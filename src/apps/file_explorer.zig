// apps/file_explorer.zig - Core97-style RAM-VFS file browser.

const fb = @import("../gui/framebuffer.zig");
const vfs = @import("../fs/vfs.zig");
const ui = @import("../gui/ui.zig");
const selection = @import("../gui/selection.zig");

pub var open: bool = false;

const MAX_EXPLORERS: usize = 6;
const MAX_SELECTABLE_ROWS: usize = 16; // matches vfs.zig's MAX_CHILDREN
const ExplorerArea = struct { x: u32 = 0, y: u32 = 0, w: u32 = 0, h: u32 = 0 };

const ExplorerMode = enum { explorer, my_computer, documents, trash };

const ExplorerState = struct {
    mode: ExplorerMode = .explorer,
    current: vfs.NodeHandle = vfs.INVALID_HANDLE,
    rubber_band: selection.RubberBand = .{},
    selected_rows: [MAX_SELECTABLE_ROWS]bool = [_]bool{false} ** MAX_SELECTABLE_ROWS,
    last_area: ExplorerArea = .{},
    context_open: bool = false,
    context_x: u32 = 0,
    context_y: u32 = 0,
    context_target_row: ?usize = null,
    hover_x: i32 = -1,
    hover_y: i32 = -1,
};

var states: [MAX_EXPLORERS]ExplorerState = [_]ExplorerState{.{}} ** MAX_EXPLORERS;
var active_id: usize = 0;

fn useExplorer(id: usize) void {
    active_id = if (id < MAX_EXPLORERS) id else 0;
}

fn st() *ExplorerState {
    return &states[active_id];
}

// Drag-to-select state for the file list (right-hand content pane).
// Clicking directly on an item still opens it immediately (unchanged
// behavior) - the rubber band is specifically for dragging across empty
// space to multi-select several items at once, same as a real desktop
// file manager. selected_rows is indexed by row position within the
// CURRENT directory's listing, so it's reset every time `current`
// changes (see clearSelection() and its call sites) rather than tracking
// handles directly - simpler, since row order already matches what's
// drawn.
// onMouseUp (window.AppVTable) takes no position arguments - it only
// fires after onMouseDown already gave us the content area once this
// drag, so we cache it per Explorer instance rather than sharing it
// between windows.

fn clearSelection() void {
    st().selected_rows = [_]bool{false} ** MAX_SELECTABLE_ROWS;
}

const MENU_H: u32 = 16;
const TOOL_H: u32 = 44;
const ADDR_H: u32 = 20;
const STATUS_H: u32 = 18;
const TREE_W: u32 = 135;
const ROW_H: u32 = 18;

pub fn init() void {
    var i: usize = 0;
    while (i < MAX_EXPLORERS) : (i += 1) {
        states[i].current = vfs.root;
    }
}

pub fn showRoot() void {
    showRootAt(0);
}

pub fn showRootAt(id: usize) void {
    useExplorer(id);
    st().mode = .explorer;
    st().current = vfs.root;
    open = true;
    clearSelection();
}

pub fn showComputerAt(id: usize) void {
    useExplorer(id);
    st().mode = .my_computer;
    st().current = vfs.root;
    open = true;
    clearSelection();
}

pub fn showDocumentsAt(id: usize) void {
    useExplorer(id);
    st().mode = .documents;
    if (vfs.resolvePath("/users/default")) |docs| st().current = docs else st().current = vfs.root;
    open = true;
    clearSelection();
}

pub fn showTrashAt(id: usize) void {
    useExplorer(id);
    st().mode = .trash;
    if (vfs.trashFolder()) |trash| st().current = trash else st().current = vfs.root;
    open = true;
    clearSelection();
}

pub fn currentNode() vfs.NodeHandle {
    return st().current;
}

/// True if the current directory has a parent to go back to (i.e. we're
/// not sitting at the root already).
pub fn canGoBack() bool {
    return vfs.parentOf(safeCurrent()) != vfs.INVALID_HANDLE;
}

/// Navigates to the parent of the current directory. No-op at the root.
pub fn back() void {
    const cur = safeCurrent();
    const parent = vfs.parentOf(cur);
    if (parent != vfs.INVALID_HANDLE) {
        st().current = parent;
        clearSelection();
    }
}

/// Jumps straight to a specific node (used by the "Documents" Start menu
/// item to open the explorer at /users/default instead of at the root).
pub fn navigateTo(handle: vfs.NodeHandle) void {
    navigateToAt(0, handle);
}

pub fn navigateToAt(id: usize, handle: vfs.NodeHandle) void {
    useExplorer(id);
    st().mode = .explorer;
    if (handle != vfs.INVALID_HANDLE) {
        st().current = handle;
        clearSelection();
    }
}

fn safeCurrent() vfs.NodeHandle {
    if (st().current == vfs.INVALID_HANDLE) st().current = vfs.root;
    return st().current;
}

fn drawIcon(x: u32, y: u32, folder: bool) void {
    if (folder) {
        fb.fillRect(x, y + 5, 15, 10, 0xFFFF80);
        fb.fillRect(x + 2, y + 3, 8, 3, 0xFFFF80);
        fb.draw3DBorder(x, y + 5, 15, 10, true);
    } else {
        fb.fillRect(x + 2, y + 1, 12, 14, fb.CORE97_WHITE);
        fb.draw3DBorder(x + 2, y + 1, 12, 14, true);
        fb.fillRect(x + 5, y + 5, 7, 1, fb.CORE97_DARK_GREY);
        fb.fillRect(x + 5, y + 8, 7, 1, fb.CORE97_DARK_GREY);
        fb.fillRect(x + 5, y + 11, 5, 1, fb.CORE97_DARK_GREY);
    }
}

fn drawToolbarButton(x: u32, y: u32, label: []const u8, enabled: bool) void {
    const hovered = enabled and ui.hit(x, y, 22, 18);
    const bg = if (hovered) 0xD8E8FF else fb.CORE97_GREY;
    fb.fillRect(x, y, 22, 18, bg);
    fb.draw3DBorder(x, y, 22, 18, true);
    fb.drawString(x + 6, y + 6, label, if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY, bg);
}


