// gui/desktop.zig - desktop coordinator.
//
// Before the windowing refactor, this file held a separate copy of
// position/size/state/drag/chrome-click logic for Notepad and another
// copy for File Explorer, plus a hand-rolled z-order switch between the
// two. All of that generic "being a window" behavior now lives once in
// gui/window.zig's WindowManager; apps are just window.App values
// registered with it. What's left here is genuinely desktop-level:
// owning the manager, the Start menu, and the Shut Down dialog (none of
// which are themselves "windows").

const fb = @import("framebuffer.zig");
const mouse = @import("../drivers/mouse.zig");
const keyboard = @import("../drivers/keyboard.zig");
const pit = @import("../drivers/pit.zig");
const notepad = @import("../apps/notepad.zig");
const explorer = @import("../apps/file_explorer.zig");
const script_app = @import("../apps/script_app.zig");
const device_manager = @import("../apps/device_manager.zig");
const command_prompt = @import("../apps/command_prompt.zig");
const task_manager = @import("../apps/task_manager.zig");
const control_panel = @import("../apps/control_panel.zig");
const web_browser = @import("../apps/web_browser.zig");
const vfs = @import("../fs/vfs.zig");
const window = @import("window.zig");
const taskbar = @import("taskbar.zig");
const cursor = @import("cursor.zig");
const power = @import("../kernel/power.zig");
const ui = @import("ui.zig");
const desktop_icons = @import("desktop_icons.zig");
const audio = @import("../drivers/audio.zig");
const colors = @import("colors.zig");

const SLOT_NOTEPAD: usize = 0;
const SLOT_EXPLORER: usize = 1;
const SLOT_COUNTER: usize = 2;
const SLOT_DEVICE_MANAGER: usize = 3;
const SLOT_COMMAND_PROMPT: usize = 4;
const SLOT_COMMAND_PROMPT_2: usize = 5;
const SLOT_COMMAND_PROMPT_3: usize = 6;
const SLOT_NOTEPAD_2: usize = 7;
const SLOT_EXPLORER_2: usize = 8;
const SLOT_TASK_MANAGER: usize = 9;
const SLOT_CONTROL_PANEL: usize = 10;
const SLOT_WEB_BROWSER: usize = 11;
const SLOT_EXPLORER_3: usize = 12;
const SLOT_EXPLORER_4: usize = 13;
const SLOT_EXPLORER_5: usize = 14;
const SLOT_EXPLORER_6: usize = 15;

var manager: window.WindowManager = .{};

pub var start_menu_open: bool = false;
var programs_flyout_open: bool = false;
var shutdown_dialog_open: bool = false;
pub var usb_keyboard_present: bool = false;

fn closeStartMenu() void {
    start_menu_open = false;
    programs_flyout_open = false;
}

/// Registers the two built-in apps with their default rectangles. Call
/// once at boot, before the first redrawScene().
pub fn init() void {
    manager.register(SLOT_NOTEPAD, .notepad, notepad.asApp(), .{ .x = 200, .y = 150, .w = 400, .h = 300 });
    manager.register(SLOT_EXPLORER, .explorer, explorer.asAppAt(0), .{ .x = 80, .y = 80, .w = 520, .h = 360 });
    script_app.load("/apps/counter.ws", "COUNTER");
    manager.register(SLOT_COUNTER, .counter_demo, script_app.asApp(), .{ .x = 420, .y = 200, .w = 170, .h = 100 });
    manager.register(SLOT_DEVICE_MANAGER, .device_manager, device_manager.asApp(), .{ .x = 22, .y = 50, .w = 596, .h = 420 });
    manager.register(SLOT_COMMAND_PROMPT, .command_prompt, command_prompt.asAppAt(0), .{ .x = 70, .y = 90, .w = 560, .h = 310 });
    manager.register(SLOT_COMMAND_PROMPT_2, .command_prompt, command_prompt.asAppAt(1), .{ .x = 100, .y = 120, .w = 560, .h = 310 });
    manager.register(SLOT_COMMAND_PROMPT_3, .command_prompt, command_prompt.asAppAt(2), .{ .x = 130, .y = 150, .w = 560, .h = 310 });
    manager.register(SLOT_NOTEPAD_2, .notepad, notepad.asApp(), .{ .x = 230, .y = 180, .w = 400, .h = 300 });
    manager.register(SLOT_EXPLORER_2, .explorer, explorer.asAppAt(1), .{ .x = 110, .y = 110, .w = 520, .h = 360 });
    manager.register(SLOT_EXPLORER_3, .explorer, explorer.asAppAt(2), .{ .x = 140, .y = 140, .w = 520, .h = 360 });
    manager.register(SLOT_EXPLORER_4, .explorer, explorer.asAppAt(3), .{ .x = 170, .y = 170, .w = 520, .h = 360 });
    manager.register(SLOT_EXPLORER_5, .explorer, explorer.asAppAt(4), .{ .x = 200, .y = 80, .w = 520, .h = 360 });
    manager.register(SLOT_EXPLORER_6, .explorer, explorer.asAppAt(5), .{ .x = 230, .y = 110, .w = 520, .h = 360 });
    manager.register(SLOT_TASK_MANAGER, .task_manager, task_manager.asApp(), .{ .x = 115, .y = 80, .w = 430, .h = 330 });
    manager.register(SLOT_CONTROL_PANEL, .control_panel, control_panel.asApp(), .{ .x = 92, .y = 70, .w = 520, .h = 452 });
    manager.register(SLOT_WEB_BROWSER, .web_browser, web_browser.asApp(), .{ .x = 46, .y = 58, .w = 590, .h = 390 });
}

