// apps/file_explorer.zig - Core97-style RAM-VFS file browser.

const fb = @import("../gui/framebuffer.zig");
const vfs = @import("../fs/vfs.zig");
const ui = @import("../gui/ui.zig");

pub var open: bool = false;
var current: vfs.NodeHandle = vfs.INVALID_HANDLE;

const MENU_H: u32 = 16;
const TOOL_H: u32 = 24;
const ADDR_H: u32 = 20;
const STATUS_H: u32 = 18;
const TREE_W: u32 = 135;
const ROW_H: u32 = 18;

pub fn init() void {
    current = vfs.root;
}

pub fn showRoot() void {
    current = vfs.root;
    open = true;
}

pub fn currentNode() vfs.NodeHandle {
    return current;
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
    if (parent != vfs.INVALID_HANDLE) current = parent;
}

/// Jumps straight to a specific node (used by the "Documents" Start menu
/// item to open the explorer at /users/default instead of at the root).
pub fn navigateTo(handle: vfs.NodeHandle) void {
    if (handle != vfs.INVALID_HANDLE) current = handle;
}

fn safeCurrent() vfs.NodeHandle {
    if (current == vfs.INVALID_HANDLE) current = vfs.root;
    return current;
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

    var row: usize = 0;
    const count = vfs.childCount(cur);
    while (row < count) : (row += 1) {
        const child = vfs.childAt(cur, row);
        if (child == vfs.INVALID_HANDLE) continue;

        const ry = y + 6 + @as(u32, @intCast(row)) * ROW_H;
        if (ry + ROW_H >= y + h) break;

        const is_folder = vfs.kindOf(child) == .directory;
        const hx: u32 = if (hover_x < 0) 0 else @intCast(hover_x);
        const hy: u32 = if (hover_y < 0) 0 else @intCast(hover_y);
        const hovered = hx >= x and hx < x + w and hy >= ry and hy < ry + ROW_H;
        if (hovered) fb.fillRect(x + 2, ry, w - 4, ROW_H, 0xC0D8FF);
        drawIcon(x + 8, ry + 1, is_folder);
        fb.drawString(x + 30, ry + 6, vfs.nameOf(child), fb.CORE97_BLACK, if (hovered) 0xC0D8FF else fb.CORE97_WHITE);
    }
}

pub fn draw(x: u32, y: u32, w: u32, h: u32) void {
    const cur = safeCurrent();

    fb.fillRect(x, y, w, h, fb.CORE97_GREY);

    // Menu bar
    fb.fillRect(x, y, w, MENU_H, fb.CORE97_GREY);
    fb.drawString(x + 6, y + 5, "File", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 38, y + 5, "Edit", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 70, y + 5, "View", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 108, y + 5, "Tools", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 150, y + 5, "Help", fb.CORE97_BLACK, fb.CORE97_GREY);

    // Toolbar
    const ty = y + MENU_H;
    fb.fillRect(x, ty, w, TOOL_H, fb.CORE97_GREY);
    drawToolbarButton(x + 6, ty + 3, "<", canGoBack());
    drawToolbarButton(x + 32, ty + 3, "^", true);
    drawToolbarButton(x + 58, ty + 3, "X", true);
    drawToolbarButton(x + 84, ty + 3, "R", true);

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
    const by: i32 = ty + 3;
    return mx >= bx and mx < bx + 22 and my >= by and my < by + 18;
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

pub fn itemAt(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) ?vfs.NodeHandle {
    const body_y = y + MENU_H + TOOL_H + ADDR_H + 2;
    const right_x = x + 6 + TREE_W;
    const right_w = w - TREE_W - 10;
    const ix: i32 = @intCast(right_x);
    const iy: i32 = @intCast(body_y + 6);

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

pub fn activate(handle: vfs.NodeHandle) bool {
    if (handle == vfs.INVALID_HANDLE) return false;
    if (vfs.kindOf(handle) == .directory) {
        current = handle;
        return true;
    }
    return false;
}

pub const ContextAction = enum { none, new_folder, new_text };

var context_open: bool = false;
var context_x: u32 = 0;
var context_y: u32 = 0;
var hover_x: i32 = -1;
var hover_y: i32 = -1;

pub fn setHover(mx: i32, my: i32) void {
    hover_x = mx;
    hover_y = my;
}

pub fn openContextMenu(mx: i32, my: i32) void {
    context_open = true;
    context_x = if (mx < 0) 0 else @intCast(mx);
    context_y = if (my < 0) 0 else @intCast(my);
}

pub fn closeContextMenu() void {
    context_open = false;
}

pub fn contextContains(mx: i32, my: i32) bool {
    if (!context_open) return false;
    const x: i32 = @intCast(context_x);
    const y: i32 = @intCast(context_y);
    return mx >= x and mx < x + 150 and my >= y and my < y + 48;
}

pub fn contextActionAt(mx: i32, my: i32) ContextAction {
    if (!context_open) return .none;

    const x: i32 = @intCast(context_x);
    const y: i32 = @intCast(context_y);

    if (mx < x or mx >= x + 150) return .none;
    if (my < y or my >= y + 48) return .none;

    const row = @divTrunc(my - y, 24);
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
            context_open = false;
            return true;
        },
        .new_text => {
            _ = vfs.createUniqueTextFile(cur);
            context_open = false;
            return true;
        },
        .none => return false,
    }
}