fn drawSeparator(x: u32, y: u32, h: u32) void {
    fb.fillRect(x, y + 2, 1, h - 4, fb.CORE97_DARK_GREY);
    fb.fillRect(x + 1, y + 2, 1, h - 4, fb.CORE97_WHITE);
}

fn drawMiniIcon(x: u32, y: u32, kind: u8, enabled: bool) void {
    const c = if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY;
    switch (kind) {
        0 => { // back arrow
            fb.fillRect(x + 2, y + 6, 11, 3, if (enabled) 0x008000 else fb.CORE97_DARK_GREY);
            fb.fillRect(x + 2, y + 3, 3, 9, if (enabled) 0x008000 else fb.CORE97_DARK_GREY);
            fb.putPixel(x + 1, y + 7, if (enabled) 0x008000 else fb.CORE97_DARK_GREY);
        },
        1 => { // forward arrow
            fb.fillRect(x + 2, y + 6, 11, 3, c);
            fb.fillRect(x + 10, y + 3, 3, 9, c);
            fb.putPixel(x + 14, y + 7, c);
        },
        2 => { // up folder
            fb.fillRect(x + 1, y + 7, 14, 8, 0xFFFF80);
            fb.draw3DBorder(x + 1, y + 7, 14, 8, true);
            fb.fillRect(x + 6, y + 2, 3, 8, if (enabled) 0x008000 else fb.CORE97_DARK_GREY);
            fb.fillRect(x + 4, y + 4, 7, 2, if (enabled) 0x008000 else fb.CORE97_DARK_GREY);
        },
        3 => { // scissors/cut
            fb.fillRect(x + 4, y + 2, 2, 12, c);
            fb.fillRect(x + 10, y + 2, 2, 12, c);
            fb.drawString(x + 2, y + 9, "x", c, fb.CORE97_GREY);
        },
        4 => { // copy
            fb.fillRect(x + 5, y + 2, 9, 12, fb.CORE97_WHITE); fb.draw3DBorder(x + 5, y + 2, 9, 12, true);
            fb.fillRect(x + 2, y + 5, 9, 12, fb.CORE97_WHITE); fb.draw3DBorder(x + 2, y + 5, 9, 12, true);
        },
        5 => { // paste
            fb.fillRect(x + 4, y + 1, 8, 4, 0xC08020); fb.draw3DBorder(x + 4, y + 1, 8, 4, true);
            fb.fillRect(x + 2, y + 5, 12, 11, fb.CORE97_WHITE); fb.draw3DBorder(x + 2, y + 5, 12, 11, true);
        },
        6 => { // delete x
            fb.drawString(x + 4, y + 4, "X", 0xC00000, fb.CORE97_GREY);
        },
        else => { // properties
            fb.fillRect(x + 3, y + 1, 10, 14, fb.CORE97_WHITE); fb.draw3DBorder(x + 3, y + 1, 10, 14, true);
            fb.fillRect(x + 6, y + 5, 5, 1, fb.CORE97_DARK_GREY);
            fb.fillRect(x + 6, y + 8, 5, 1, fb.CORE97_DARK_GREY);
        },
    }
}

fn drawToolbarCommand(x: u32, y: u32, label: []const u8, icon: u8, enabled: bool) void {
    const hovered = enabled and ui.hit(x, y, 58, 34);
    if (hovered) fb.draw3DBorder(x, y, 58, 34, true);
    drawMiniIcon(x + 20, y + 3, icon, enabled);
    fb.drawString(x + 6, y + 23, label, if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY, fb.CORE97_GREY);
}

fn drawColumnHeader(x: u32, y: u32, w: u32, label: []const u8) void {
    fb.fillRect(x, y, w, 18, fb.CORE97_GREY);
    fb.draw3DBorder(x, y, w, 18, true);
    fb.drawString(x + 6, y + 6, label, fb.CORE97_BLACK, fb.CORE97_GREY);
}

fn drawTaskPanelHeader(x: u32, y: u32, w: u32, label: []const u8) void {
    fb.fillRect(x, y, w, 20, fb.CORE97_BLUE);
    fb.drawString(x + 8, y + 7, label, fb.CORE97_WHITE, fb.CORE97_BLUE);
    fb.drawString(x + w - 18, y + 7, "^", fb.CORE97_WHITE, fb.CORE97_BLUE);
}

fn drawProgressBar(x: u32, y: u32, w: u32, filled: u32) void {
    fb.fillRect(x, y, w, 8, fb.CORE97_WHITE);
    fb.draw3DBorder(x, y, w, 8, false);
    if (filled > 2) fb.fillRect(x + 1, y + 1, filled - 2, 6, fb.CORE97_BLUE);
}

fn drawTreeItem(x: u32, y: u32, name: []const u8, indent: u32) void {
    drawIcon(x + indent, y + 1, true);
    fb.drawString(x + indent + 20, y + 6, name, fb.CORE97_BLACK, fb.CORE97_WHITE);
}

fn drawLeftTree(x: u32, y: u32, h: u32) void {
    fb.fillRect(x, y, TREE_W, h, fb.CORE97_WHITE);
    fb.draw3DBorder(x, y, TREE_W, h, false);

    var row_y = y + 6;
    drawTreeItem(x + 6, row_y, "Desktop", 0);
    row_y += ROW_H;
    drawTreeItem(x + 6, row_y, "My Computer", 8);
    row_y += ROW_H;
    drawTreeItem(x + 6, row_y, "C:", 16);
    row_y += ROW_H;

    const root = vfs.root;
    var i: usize = 0;
    while (i < vfs.childCount(root)) : (i += 1) {
        const child = vfs.childAt(root, i);
        if (child == vfs.INVALID_HANDLE) continue;
        if (vfs.kindOf(child) == .directory) {
            drawTreeItem(x + 6, row_y, vfs.nameOf(child), 24);
            row_y += ROW_H;
            if (row_y + ROW_H >= y + h) break;
        }
    }
}