fn restoreBuiltin(kind: window.BuiltinApp) void {
    const slot = manager.findBuiltin(kind) orelse return;
    manager.restore(slot);
}

fn firstClosed(slots: []const usize) ?usize {
    var i: usize = 0;
    while (i < slots.len) : (i += 1) {
        if (!manager.isOpen(slots[i])) return slots[i];
    }
    return null;
}

fn launchBuiltin(kind: window.BuiltinApp) void {
    switch (kind) {
        .command_prompt => {
            const slots = [_]usize{ SLOT_COMMAND_PROMPT, SLOT_COMMAND_PROMPT_2, SLOT_COMMAND_PROMPT_3 };
            manager.restore(firstClosed(&slots) orelse SLOT_COMMAND_PROMPT);
        },
        .notepad => {
            const slots = [_]usize{ SLOT_NOTEPAD, SLOT_NOTEPAD_2 };
            manager.restore(firstClosed(&slots) orelse SLOT_NOTEPAD);
        },
        .explorer => launchExplorerFresh(),
        else => restoreBuiltin(kind),
    }
}

/// Explorer specifically has a "launch fresh" notion (jump back to the
/// root) that the Start menu / Notepad's File > Open use, as opposed to
/// just restoring it via its taskbar button, which leaves you wherever
/// you were browsing.
const ExplorerSlot = struct { slot: usize, id: usize };
const EXPLORER_POOL = [_]ExplorerSlot{
    .{ .slot = SLOT_EXPLORER, .id = 0 },
    .{ .slot = SLOT_EXPLORER_2, .id = 1 },
    .{ .slot = SLOT_EXPLORER_3, .id = 2 },
    .{ .slot = SLOT_EXPLORER_4, .id = 3 },
    .{ .slot = SLOT_EXPLORER_5, .id = 4 },
    .{ .slot = SLOT_EXPLORER_6, .id = 5 },
};

fn firstClosedExplorer() ExplorerSlot {
    for (EXPLORER_POOL) |entry| {
        if (!manager.isOpen(entry.slot)) return entry;
    }
    return EXPLORER_POOL[0];
}

fn openExplorerAt(handle: ?vfs.NodeHandle) void {
    const entry = firstClosedExplorer();
    if (handle) |h| {
        explorer.navigateToAt(entry.id, h);
    } else {
        explorer.showRootAt(entry.id);
    }
    manager.restore(entry.slot);
}

fn launchExplorerFresh() void {
    openExplorerAt(null);
}

fn openMyComputer() void {
    const entry = firstClosedExplorer();
    explorer.showComputerAt(entry.id);
    manager.restore(entry.slot);
}

fn openDocuments() void {
    const entry = firstClosedExplorer();
    explorer.showDocumentsAt(entry.id);
    manager.restore(entry.slot);
}

fn openTrash() void {
    const entry = firstClosedExplorer();
    explorer.showTrashAt(entry.id);
    manager.restore(entry.slot);
}

fn consumeCommandPromptLaunch() void {
    if (command_prompt.takeLaunchRequest()) |kind| {
        switch (kind) {
            .explorer => launchExplorerFresh(),
            else => launchBuiltin(kind),
        }
    }
}

fn consumeTaskManagerRequests() void {
    if (task_manager.takeSwitchRequest()) |slot| manager.forceSwitchTo(slot);
    if (task_manager.takeEndRequest()) |slot| manager.forceClose(slot);
}

