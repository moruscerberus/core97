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
    manager.register(SLOT_EXPLORER, .explorer, explorer.asApp(), .{ .x = 80, .y = 80, .w = 340, .h = 260 });
    script_app.load("/apps/counter.ws", "COUNTER");
    manager.register(SLOT_COUNTER, .counter_demo, script_app.asApp(), .{ .x = 420, .y = 200, .w = 170, .h = 100 });
    manager.register(SLOT_DEVICE_MANAGER, .device_manager, device_manager.asApp(), .{ .x = 22, .y = 50, .w = 596, .h = 420 });
    manager.register(SLOT_COMMAND_PROMPT, .command_prompt, command_prompt.asAppAt(0), .{ .x = 70, .y = 90, .w = 560, .h = 310 });
    manager.register(SLOT_COMMAND_PROMPT_2, .command_prompt, command_prompt.asAppAt(1), .{ .x = 100, .y = 120, .w = 560, .h = 310 });
    manager.register(SLOT_COMMAND_PROMPT_3, .command_prompt, command_prompt.asAppAt(2), .{ .x = 130, .y = 150, .w = 560, .h = 310 });
    manager.register(SLOT_NOTEPAD_2, .notepad, notepad.asApp(), .{ .x = 230, .y = 180, .w = 400, .h = 300 });
    manager.register(SLOT_EXPLORER_2, .explorer, explorer.asApp(), .{ .x = 110, .y = 110, .w = 340, .h = 260 });
    manager.register(SLOT_TASK_MANAGER, .task_manager, task_manager.asApp(), .{ .x = 115, .y = 80, .w = 430, .h = 330 });
    manager.register(SLOT_CONTROL_PANEL, .control_panel, control_panel.asApp(), .{ .x = 92, .y = 70, .w = 520, .h = 340 });
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
        .explorer => {
            const slots = [_]usize{ SLOT_EXPLORER, SLOT_EXPLORER_2 };
            manager.restore(firstClosed(&slots) orelse SLOT_EXPLORER);
        },
        else => restoreBuiltin(kind),
    }
}

/// Explorer specifically has a "launch fresh" notion (jump back to the
/// root) that the Start menu / Notepad's File > Open use, as opposed to
/// just restoring it via its taskbar button, which leaves you wherever
/// you were browsing.
fn launchExplorerFresh() void {
    explorer.showRoot();
    restoreBuiltin(.explorer);
}

fn openDocuments() void {
    if (vfs.resolvePath("/users/default")) |h| explorer.navigateTo(h) else explorer.showRoot();
    restoreBuiltin(.explorer);
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
fn dialogY() u32 { return (fb.fb_height - taskbar.HEIGHT - DIALOG_H) / 2; }

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

// --- Scene drawing ---

fn drawSceneContents() void {
    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, fb.CORE97_TEAL);
    desktop_icons.draw();
    manager.drawAll();

    var entries_buf: [window.MAX_WINDOWS]taskbar.TaskbarEntry = undefined;
    const n = manager.taskbarEntries(&entries_buf);
    taskbar.draw(start_menu_open, programs_flyout_open, entries_buf[0..n]);

    drawShutdownDialog();
    cursor.draw(mouse.mouse_x, mouse.mouse_y);
}

pub fn redrawScene() void {
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
        const result = manager.handleMouseDown(mouse.mouse_x, mouse.mouse_y, button);
        handleAction(result.action);
        consumeTaskManagerRequests();
        consumeCommandPromptLaunch();

        if (result.slot == null and button == .left) {
            desktop_icons.onMouseDown(mouse.mouse_x, mouse.mouse_y);
            desktop_interaction_active = true;
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
                .open_my_computer => launchExplorerFresh(),
                .open_documents => openDocuments(),
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