fn drawContents(x: u32, y: u32, w: u32, h: u32) void {
    const cur = safeCurrent();

    fb.fillRect(x, y, w, h, fb.CORE97_WHITE);
    fb.draw3DBorder(x, y, w, h, false);

    // Details view: clearer columns make Explorer feel like a real file manager.
    const header_y = y + 1;
    const name_w: u32 = if (w > 300) w - 235 else 120;
    drawColumnHeader(x + 1, header_y, name_w, "Name");
    drawColumnHeader(x + 1 + name_w, header_y, 58, "Size");
    drawColumnHeader(x + 1 + name_w + 58, header_y, 92, "Type");
    drawColumnHeader(x + 1 + name_w + 150, header_y, if (w > name_w + 154) w - name_w - 154 else 70, "Modified");

    var row: usize = 0;
    const count = vfs.childCount(cur);
    while (row < count) : (row += 1) {
        const child = vfs.childAt(cur, row);
        if (child == vfs.INVALID_HANDLE) continue;

        const ry = y + 24 + @as(u32, @intCast(row)) * ROW_H;
        if (ry + ROW_H >= y + h) break;

        const is_folder = vfs.kindOf(child) == .directory;
        const hx: u32 = if (st().hover_x < 0) 0 else @intCast(st().hover_x);
        const hy: u32 = if (st().hover_y < 0) 0 else @intCast(st().hover_y);
        const hovered = hx >= x and hx < x + w and hy >= ry and hy < ry + ROW_H;
        const is_selected = row < MAX_SELECTABLE_ROWS and st().selected_rows[row];
        const row_bg = if (is_selected) 0x99C2FF else if (hovered) 0xE8F2FF else fb.CORE97_WHITE;
        if (is_selected or hovered) fb.fillRect(x + 2, ry, w - 4, ROW_H, row_bg);
        drawIcon(x + 8, ry + 1, is_folder);
        fb.drawString(x + 30, ry + 6, vfs.nameOf(child), fb.CORE97_BLACK, row_bg);
        const size_text: []const u8 = if (is_folder) "" else "1 KB";
        const type_text: []const u8 = if (is_folder) "File Folder" else "Text File";
        fb.drawString(x + 1 + name_w + 8, ry + 6, size_text, fb.CORE97_BLACK, row_bg);
        fb.drawString(x + 1 + name_w + 66, ry + 6, type_text, fb.CORE97_BLACK, row_bg);
        fb.drawString(x + 1 + name_w + 158, ry + 6, "Today", fb.CORE97_BLACK, row_bg);
    }

    if (count == 0) {
        fb.drawString(x + 32, y + 48, "This folder is empty.", fb.CORE97_DARK_GREY, fb.CORE97_WHITE);
    }
}


fn drawLargeFolderIcon(x: u32, y: u32) void {
    fb.fillRect(x + 4, y + 14, 38, 28, 0xFFFF80);
    fb.fillRect(x + 7, y + 9, 18, 7, 0xFFFF80);
    fb.draw3DBorder(x + 4, y + 14, 38, 28, true);
}

fn drawComputerIcon(x: u32, y: u32) void {
    fb.fillRect(x + 8, y + 6, 34, 26, fb.CORE97_GREY);
    fb.draw3DBorder(x + 8, y + 6, 34, 26, true);
    fb.fillRect(x + 12, y + 10, 26, 16, 0x102060);
    fb.fillRect(x + 20, y + 33, 12, 5, fb.CORE97_DARK_GREY);
    fb.fillRect(x + 14, y + 38, 24, 4, fb.CORE97_GREY);
    fb.draw3DBorder(x + 14, y + 38, 24, 4, true);
}

fn drawDiskIcon(x: u32, y: u32) void {
    fb.fillRect(x + 5, y + 20, 40, 18, fb.CORE97_GREY);
    fb.draw3DBorder(x + 5, y + 20, 40, 18, true);
    fb.fillRect(x + 10, y + 32, 25, 2, fb.CORE97_DARK_GREY);
    fb.fillRect(x + 38, y + 25, 4, 4, 0x00C000);
}

fn drawTrashIconBig(x: u32, y: u32) void {
    fb.fillRect(x + 13, y + 12, 24, 30, 0xE8E8E8);
    fb.draw3DBorder(x + 13, y + 12, 24, 30, true);
    fb.fillRect(x + 10, y + 9, 30, 5, fb.CORE97_GREY);
    fb.drawString(x + 19, y + 23, "X", 0x00A000, 0xE8E8E8);
}

fn drawDocIconBig(x: u32, y: u32) void {
    fb.fillRect(x + 14, y + 6, 26, 36, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 14, y + 6, 26, 36, true);
    fb.fillRect(x + 19, y + 17, 15, 1, fb.CORE97_DARK_GREY);
    fb.fillRect(x + 19, y + 23, 15, 1, fb.CORE97_DARK_GREY);
    fb.fillRect(x + 19, y + 29, 12, 1, fb.CORE97_DARK_GREY);
}

fn drawLargeIconLabel(x: u32, y: u32, label: []const u8) void {
    fb.drawString(x, y, label, fb.CORE97_BLACK, fb.CORE97_WHITE);
}

fn drawHeader(x: u32, y: u32, w: u32, title: []const u8, subtitle: []const u8, kind: ExplorerMode) void {
    fb.fillRect(x, y, w, 54, 0xF4F4F4);
    fb.draw3DBorder(x, y, w, 54, false);
    switch (kind) {
        .my_computer => drawComputerIcon(x + 12, y + 6),
        .trash => drawTrashIconBig(x + 12, y + 6),
        .documents => drawLargeFolderIcon(x + 12, y + 6),
        else => drawLargeFolderIcon(x + 12, y + 6),
    }
    fb.drawString(x + 66, y + 13, title, fb.CORE97_BLACK, 0xF4F4F4);
    fb.drawString(x + 66, y + 31, subtitle, fb.CORE97_DARK_GREY, 0xF4F4F4);
}

fn drawNiceMenu(x: u32, y: u32, w: u32, with_favorites: bool) void {
    fb.fillRect(x, y, w, MENU_H, fb.CORE97_GREY);
    fb.drawString(x + 6, y + 5, "File", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 38, y + 5, "Edit", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 70, y + 5, "View", fb.CORE97_BLACK, fb.CORE97_GREY);
    if (with_favorites) {
        fb.drawString(x + 108, y + 5, "Favorites", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + 174, y + 5, "Tools", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + 216, y + 5, "Help", fb.CORE97_BLACK, fb.CORE97_GREY);
    } else {
        fb.drawString(x + 108, y + 5, "Help", fb.CORE97_BLACK, fb.CORE97_GREY);
    }
}