fn handleAction(action: window.AppAction) void {
    switch (action) {
        .none, .close => {},
        .open_builtin => |kind| switch (kind) {
            .explorer => launchExplorerFresh(),
            else => launchBuiltin(kind),
        },
    }
}

// --- Shut Down dialog (desktop-level chrome, not a managed window) ---

const DIALOG_W: u32 = 280;
const DIALOG_H: u32 = 116;
fn dialogX() u32 { return (fb.fb_width - DIALOG_W) / 2; }
fn dialogY() u32 { return (fb.fb_height - taskbar.height() - DIALOG_H) / 2; }

const ShutdownButton = enum { none, shutdown, restart, cancel };
fn shutdownButtonRect(index: u32) window.Rect {
    const bw: u32 = 80;
    const bh: u32 = 22;
    const gap: u32 = 10;
    const total_w = bw * 3 + gap * 2;
    const bx = dialogX() + (DIALOG_W - total_w) / 2 + index * (bw + gap);
    const by = dialogY() + DIALOG_H - 36;
    return .{ .x = @intCast(bx), .y = @intCast(by), .w = bw, .h = bh };
}
fn shutdownButtonAt(mx: i32, my: i32) ShutdownButton {
    if (!shutdown_dialog_open) return .none;
    const labels = [_]ShutdownButton{ .shutdown, .restart, .cancel };
    var i: u32 = 0;
    while (i < labels.len) : (i += 1) {
        const r = shutdownButtonRect(i);
        if (mx >= r.x and mx < r.x + @as(i32, @intCast(r.w)) and my >= r.y and my < r.y + @as(i32, @intCast(r.h))) return labels[i];
    }
    return .none;
}

fn drawShutdownButton(index: u32, label: []const u8) void {
    const r = shutdownButtonRect(index);
    const ux: u32 = @intCast(r.x);
    const uy: u32 = @intCast(r.y);
    ui.drawButton(ux, uy, r.w, r.h, label, true);
}

fn drawShutdownDialog() void {
    if (!shutdown_dialog_open) return;
    const x = dialogX();
    const y = dialogY();
    fb.fillRect(x, y, DIALOG_W, DIALOG_H, fb.CORE97_GREY);
    fb.draw3DBorder(x, y, DIALOG_W, DIALOG_H, true);
    fb.fillRect(x + 2, y + 2, DIALOG_W - 4, 18, fb.CORE97_BLUE);
    fb.drawString(x + 8, y + 7, "SHUT DOWN CORE97", fb.CORE97_WHITE, fb.CORE97_BLUE);
    fb.drawString(x + 16, y + 32, "Are you sure you want to:", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 24, y + 50, "Shut down the computer, or", fb.CORE97_BLACK, fb.CORE97_GREY);
    fb.drawString(x + 24, y + 64, "restart the computer?", fb.CORE97_BLACK, fb.CORE97_GREY);
    drawShutdownButton(0, "Shut Down");
    drawShutdownButton(1, "Restart");
    drawShutdownButton(2, "Cancel");
}

// --- Desktop context menu ---

const DESKTOP_MENU_W: u32 = 162;
const DESKTOP_MENU_ROW_H: u32 = 18;
const DESKTOP_MENU_ROWS: u32 = 9;
const DESKTOP_MENU_H: u32 = DESKTOP_MENU_ROWS * DESKTOP_MENU_ROW_H + 8;
const DESKTOP_SUBMENU_W: u32 = 136;
const DESKTOP_SUBMENU_ROWS: u32 = 5;
const DESKTOP_SUBMENU_H: u32 = DESKTOP_SUBMENU_ROWS * DESKTOP_MENU_ROW_H + 8;

const DesktopMenuAction = enum { none, open_explorer, refresh, new_menu, new_folder, new_text, new_bitmap, new_wave, new_shortcut, change_wallpaper, properties };

var desktop_menu_open: bool = false;
var desktop_menu_x: u32 = 0;
var desktop_menu_y: u32 = 0;
var desktop_new_submenu_open: bool = false;
var desktop_new_submenu_x: u32 = 0;
var desktop_new_submenu_y: u32 = 0;
var wallpaper_index: usize = 0;

fn closeDesktopMenu() void {
    desktop_menu_open = false;
    desktop_new_submenu_open = false;
}