pub fn drawContextMenu() void {
    if (!context_open) return;

    fb.fillRect(context_x + 4, context_y + 4, 150, 48, fb.CORE97_DARK_GREY);
    fb.fillRect(context_x, context_y, 150, 48, fb.CORE97_GREY);
    fb.draw3DBorder(context_x, context_y, 150, 48, true);

    const hx: u32 = if (hover_x < 0) 0 else @intCast(hover_x);
    const hy: u32 = if (hover_y < 0) 0 else @intCast(hover_y);

    const h0 = hx >= context_x and hx < context_x + 150 and hy >= context_y and hy < context_y + 24;
    const h1 = hx >= context_x and hx < context_x + 150 and hy >= context_y + 24 and hy < context_y + 48;

    if (h0) fb.fillRect(context_x + 2, context_y + 2, 146, 20, fb.CORE97_BLUE);
    if (h1) fb.fillRect(context_x + 2, context_y + 26, 146, 20, fb.CORE97_BLUE);

    fb.drawString(context_x + 8, context_y + 8, "New Folder", if (h0) fb.CORE97_WHITE else fb.CORE97_BLACK, if (h0) fb.CORE97_BLUE else fb.CORE97_GREY);
    fb.drawString(context_x + 8, context_y + 32, "New Text Document", if (h1) fb.CORE97_WHITE else fb.CORE97_BLACK, if (h1) fb.CORE97_BLUE else fb.CORE97_GREY);
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

fn insetOf(x: u32, y: u32, w: u32, h: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
    return .{
        .x = x + 8,
        .y = y + 8,
        .w = if (w > 16) w - 16 else 1,
        .h = if (h > 18) h - 18 else 1,
    };
}

pub const Explorer = struct {
    pub fn title(_: *Explorer) []const u8 {
        return "FILE EXPLORER";
    }

    pub fn titleDetail(_: *Explorer) []const u8 {
        return "";
    }

    pub fn draw(_: *Explorer, x: u32, y: u32, w: u32, h: u32) void {
        const a = insetOf(x, y, w, h);
        Self.draw(a.x, a.y, a.w, a.h);
        drawContextMenu();
    }

    pub fn onMouseDown(_: *Explorer, mx: i32, my: i32, button: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        const a = insetOf(x, y, w, h);

        if (button == .right) {
            openContextMenu(mx, my);
            return .none;
        }

        const ctx_action = contextActionAt(mx, my);
        switch (ctx_action) {
            .new_folder, .new_text => {
                _ = handleContextAction(ctx_action);
                closeContextMenu();
                return .none;
            },
            .none => {
                if (context_open) {
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
        if (itemAt(mx, my, a.x, a.y, a.w, a.h)) |handle| {
            if (!activate(handle) and vfs.kindOf(handle) == .file) {
                _ = notepad.loadFromVfsFile(handle);
                return .{ .open_builtin = .notepad };
            }
        }
        return .none;
    }

    pub fn onMouseDrag(_: *Explorer, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *Explorer) void {}
    pub fn onKeyAscii(_: *Explorer, _: u8) void {}
    pub fn onKeyUsb(_: *Explorer, _: u8, _: u8, _: u32) bool {
        return false;
    }

    pub fn hasModalCapture(_: *Explorer) bool {
        return context_open;
    }
};

// `Self.draw` above refers to the free draw() function defined earlier
// in this file (the real drawing code, untouched by the refactor) -
// `Self` is just this module, named so Explorer.draw and the module's
// own draw() don't collide.
const Self = @This();

var instance: Explorer = .{};

pub fn asApp() window.App {
    return window.appFrom(Explorer, &instance);
}