fn drawToolLabel(x: u32, y: u32, label: []const u8, enabled: bool) void {
    drawToolbarButton(x, y, " ", enabled);
    fb.drawString(x + 26, y + 6, label, if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY, fb.CORE97_GREY);
}

fn drawComputerView(x: u32, y: u32, w: u32, h: u32) void {
    fb.fillRect(x, y, w, h, fb.CORE97_GREY);
    drawNiceMenu(x, y, w, true);
    const ty = y + MENU_H;
    fb.fillRect(x, ty, w, TOOL_H, fb.CORE97_GREY);
    drawToolbarCommand(x + 8, ty + 4, "Open", 2, true);
    drawToolbarCommand(x + 72, ty + 4, "Props", 7, true);
    drawToolbarCommand(x + 140, ty + 4, "View", 4, true);

    const body_y = ty + TOOL_H;
    const body_h = if (h > MENU_H + TOOL_H + STATUS_H) h - MENU_H - TOOL_H - STATUS_H else 1;
    fb.fillRect(x + 4, body_y + 4, if (w > 8) w - 8 else 1, if (body_h > 8) body_h - 8 else 1, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 4, body_y + 4, if (w > 8) w - 8 else 1, if (body_h > 8) body_h - 8 else 1, false);
    drawHeader(x + 4, body_y + 4, if (w > 8) w - 8 else 1, "My Computer", "Drives, devices and system tools", .my_computer);

    const iy = body_y + 82;
    drawDiskIcon(x + 28, iy);
    drawLargeIconLabel(x + 16, iy + 52, "Local Disk (C:)");
    drawProgressBar(x + 18, iy + 68, 92, 46);
    fb.drawString(x + 18, iy + 82, "15.2 GB free", fb.CORE97_DARK_GREY, fb.CORE97_WHITE);

    drawDiskIcon(x + 155, iy);
    drawLargeIconLabel(x + 145, iy + 52, "RAM Disk (R:)");
    drawProgressBar(x + 150, iy + 68, 92, 52);
    fb.drawString(x + 150, iy + 82, "63.8 MB free", fb.CORE97_DARK_GREY, fb.CORE97_WHITE);

    drawLargeFolderIcon(x + 282, iy);
    drawLargeIconLabel(x + 272, iy + 52, "CD-ROM (D:)");
    fb.drawString(x + 292, iy + 68, "No media", fb.CORE97_DARK_GREY, fb.CORE97_WHITE);

    const iy2 = iy + 118;
    drawLargeFolderIcon(x + 28, iy2); drawLargeIconLabel(x + 18, iy2 + 52, "Control Panel");
    drawComputerIcon(x + 155, iy2); drawLargeIconLabel(x + 152, iy2 + 52, "System Info");
    drawLargeFolderIcon(x + 282, iy2); drawLargeIconLabel(x + 286, iy2 + 52, "Printers");
    drawComputerIcon(x + 405, iy2); drawLargeIconLabel(x + 410, iy2 + 52, "Network");

    const sy = y + h - STATUS_H;
    fb.fillRect(x, sy, w, STATUS_H, fb.CORE97_GREY);
    fb.draw3DBorder(x, sy, w, STATUS_H, false);
    fb.drawString(x + 6, sy + 6, "8 object(s)", fb.CORE97_BLACK, fb.CORE97_GREY);
}

fn drawTrashView(x: u32, y: u32, w: u32, h: u32) void {
    const cur = safeCurrent();
    fb.fillRect(x, y, w, h, fb.CORE97_GREY);
    drawNiceMenu(x, y, w, false);
    const ty = y + MENU_H;
    fb.fillRect(x, ty, w, TOOL_H, fb.CORE97_GREY);
    drawToolbarCommand(x + 8, ty + 4, "Restore", 0, true);
    drawToolbarCommand(x + 82, ty + 4, "Delete", 6, true);
    drawToolbarCommand(x + 150, ty + 4, "Empty", 5, true);
    drawToolbarCommand(x + 218, ty + 4, "Props", 7, true);
    const body_y = ty + TOOL_H;
    const body_h = if (h > MENU_H + TOOL_H + STATUS_H) h - MENU_H - TOOL_H - STATUS_H else 1;
    fb.fillRect(x + 4, body_y + 4, if (w > 8) w - 8 else 1, if (body_h > 8) body_h - 8 else 1, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 4, body_y + 4, if (w > 8) w - 8 else 1, if (body_h > 8) body_h - 8 else 1, false);
    drawHeader(x + 4, body_y + 4, if (w > 8) w - 8 else 1, "Trash", "Deleted files waiting to be emptied", .trash);
    const ly = body_y + 64;
    fb.fillRect(x + 8, ly, w - 16, 18, fb.CORE97_GREY); fb.draw3DBorder(x + 8, ly, w - 16, 18, false);
    fb.drawString(x + 14, ly + 6, "Name", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 190, ly + 6, "Original Location", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 390, ly + 6, "Deleted", fb.CORE97_BLACK, fb.CORE97_GREY);
    var row: usize = 0; const count = vfs.childCount(cur);
    while (row < count) : (row += 1) {
        const child = vfs.childAt(cur, row); if (child == vfs.INVALID_HANDLE) continue;
        const ry = ly + 22 + @as(u32, @intCast(row)) * ROW_H; if (ry + ROW_H >= y + h - STATUS_H) break;
        drawIcon(x + 14, ry + 1, vfs.kindOf(child) == .directory);
        fb.drawString(x + 38, ry + 6, vfs.nameOf(child), fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 190, ry + 6, "C:\\Users\\Default\\", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 390, ry + 6, "Today", fb.CORE97_BLACK, fb.CORE97_WHITE);
    }
    const sy = y + h - STATUS_H; fb.fillRect(x, sy, w, STATUS_H, fb.CORE97_GREY); fb.draw3DBorder(x, sy, w, STATUS_H, false); fb.drawString(x + 6, sy + 6, "Trash items", fb.CORE97_BLACK, fb.CORE97_GREY);
}