fn openDesktopMenu(mx: i32, my: i32) void {
    closeStartMenu();
    desktop_menu_open = true;
    var x: u32 = if (mx < 0) 0 else @intCast(mx);
    var y: u32 = if (my < 0) 0 else @intCast(my);
    if (x + DESKTOP_MENU_W + DESKTOP_SUBMENU_W > fb.fb_width) {
        if (x + DESKTOP_MENU_W > fb.fb_width) x = fb.fb_width - DESKTOP_MENU_W;
    }
    const max_y = fb.fb_height - taskbar.height();
    if (y + DESKTOP_MENU_H > max_y) y = if (max_y > DESKTOP_MENU_H) max_y - DESKTOP_MENU_H else 0;
    desktop_menu_x = x;
    desktop_menu_y = y;
    desktop_new_submenu_x = if (x + DESKTOP_MENU_W + DESKTOP_SUBMENU_W < fb.fb_width) x + DESKTOP_MENU_W - 2 else if (x > DESKTOP_SUBMENU_W) x - DESKTOP_SUBMENU_W + 2 else x;
    desktop_new_submenu_y = y + 2 * DESKTOP_MENU_ROW_H + 4;
    if (desktop_new_submenu_y + DESKTOP_SUBMENU_H > max_y) desktop_new_submenu_y = if (max_y > DESKTOP_SUBMENU_H) max_y - DESKTOP_SUBMENU_H else 0;
}

fn rectContains(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) bool {
    const ix: i32 = @intCast(x);
    const iy: i32 = @intCast(y);
    return mx >= ix and mx < ix + @as(i32, @intCast(w)) and my >= iy and my < iy + @as(i32, @intCast(h));
}

fn desktopMenuContains(mx: i32, my: i32) bool {
    if (!desktop_menu_open) return false;
    if (rectContains(mx, my, desktop_menu_x, desktop_menu_y, DESKTOP_MENU_W, DESKTOP_MENU_H)) return true;
    return desktop_new_submenu_open and rectContains(mx, my, desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, DESKTOP_SUBMENU_H);
}

fn desktopMenuMainRowAt(mx: i32, my: i32) i32 {
    if (!rectContains(mx, my, desktop_menu_x, desktop_menu_y, DESKTOP_MENU_W, DESKTOP_MENU_H)) return -1;
    const y: i32 = @intCast(desktop_menu_y);
    return @divTrunc(my - y - 4, @as(i32, @intCast(DESKTOP_MENU_ROW_H)));
}

fn desktopSubmenuRowAt(mx: i32, my: i32) i32 {
    if (!desktop_new_submenu_open or !rectContains(mx, my, desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, DESKTOP_SUBMENU_H)) return -1;
    const y: i32 = @intCast(desktop_new_submenu_y);
    return @divTrunc(my - y - 4, @as(i32, @intCast(DESKTOP_MENU_ROW_H)));
}

fn updateDesktopSubmenuHover() void {
    const row = desktopMenuMainRowAt(mouse.mouse_x, mouse.mouse_y);
    if (row == 2 or desktopSubmenuRowAt(mouse.mouse_x, mouse.mouse_y) >= 0) {
        desktop_new_submenu_open = true;
    } else if (row >= 0) {
        desktop_new_submenu_open = false;
    }
}

fn desktopMenuActionAt(mx: i32, my: i32) DesktopMenuAction {
    const sub = desktopSubmenuRowAt(mx, my);
    if (sub >= 0) return switch (sub) {
        0 => .new_folder,
        1 => .new_shortcut,
        2 => .new_text,
        3 => .new_bitmap,
        4 => .new_wave,
        else => .none,
    };
    const row = desktopMenuMainRowAt(mx, my);
    return switch (row) {
        0 => .open_explorer,
        1 => .refresh,
        2 => .new_menu,
        3 => .new_folder,
        4 => .new_text,
        5 => .none,
        6 => .change_wallpaper,
        7 => .properties,
        else => .none,
    };
}

fn defaultUserFolder() vfs.NodeHandle {
    return vfs.resolvePath("/users/default") orelse vfs.root;
}

fn createUniqueDesktopFile(base: []const u8, second: []const u8, third: []const u8, contents: []const u8) void {
    const parent = defaultUserFolder();
    const name = if (vfs.findChild(parent, base) == null) base else if (vfs.findChild(parent, second) == null) second else if (vfs.findChild(parent, third) == null) third else return;
    if (vfs.createNode(parent, name, .file)) |file| {
        _ = vfs.writeFile(file, contents);
    }
}

fn cycleWallpaper() void {
    wallpaper_index += 1;
    if (wallpaper_index >= colors.BACKGROUND_PRESETS.len) wallpaper_index = 0;
    colors.desktop_background = colors.BACKGROUND_PRESETS[wallpaper_index].color;
}

fn handleDesktopMenuAction(action: DesktopMenuAction) void {
    switch (action) {
        .open_explorer => launchExplorerFresh(),
        .refresh => {},
        .new_folder => {
            _ = vfs.createUniqueFolder(defaultUserFolder());
            openDocuments();
        },
        .new_text => {
            _ = vfs.createUniqueTextFile(defaultUserFolder());
            openDocuments();
        },
        .new_bitmap => {
            createUniqueDesktopFile("New Bitmap Image.bmp", "New Bitmap Image 2.bmp", "New Bitmap Image 3.bmp", "BM");
            openDocuments();
        },
        .new_wave => {
            createUniqueDesktopFile("New Wave Sound.wav", "New Wave Sound 2.wav", "New Wave Sound 3.wav", "RIFF....WAVE");
            openDocuments();
        },
        .new_shortcut => {
            createUniqueDesktopFile("New Shortcut.lnk", "New Shortcut 2.lnk", "New Shortcut 3.lnk", "Core97 shortcut\n");
            openDocuments();
        },
        .change_wallpaper => cycleWallpaper(),
        .properties => launchBuiltin(.control_panel),
        .new_menu, .none => {},
    }
}

fn drawTinyRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    fb.fillRect(x, y, w, 1, color);
    fb.fillRect(x, y + h - 1, w, 1, color);
    fb.fillRect(x, y, 1, h, color);
    fb.fillRect(x + w - 1, y, 1, h, color);
}

fn drawSmallIcon(x: u32, y: u32, kind: DesktopMenuAction, selected: bool) void {
    const bg = if (selected) fb.CORE97_BLUE else fb.CORE97_GREY;
    const fg = if (selected) fb.CORE97_WHITE else fb.CORE97_BLACK;
    switch (kind) {
        .open_explorer, .new_folder => {
            fb.fillRect(x, y + 5, 13, 9, 0xFFFF00);
            fb.fillRect(x + 2, y + 3, 7, 3, 0xFFFF00);
            drawTinyRect(x, y + 5, 13, 9, fg);
        },
        .refresh => {
            fb.drawString(x + 1, y + 5, "R", fg, bg);
        },
        .new_text => {
            fb.fillRect(x + 2, y + 2, 10, 13, fb.CORE97_WHITE);
            drawTinyRect(x + 2, y + 2, 10, 13, fg);
            fb.fillRect(x + 4, y + 6, 6, 1, fg);
            fb.fillRect(x + 4, y + 9, 6, 1, fg);
        },
        .new_bitmap => {
            fb.fillRect(x + 2, y + 2, 11, 12, fb.CORE97_WHITE);
            drawTinyRect(x + 2, y + 2, 11, 12, fg);
            fb.fillRect(x + 4, y + 9, 3, 3, 0x0000FF);
            fb.fillRect(x + 8, y + 6, 3, 6, 0x00AA00);
        },
        .new_wave => {
            fb.drawString(x + 1, y + 5, "~", fg, bg);
        },
        .new_shortcut => {
            fb.fillRect(x + 3, y + 4, 9, 9, fb.CORE97_WHITE);
            drawTinyRect(x + 3, y + 4, 9, 9, fg);
            fb.drawString(x, y + 6, ">", fg, bg);
        },
        .change_wallpaper => {
            fb.fillRect(x + 1, y + 3, 13, 10, fb.CORE97_BLUE);
            drawTinyRect(x + 1, y + 3, 13, 10, fg);
        },
        .properties => {
            fb.drawString(x + 2, y + 5, "i", fg, bg);
        },
        else => {},
    }
}

fn drawMenuRowAt(menu_x: u32, menu_y: u32, menu_w: u32, row: u32, label: []const u8, icon: DesktopMenuAction, enabled: bool, arrow: bool) void {
    const x = menu_x + 2;
    const y = menu_y + 4 + row * DESKTOP_MENU_ROW_H;
    const hx: u32 = if (mouse.mouse_x < 0) 0 else @intCast(mouse.mouse_x);
    const hy: u32 = if (mouse.mouse_y < 0) 0 else @intCast(mouse.mouse_y);
    const hover = enabled and hx >= x and hx < x + menu_w - 4 and hy >= y and hy < y + DESKTOP_MENU_ROW_H;
    if (hover) fb.fillRect(x, y, menu_w - 4, DESKTOP_MENU_ROW_H, fb.CORE97_BLUE);
    drawSmallIcon(x + 5, y + 1, icon, hover);
    fb.drawString(x + 28, y + 6, label, if (enabled and hover) fb.CORE97_WHITE else if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY, if (enabled and hover) fb.CORE97_BLUE else fb.CORE97_GREY);
    if (arrow) fb.drawString(menu_x + menu_w - 14, y + 6, ">", if (hover) fb.CORE97_WHITE else fb.CORE97_BLACK, if (hover) fb.CORE97_BLUE else fb.CORE97_GREY);
}