fn drawDocumentsView(x: u32, y: u32, w: u32, h: u32) void {
    const cur = safeCurrent();
    fb.fillRect(x, y, w, h, fb.CORE97_GREY);
    drawNiceMenu(x, y, w, true);

    const ty = y + MENU_H;
    fb.fillRect(x, ty, w, TOOL_H, fb.CORE97_GREY);
    drawToolbarCommand(x + 8, ty + 4, "Back", 0, canGoBack());
    drawToolbarCommand(x + 72, ty + 4, "Forward", 1, false);
    drawToolbarCommand(x + 140, ty + 4, "Up", 2, true);
    drawSeparator(x + 202, ty + 4, TOOL_H - 8);
    drawToolbarCommand(x + 212, ty + 4, "Cut", 3, true);
    drawToolbarCommand(x + 270, ty + 4, "Copy", 4, true);
    drawToolbarCommand(x + 328, ty + 4, "Paste", 5, true);
    drawToolbarCommand(x + 390, ty + 4, "Undo", 1, false);
    drawToolbarCommand(x + 450, ty + 4, "Delete", 6, true);

    const ay = ty + TOOL_H;
    fb.fillRect(x, ay, w, ADDR_H, fb.CORE97_GREY);
    fb.drawString(x + 6, ay + 6, "Address", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.fillRect(x + 58, ay + 3, w - 84, 14, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 58, ay + 3, w - 84, 14, false);
    drawIcon(x + 63, ay + 3, true);
    fb.drawString(x + 84, ay + 7, "C:\\Users\\Default\\Documents", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.fillRect(x + w - 24, ay + 3, 16, 14, fb.CORE97_GREY);
    fb.draw3DBorder(x + w - 24, ay + 3, 16, 14, true);
    fb.drawString(x + w - 20, ay + 7, "v", fb.CORE97_BLACK, fb.CORE97_GREY);

    const body_y = ay + ADDR_H;
    const body_h = if (h > MENU_H + TOOL_H + ADDR_H + STATUS_H) h - MENU_H - TOOL_H - ADDR_H - STATUS_H else 1;
    drawLeftTree(x + 4, body_y + 2, body_h - 4);
    drawContents(x + 6 + TREE_W, body_y + 2, w - TREE_W - 10, body_h - 4);

    const sy = y + h - STATUS_H;
    fb.fillRect(x, sy, w, STATUS_H, fb.CORE97_GREY);
    fb.draw3DBorder(x, sy, w, STATUS_H, false);
    fb.drawString(x + 6, sy + 6, "6 object(s)", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + w - 96, sy + 6, "1.26 KB", fb.CORE97_BLACK, fb.CORE97_GREY);
    _ = cur;
}

pub fn draw(x: u32, y: u32, w: u32, h: u32) void {
    switch (st().mode) {
        .my_computer => { drawComputerView(x, y, w, h); return; },
        .trash => { drawTrashView(x, y, w, h); return; },
        .documents => { drawDocumentsView(x, y, w, h); return; },
        else => {},
    }
    const cur = safeCurrent();

    fb.fillRect(x, y, w, h, fb.CORE97_GREY);

    // Menu bar
    fb.fillRect(x, y, w, MENU_H, fb.CORE97_GREY);
    fb.drawString(x + 6, y + 5, "File", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 38, y + 5, "Edit", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 70, y + 5, "View", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 108, y + 5, "Tools", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 150, y + 5, "Help", fb.CORE97_BLACK, fb.CORE97_GREY);

    // Toolbar - larger icon commands like late-90s Explorer.
    const ty = y + MENU_H;
    fb.fillRect(x, ty, w, TOOL_H, fb.CORE97_GREY);
    drawToolbarCommand(x + 6, ty + 4, "Back", 0, canGoBack());
    drawToolbarCommand(x + 66, ty + 4, "Forward", 1, false);
    drawToolbarCommand(x + 132, ty + 4, "Up", 2, true);
    drawSeparator(x + 194, ty + 4, TOOL_H - 8);
    drawToolbarCommand(x + 204, ty + 4, "Cut", 3, true);
    drawToolbarCommand(x + 262, ty + 4, "Copy", 4, true);
    drawToolbarCommand(x + 320, ty + 4, "Paste", 5, true);
    drawToolbarCommand(x + 382, ty + 4, "Delete", 6, true);
    drawToolbarCommand(x + 446, ty + 4, "Props", 7, true);

    // Address bar
    const ay = ty + TOOL_H;
    fb.fillRect(x, ay, w, ADDR_H, fb.CORE97_GREY);
    fb.drawString(x + 6, ay + 6, "Address:", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.fillRect(x + 58, ay + 3, w - 66, 14, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 58, ay + 3, w - 66, 14, false);
    fb.drawString(x + 64, ay + 7, "C:\\", fb.CORE97_BLACK, fb.CORE97_WHITE);
    if (cur != vfs.root) {
        fb.drawString(x + 82, ay + 7, vfs.nameOf(cur), fb.CORE97_BLACK, fb.CORE97_WHITE);
    }

    const body_y = ay + ADDR_H;
    const body_h = if (h > MENU_H + TOOL_H + ADDR_H + STATUS_H)
        h - MENU_H - TOOL_H - ADDR_H - STATUS_H
    else
        1;

    drawLeftTree(x + 4, body_y + 2, body_h - 4);
    drawContents(x + 6 + TREE_W, body_y + 2, w - TREE_W - 10, body_h - 4);

    // Status bar
    const sy = y + h - STATUS_H;
    fb.fillRect(x, sy, w, STATUS_H, fb.CORE97_GREY);
    fb.draw3DBorder(x, sy, w, STATUS_H, false);
    fb.drawString(x + 6, sy + 6, "Objects:", fb.CORE97_BLACK, fb.CORE97_GREY);

    const count = vfs.childCount(cur);
    if (count == 0) fb.drawString(x + 58, sy + 6, "0", fb.CORE97_BLACK, fb.CORE97_GREY);
    if (count == 1) fb.drawString(x + 58, sy + 6, "1", fb.CORE97_BLACK, fb.CORE97_GREY);
    if (count == 2) fb.drawString(x + 58, sy + 6, "2", fb.CORE97_BLACK, fb.CORE97_GREY);
    if (count == 3) fb.drawString(x + 58, sy + 6, "3", fb.CORE97_BLACK, fb.CORE97_GREY);
}


/// Hit-test for the "<" (Back) toolbar button. `x, y` are the explorer's
/// content-area origin, same as passed to draw().
pub fn backButtonHit(mx: i32, my: i32, x: u32, y: u32) bool {
    const ty: i32 = @intCast(y + MENU_H);
    const bx: i32 = @intCast(x + 6);
    const by: i32 = ty + 4;
    return mx >= bx and mx < bx + 58 and my >= by and my < by + 34;
}

pub fn treeItemAt(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) ?vfs.NodeHandle {
    _ = w;
    _ = h;

    const tree_x: i32 = @intCast(x + 4);
    const tree_y: i32 = @intCast(y + MENU_H + TOOL_H + ADDR_H + 2 + 2 + 6);

    if (mx < tree_x or mx >= tree_x + @as(i32, @intCast(TREE_W))) return null;
    if (my < tree_y) return null;

    const row: usize = @intCast(@divTrunc(my - tree_y, @as(i32, @intCast(ROW_H))));

    if (row <= 2) return vfs.root;

    const idx = row - 3;
    if (idx >= vfs.childCount(vfs.root)) return null;

    const child = vfs.childAt(vfs.root, idx);
    if (child == vfs.INVALID_HANDLE) return null;
    if (vfs.kindOf(child) != .directory) return null;
    return child;
}

/// Same hit-test as itemAt(), but returns the row index instead of
/// resolving it to a handle - needed so click handling can update
/// st().selected_rows (which is row-indexed) without a second geometry
/// calculation duplicated inline at every call site.
fn rowAtPoint(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) ?usize {
    const body_y = y + MENU_H + TOOL_H + ADDR_H + 2;
    const right_x = x + 6 + TREE_W;
    const right_w = w - TREE_W - 10;
    const ix: i32 = @intCast(right_x);
    const iy: i32 = @intCast(body_y + 24);

    if (mx < ix or my < iy) return null;
    if (mx >= ix + @as(i32, @intCast(right_w))) return null;
    if (my >= @as(i32, @intCast(y + h - STATUS_H))) return null;

    const row: usize = @intCast(@divTrunc(my - iy, @as(i32, @intCast(ROW_H))));
    if (row >= vfs.childCount(safeCurrent())) return null;
    return row;
}

pub fn itemAt(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) ?vfs.NodeHandle {
    const body_y = y + MENU_H + TOOL_H + ADDR_H + 2;
    const right_x = x + 6 + TREE_W;
    const right_w = w - TREE_W - 10;
    const ix: i32 = @intCast(right_x);
    const iy: i32 = @intCast(body_y + 24);

    if (mx < ix or my < iy) return null;
    if (mx >= ix + @as(i32, @intCast(right_w))) return null;
    if (my >= @as(i32, @intCast(y + h - STATUS_H))) return null;

    const row: usize = @intCast(@divTrunc(my - iy, @as(i32, @intCast(ROW_H))));
    const cur = safeCurrent();
    if (row >= vfs.childCount(cur)) return null;

    const child = vfs.childAt(cur, row);
    if (child == vfs.INVALID_HANDLE) return null;
    return child;
}

/// The screen-space rectangle row `row` occupies in the content pane -
/// same geometry itemAt() hit-tests against, just exposed per-row so the
/// rubber band can test "does my selection rect overlap this row" rather
/// than "what row is the mouse over right now".
fn itemRowRect(row: usize, x: u32, y: u32, w: u32, h: u32) selection.Rect {
    _ = h;
    const body_y = y + MENU_H + TOOL_H + ADDR_H + 2;
    const right_x = x + 6 + TREE_W;
    const right_w = w - TREE_W - 10;
    const iy = body_y + 24;
    return .{
        .x = @intCast(right_x),
        .y = @intCast(iy + @as(u32, @intCast(row)) * ROW_H),
        .w = right_w,
        .h = ROW_H,
    };
}

/// True if (mx, my) is somewhere inside the content pane's body - the
/// scrollable file list area - regardless of whether it's actually on
/// top of an item or in the empty space below/between them. Used to
/// decide whether an empty-space click should start a rubber-band drag
/// (as opposed to a click on the tree, toolbar, or menu bar doing
/// something else entirely).
fn contentBodyContains(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) bool {
    const body_y = y + MENU_H + TOOL_H + ADDR_H + 2;
    const right_x = x + 6 + TREE_W;
    const right_w = w - TREE_W - 10;
    const ix: i32 = @intCast(right_x);
    const iy: i32 = @intCast(body_y);

    if (mx < ix or my < iy) return false;
    if (mx >= ix + @as(i32, @intCast(right_w))) return false;
    if (my >= @as(i32, @intCast(y + h - STATUS_H))) return false;
    return true;
}

pub fn activate(handle: vfs.NodeHandle) bool {
    if (handle == vfs.INVALID_HANDLE) return false;
    if (vfs.kindOf(handle) == .directory) {
        st().current = handle;
        clearSelection();
        return true;
    }
    return false;
}

pub const ContextAction = enum { none, new_folder, new_text, move_to_trash, empty_trash };

// Which row (if any) the cursor was over when the context menu was
// opened - determines whether "Move to Trash" shows up at all (only
// makes sense if you right-clicked an actual item). Set in
// openContextMenu(), read by contextActionAt()/drawContextMenu()/
// handleContextAction().

fn isInTrash() bool {
    const trash = vfs.trashFolder() orelse return false;
    return safeCurrent() == trash;
}

pub fn setHover(mx: i32, my: i32) void {
    st().hover_x = mx;
    st().hover_y = my;
}

pub fn openContextMenu(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) void {
    st().context_open = true;
    st().context_x = if (mx < 0) 0 else @intCast(mx);
    st().context_y = if (my < 0) 0 else @intCast(my);
    st().context_target_row = rowAtPoint(mx, my, x, y, w, h);
}

pub fn closeContextMenu() void {
    st().context_open = false;
}

fn contextRowCount() u32 {
    if (isInTrash()) return 3; // Empty Trash always available here
    if (st().context_target_row != null) return 3; // Move to Trash, since an item was right-clicked
    return 2;
}

pub fn contextContains(mx: i32, my: i32) bool {
    if (!st().context_open) return false;
    const x: i32 = @intCast(st().context_x);
    const y: i32 = @intCast(st().context_y);
    return mx >= x and mx < x + 150 and my >= y and my < y + @as(i32, @intCast(contextRowCount() * 24));
}

pub fn contextActionAt(mx: i32, my: i32) ContextAction {
    if (!st().context_open) return .none;

    const x: i32 = @intCast(st().context_x);
    const y: i32 = @intCast(st().context_y);
    const rows = contextRowCount();

    if (mx < x or mx >= x + 150) return .none;
    if (my < y or my >= y + @as(i32, @intCast(rows * 24))) return .none;

    const row = @divTrunc(my - y, 24);
    if (row == 2) {
        return if (isInTrash()) .empty_trash else .move_to_trash;
    }
    return switch (row) {
        0 => .new_folder,
        1 => .new_text,
        else => .none,
    };
}

pub fn handleContextAction(action: ContextAction) bool {
    const cur = safeCurrent();
    switch (action) {
        .new_folder => {
            _ = vfs.createUniqueFolder(cur);
            st().context_open = false;
            return true;
        },
        .new_text => {
            _ = vfs.createUniqueTextFile(cur);
            st().context_open = false;
            return true;
        },
        .move_to_trash => {
            const trash = vfs.trashFolder();
            if (trash) |t| {
                // Moves every currently-selected row, or just the
                // right-clicked one if nothing was multi-selected -
                // same "act on the selection, or on what you clicked if
                // there isn't one" convention real file managers use.
                var any_selected = false;
                for (st().selected_rows) |s| { if (s) any_selected = true; }
                if (any_selected) {
                    var row: usize = MAX_SELECTABLE_ROWS;
                    while (row > 0) {
                        row -= 1;
                        if (!st().selected_rows[row]) continue;
                        const h = vfs.childAt(cur, row);
                        if (h != vfs.INVALID_HANDLE) _ = vfs.moveNode(h, t);
                    }
                    clearSelection();
                } else if (st().context_target_row) |row| {
                    const h = vfs.childAt(cur, row);
                    if (h != vfs.INVALID_HANDLE) _ = vfs.moveNode(h, t);
                }
            }
            st().context_open = false;
            return true;
        },
        .empty_trash => {
            // deleteChild needs a name, not a handle, and shifts the
            // children array down on every call - always taking index 0
            // until none are left sidesteps having to worry about that
            // shifting invalidating any index past the first.
            while (vfs.childCount(cur) > 0) {
                const h = vfs.childAt(cur, 0);
                if (h == vfs.INVALID_HANDLE) break;
                _ = vfs.deleteChild(cur, vfs.nameOf(h));
            }
            st().context_open = false;
            return true;
        },
        .none => return false,
    }
}

pub fn drawContextMenu() void {
    if (!st().context_open) return;
    const rows = contextRowCount();
    const menu_h = rows * 24;

    fb.fillRect(st().context_x + 4, st().context_y + 4, 150, menu_h, fb.CORE97_DARK_GREY);
    fb.fillRect(st().context_x, st().context_y, 150, menu_h, fb.CORE97_GREY);
    fb.draw3DBorder(st().context_x, st().context_y, 150, menu_h, true);

    const hx: u32 = if (st().hover_x < 0) 0 else @intCast(st().hover_x);
    const hy: u32 = if (st().hover_y < 0) 0 else @intCast(st().hover_y);

    const h0 = hx >= st().context_x and hx < st().context_x + 150 and hy >= st().context_y and hy < st().context_y + 24;
    const h1 = hx >= st().context_x and hx < st().context_x + 150 and hy >= st().context_y + 24 and hy < st().context_y + 48;
    const h2 = rows == 3 and hx >= st().context_x and hx < st().context_x + 150 and hy >= st().context_y + 48 and hy < st().context_y + 72;

    if (h0) fb.fillRect(st().context_x + 2, st().context_y + 2, 146, 20, fb.CORE97_BLUE);
    if (h1) fb.fillRect(st().context_x + 2, st().context_y + 26, 146, 20, fb.CORE97_BLUE);
    if (h2) fb.fillRect(st().context_x + 2, st().context_y + 50, 146, 20, fb.CORE97_BLUE);

    fb.drawString(st().context_x + 8, st().context_y + 8, "New Folder", if (h0) fb.CORE97_WHITE else fb.CORE97_BLACK, if (h0) fb.CORE97_BLUE else fb.CORE97_GREY);
    fb.drawString(st().context_x + 8, st().context_y + 32, "New Text Document", if (h1) fb.CORE97_WHITE else fb.CORE97_BLACK, if (h1) fb.CORE97_BLUE else fb.CORE97_GREY);
    if (rows == 3) {
        const label: []const u8 = if (isInTrash()) "Empty Trash" else "Move to Trash";
        fb.drawString(st().context_x + 8, st().context_y + 56, label, if (h2) fb.CORE97_WHITE else fb.CORE97_BLACK, if (h2) fb.CORE97_BLUE else fb.CORE97_GREY);
    }
}

// ===========================================================================
// AppVTable adapter
// ===========================================================================
// Everything above is unchanged - draw/treeItemAt/itemAt/backButtonHit
// etc. all still take the same inset content coordinates they always
// did. This section just reproduces the small bit of glue gui/desktop.zig
// used to do by hand (computing that inset, deciding what a click landed
// on) so Explorer can be handed to the window manager as a window.App.

const window = @import("../gui/window.zig");
const notepad = @import("notepad.zig");
const mouse = @import("../drivers/mouse.zig");

fn insetOf(x: u32, y: u32, w: u32, h: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
    return .{
        .x = x + 8,
        .y = y + 8,
        .w = if (w > 16) w - 16 else 1,
        .h = if (h > 18) h - 18 else 1,
    };
}

pub const Explorer = struct {
    id: usize,

    fn activateSelf(self: *Explorer) void {
        useExplorer(self.id);
    }

    pub fn title(self: *Explorer) []const u8 {
        self.activateSelf();
        return switch (st().mode) {
            .my_computer => "My Computer",
            .documents => "Documents",
            .trash => "Trash",
            .explorer => "Explorer",
        };
    }

    pub fn titleDetail(self: *Explorer) []const u8 {
        self.activateSelf();
        return switch (st().mode) {
            .my_computer => "",
            .documents => "",
            .trash => "",
            .explorer => blk: {
                const cur = safeCurrent();
                if (cur == vfs.root) break :blk "C:\\";
                break :blk vfs.nameOf(cur);
            },
        };
    }

    pub fn draw(self: *Explorer, x: u32, y: u32, w: u32, h: u32) void {
        self.activateSelf();
        const a = insetOf(x, y, w, h);
        Self.draw(a.x, a.y, a.w, a.h);
        st().rubber_band.draw();
        drawContextMenu();
    }

    pub fn onMouseDown(self: *Explorer, mx: i32, my: i32, button: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        self.activateSelf();
        const a = insetOf(x, y, w, h);
        st().last_area = .{ .x = a.x, .y = a.y, .w = a.w, .h = a.h };

        if (st().mode == .my_computer and button == .left) {
            const body_y = a.y + MENU_H + TOOL_H;
            const iy: i32 = @intCast(body_y + 82);
            const local_x: i32 = @intCast(a.x + 30);
            const ram_x: i32 = @intCast(a.x + 160);
            const cp_x: i32 = @intCast(a.x + 290);
            const sys_x: i32 = @intCast(a.x + 420);
            const is_double = mouse.consumeDoubleClick();
            if (my >= iy and my < iy + 78) {
                if (mx >= local_x and mx < local_x + 100) {
                    if (is_double) { st().mode = .explorer; st().current = vfs.root; clearSelection(); }
                    return .none;
                }
                if (mx >= ram_x and mx < ram_x + 100) return .none;
                if (mx >= cp_x and mx < cp_x + 110) {
                    if (is_double) return .{ .open_builtin = .control_panel };
                    return .none;
                }
                if (mx >= sys_x and mx < sys_x + 100) return .none;
            }
            return .none;
        }

        if (st().mode == .trash and button == .left) {
            const ty: i32 = @intCast(a.y + MENU_H);
            const empty_x: i32 = @intCast(a.x + 150);
            if (my >= ty + 3 and my < ty + 21 and mx >= empty_x and mx < empty_x + 58) {
                _ = handleContextAction(.empty_trash);
                return .none;
            }
        }

        if (button == .right) {
            openContextMenu(mx, my, a.x, a.y, a.w, a.h);
            return .none;
        }

        const ctx_action = contextActionAt(mx, my);
        switch (ctx_action) {
            .new_folder, .new_text, .move_to_trash, .empty_trash => {
                _ = handleContextAction(ctx_action);
                closeContextMenu();
                return .none;
            },
            .none => {
                if (st().context_open) {
                    if (!contextContains(mx, my)) closeContextMenu();
                    return .none;
                }
            },
        }

        if (backButtonHit(mx, my, a.x, a.y)) {
            back();
            return .none;
        }
        if (treeItemAt(mx, my, a.x, a.y, a.w, a.h)) |handle| {
            _ = activate(handle);
            return .none;
        }
        if (rowAtPoint(mx, my, a.x, a.y, a.w, a.h)) |row| {
            const is_double = mouse.consumeDoubleClick();
            if (!is_double) {
                // Single click: select this row only, same as clicking
                // any other item in a real file manager - doesn't open
                // anything yet.
                st().selected_rows = [_]bool{false} ** MAX_SELECTABLE_ROWS;
                if (row < MAX_SELECTABLE_ROWS) st().selected_rows[row] = true;
                return .none;
            }
            const handle = vfs.childAt(safeCurrent(), row);
            if (handle != vfs.INVALID_HANDLE) {
                if (!activate(handle) and vfs.kindOf(handle) == .file) {
                    _ = notepad.loadFromVfsFile(handle);
                    return .{ .open_builtin = .notepad };
                }
            }
            return .none;
        }
        // Clicked in the content pane but not on an item - start a
        // rubber-band drag instead. Replaces any existing selection
        // immediately (no Shift/Ctrl modifier tracking on mouse events
        // yet, so this is "select only what the drag covers", not
        // "add to selection").
        if (contentBodyContains(mx, my, a.x, a.y, a.w, a.h)) {
            clearSelection();
            st().rubber_band.begin(mx, my);
        }
        return .none;
    }

    pub fn onMouseDrag(self: *Explorer, mx: i32, my: i32, _: u32, _: u32, _: u32, _: u32) void {
        self.activateSelf();
        st().rubber_band.update(mx, my);
    }

    pub fn onMouseUp(self: *Explorer) void {
        self.activateSelf();
        const r = st().rubber_band.end() orelse return;
        const cur = safeCurrent();
        const count = vfs.childCount(cur);
        var row: usize = 0;
        while (row < count and row < MAX_SELECTABLE_ROWS) : (row += 1) {
            const row_rect = itemRowRect(row, st().last_area.x, st().last_area.y, st().last_area.w, st().last_area.h);
            if (selection.rectsIntersect(r, row_rect)) st().selected_rows[row] = true;
        }
    }
    pub fn onKeyAscii(_: *Explorer, _: u8) void {}
    pub fn onKeyUsb(_: *Explorer, _: u8, _: u8, _: u32) bool {
        return false;
    }

    pub fn hasModalCapture(self: *Explorer) bool {
        self.activateSelf();
        return st().context_open;
    }
};

// `Self.draw` above refers to the free draw() function defined earlier
// in this file (the real drawing code, untouched by the refactor) -
// `Self` is just this module, named so Explorer.draw and the module's
// own draw() don't collide.
const Self = @This();

var instances: [MAX_EXPLORERS]Explorer = .{
    .{ .id = 0 },
    .{ .id = 1 },
    .{ .id = 2 },
    .{ .id = 3 },
    .{ .id = 4 },
    .{ .id = 5 },
};

pub fn asApp() window.App {
    return asAppAt(0);
}

pub fn asAppAt(id: usize) window.App {
    const safe_id = if (id < MAX_EXPLORERS) id else 0;
    return window.appFrom(Explorer, &instances[safe_id]);
}