fn drawDesktopMenuRow(row: u32, label: []const u8, icon: DesktopMenuAction, enabled: bool, arrow: bool) void {
    drawMenuRowAt(desktop_menu_x, desktop_menu_y, DESKTOP_MENU_W, row, label, icon, enabled, arrow);
}

fn drawMenuSeparator(menu_x: u32, menu_y: u32, menu_w: u32, row: u32) void {
    const y = menu_y + 4 + row * DESKTOP_MENU_ROW_H + 9;
    fb.fillRect(menu_x + 4, y, menu_w - 8, 1, fb.CORE97_DARK_GREY);
    fb.fillRect(menu_x + 4, y + 1, menu_w - 8, 1, fb.CORE97_WHITE);
}

fn drawDesktopMenuSeparator(row: u32) void {
    drawMenuSeparator(desktop_menu_x, desktop_menu_y, DESKTOP_MENU_W, row);
}

fn drawPopupPanel(x: u32, y: u32, w: u32, h: u32) void {
    fb.fillRect(x + 3, y + 3, w, h, fb.CORE97_DARK_GREY);
    fb.fillRect(x, y, w, h, fb.CORE97_GREY);
    fb.draw3DBorder(x, y, w, h, true);
}

fn drawDesktopContextMenu() void {
    if (!desktop_menu_open) return;
    updateDesktopSubmenuHover();
    drawPopupPanel(desktop_menu_x, desktop_menu_y, DESKTOP_MENU_W, DESKTOP_MENU_H);

    drawDesktopMenuRow(0, "Open Explorer", .open_explorer, true, false);
    drawDesktopMenuRow(1, "Refresh", .refresh, true, false);
    drawDesktopMenuRow(2, "New", .new_menu, true, true);
    drawDesktopMenuRow(3, "New Folder", .new_folder, true, false);
    drawDesktopMenuRow(4, "New Text Document", .new_text, true, false);
    drawDesktopMenuSeparator(5);
    drawDesktopMenuRow(6, "Change Wallpaper...", .change_wallpaper, true, false);
    drawDesktopMenuRow(7, "Properties", .properties, true, false);

    if (desktop_new_submenu_open) {
        drawPopupPanel(desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, DESKTOP_SUBMENU_H);
        drawMenuRowAt(desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, 0, "Folder", .new_folder, true, false);
        drawMenuRowAt(desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, 1, "Shortcut", .new_shortcut, true, false);
        drawMenuRowAt(desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, 2, "Text Document", .new_text, true, false);
        drawMenuRowAt(desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, 3, "Bitmap Image", .new_bitmap, true, false);
        drawMenuRowAt(desktop_new_submenu_x, desktop_new_submenu_y, DESKTOP_SUBMENU_W, 4, "Wave Sound", .new_wave, true, false);
    }
}

// --- Scene drawing ---

fn drawDesktopWallpaper() void {
    // A faithful Windows 95 desktop is a flat color field, but make it
    // user-changeable through the desktop context menu / Control Panel.
    fb.fillRect(0, 0, fb.fb_width, fb.fb_height - taskbar.height(), colors.desktop_background);
}

fn drawSceneContents() void {
    drawDesktopWallpaper();
    desktop_icons.draw();
    manager.drawAll();
    drawDesktopContextMenu();

    var entries_buf: [window.MAX_WINDOWS]taskbar.TaskbarEntry = undefined;
    const n = manager.taskbarEntries(&entries_buf);
    taskbar.draw(start_menu_open, programs_flyout_open, entries_buf[0..n]);

    drawShutdownDialog();
    cursor.draw(mouse.mouse_x, mouse.mouse_y);
}

var seen_resize_generation: u32 = 0;

fn handleScreenResizeIfNeeded() void {
    if (seen_resize_generation == fb.resize_generation) return;
    seen_resize_generation = fb.resize_generation;
    desktop_icons.onScreenResize();
    manager.onScreenResize();
    closeStartMenu();
    closeDesktopMenu();
}

pub fn redrawScene() void {
    handleScreenResizeIfNeeded();
    drawSceneContents();
    fb.presentFrame();
}

// --- Input ---

var prev_left_button: bool = false;
var prev_right_button: bool = false;
var last_hover_redraw_tick: u32 = 0;
// True while a desktop-icon drag or rubber-band selection (see
// desktop_icons.zig) is in progress - lets the mouse-move/release
// handling below route to desktop_icons instead of the window manager's
// own dragging/resizing logic, which doesn't apply since no window slot
// was involved in starting this interaction.
var desktop_interaction_active: bool = false;

pub fn onMouseUpdate() void {
    ui.setHover(mouse.mouse_x, mouse.mouse_y);
    explorer.setHover(mouse.mouse_x, mouse.mouse_y);

    const right_pressed = (mouse.right_button and !prev_right_button) or (mouse.left_button and mouse.right_button);
    const just_pressed = mouse.left_button and !prev_left_button;

    if (just_pressed) audio.clickSound();

    if (just_pressed or right_pressed) {
        if (shutdown_dialog_open) {
            if (just_pressed) {
                switch (shutdownButtonAt(mouse.mouse_x, mouse.mouse_y)) {
                    .shutdown => power.shutdown(),
                    .restart => power.reboot(),
                    .cancel => shutdown_dialog_open = false,
                    .none => {},
                }
            }
            prev_left_button = mouse.left_button;
            prev_right_button = mouse.right_button;
            redrawScene();
            return;
        }

        if (just_pressed and taskbar.startButtonHit(mouse.mouse_x, mouse.mouse_y)) {
            closeDesktopMenu();
            if (start_menu_open) closeStartMenu() else start_menu_open = true;
            prev_left_button = mouse.left_button;
            prev_right_button = mouse.right_button;
            redrawScene();
            return;
        }

        if (just_pressed and start_menu_open) {
            var handled = true;
            if (programs_flyout_open and taskbar.programsFlyoutNotepadHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.notepad);
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutExplorerHit(mouse.mouse_x, mouse.mouse_y)) {
                launchExplorerFresh();
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutCounterHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.counter_demo);
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutDeviceManagerHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.device_manager);
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutCommandPromptHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.command_prompt);
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutTaskManagerHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.task_manager);
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutControlPanelHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.control_panel);
                closeStartMenu();
            } else if (programs_flyout_open and taskbar.programsFlyoutBrowserHit(mouse.mouse_x, mouse.mouse_y)) {
                launchBuiltin(.web_browser);
                closeStartMenu();
            } else if (taskbar.startMenuProgramsHit(mouse.mouse_x, mouse.mouse_y)) {
                programs_flyout_open = !programs_flyout_open;
            } else if (taskbar.startMenuDocumentsHit(mouse.mouse_x, mouse.mouse_y)) {
                openDocuments();
                closeStartMenu();
            } else if (taskbar.startMenuShutdownHit(mouse.mouse_x, mouse.mouse_y)) {
                closeStartMenu();
                shutdown_dialog_open = true;
            } else {
                const inside_menu = taskbar.startMenuContains(mouse.mouse_x, mouse.mouse_y) or
                    (programs_flyout_open and taskbar.programsFlyoutContains(mouse.mouse_x, mouse.mouse_y));
                if (!inside_menu) closeStartMenu();
                handled = false;
            }
            if (handled) {
                prev_left_button = mouse.left_button;
                prev_right_button = mouse.right_button;
                redrawScene();
                return;
            }
        }

        if (just_pressed) {
            var entries_buf: [window.MAX_WINDOWS]taskbar.TaskbarEntry = undefined;
            const n = manager.taskbarEntries(&entries_buf);
            if (taskbar.buttonSlotAt(mouse.mouse_x, mouse.mouse_y, @intCast(n))) |idx| {
                if (manager.slotAtTaskbarIndex(idx)) |slot| {
                    manager.restore(slot);
                    prev_left_button = mouse.left_button;
                    prev_right_button = mouse.right_button;
                    redrawScene();
                    return;
                }
            }
        }

        const button: window.MouseButton = if (right_pressed) .right else .left;

        if (desktop_menu_open and button == .left) {
            const action = desktopMenuActionAt(mouse.mouse_x, mouse.mouse_y);
            if (action == .new_menu) {
                desktop_new_submenu_open = true;
            } else {
                closeDesktopMenu();
                handleDesktopMenuAction(action);
            }
            prev_left_button = mouse.left_button;
            prev_right_button = mouse.right_button;
            redrawScene();
            return;
        }

        if (button == .right) closeDesktopMenu();

        const result = manager.handleMouseDown(mouse.mouse_x, mouse.mouse_y, button);
        handleAction(result.action);
        consumeTaskManagerRequests();
        consumeCommandPromptLaunch();

        if (result.slot == null) {
            if (button == .left) {
                desktop_icons.onMouseDown(mouse.mouse_x, mouse.mouse_y);
                desktop_interaction_active = true;
            } else {
                openDesktopMenu(mouse.mouse_x, mouse.mouse_y);
            }
        }

        prev_left_button = mouse.left_button;
        prev_right_button = mouse.right_button;
        redrawScene();
        return;
    }

    if (desktop_interaction_active) {
        if (mouse.left_button) {
            desktop_icons.onMouseDrag(mouse.mouse_x, mouse.mouse_y);
        } else {
            switch (desktop_icons.onMouseUp()) {
                .none => {},
                .open_my_computer => openMyComputer(),
                .open_documents => openDocuments(),
                .open_explorer => launchExplorerFresh(),
                .open_control_panel => launchBuiltin(.control_panel),
                .open_trash => openTrash(),
            }
            desktop_interaction_active = false;
        }
        prev_left_button = mouse.left_button;
        prev_right_button = mouse.right_button;
        redrawScene();
        return;
    }

    if (mouse.left_button) {
        if (manager.dragging != null or manager.resizing != null) {
            manager.handleMouseMove(mouse.mouse_x, mouse.mouse_y, true);
        } else if (manager.focused()) |slot| {
            manager.forwardDrag(slot, mouse.mouse_x, mouse.mouse_y);
        }
    } else {
        manager.handleMouseMove(mouse.mouse_x, mouse.mouse_y, false);
        if (manager.focused()) |slot| manager.forwardMouseUp(slot);
    }

    prev_left_button = mouse.left_button;
    prev_right_button = mouse.right_button;

    // Throttle plain-hover redraws to once per PIT tick (~100Hz) instead
    // of once per mouse packet - see kernel/power.zig-adjacent notes in
    // the perf pass for why this matters.
    if (pit.ticks == last_hover_redraw_tick) return;
    last_hover_redraw_tick = pit.ticks;
    redrawScene();
}

pub fn onKeyPress(ascii: u8) void {
    // Always keep PS/2 ASCII as a usable fallback. USB HID may coexist,
    // but it must never make normal typing disappear.
    const slot = manager.focused() orelse return;
    if (!manager.isVisible(slot)) return;
    (manager.windows[slot].?).app.onKeyAscii(ascii);
    consumeCommandPromptLaunch();
    consumeTaskManagerRequests();
    redrawScene();
}

pub fn onKeyEvent(ev: keyboard.KeyEvent) void {
    if (!ev.pressed) return;
    if (ev.code == 0xE3 or ev.code == 0xE7 or (ev.modifiers & 0x88) != 0) {
        toggleStartMenu();
        redrawScene();
        return;
    }
    // Alt+Tab: cycles to the next open window (manager.cycleFocus()'s
    // own comment has the z-order details). 0x2B is Tab's USB-HID code
    // (see keyboard.zig's scancode table); 0x44 is left-or-right Alt.
    if (ev.code == 0x2B and (ev.modifiers & 0x44) != 0) {
        manager.cycleFocus();
        redrawScene();
        return;
    }
    const slot = manager.focused() orelse return;
    if (!manager.isVisible(slot)) return;
    if (ev.code != 0) {
        const area = manager.contentArea(slot);
        if ((manager.windows[slot].?).app.onKeyUsb(ev.code, ev.modifiers, area.w)) {
            consumeCommandPromptLaunch();
            consumeTaskManagerRequests();
            redrawScene();
        }
    }
}

pub fn onUsbKey(code: u8, modifiers: u8) bool {
    const slot = manager.focused() orelse return false;
    if (!manager.isVisible(slot)) return false;
    const area = manager.contentArea(slot);
    const changed = (manager.windows[slot].?).app.onKeyUsb(code, modifiers, area.w);
    if (changed) {
        consumeCommandPromptLaunch();
        consumeTaskManagerRequests();
    }
    return changed;
}

pub fn toggleStartMenu() void {
    if (start_menu_open) closeStartMenu() else start_menu_open = true;
}
