// gui/taskbar.zig - taskbar and Core97-style Start menu drawing.

const fb = @import("framebuffer.zig");
const colors = @import("colors.zig");
const network = @import("../drivers/network.zig");
const rtc = @import("../drivers/rtc.zig");
const ui = @import("ui.zig");

pub const HEIGHT: u32 = 28; // 1x fallback for legacy callers
pub fn height() u32 { return HEIGHT * fb.uiScale(); }

const START_X: u32 = 2;
const START_W: u32 = 78;

const TASKBAR_BUTTONS_X: u32 = START_X + START_W + 8;
const TASKBAR_BUTTON_W: u32 = 110;
const TASKBAR_BUTTON_GAP: u32 = 6;

pub const TaskbarEntry = struct { title: []const u8, active: bool };

/// Geometry of the Nth taskbar button slot (0-indexed, left to right),
/// regardless of which window currently occupies it. Shared by drawing
/// and by WindowManager's minimize-animation target, so both always
/// agree on where a given window's button actually is.
pub fn buttonRect(slot: u32) struct { x: i32, y: i32, w: u32, h: u32 } {
    const task_y: i32 = @intCast(fb.fb_height - height());
    const x: i32 = @intCast(TASKBAR_BUTTONS_X + slot * (TASKBAR_BUTTON_W + TASKBAR_BUTTON_GAP));
    return .{ .x = x, .y = task_y + 2, .w = TASKBAR_BUTTON_W, .h = height() - 4 };
}

pub fn buttonHit(mx: i32, my: i32, slot: u32) bool {
    const r = buttonRect(slot);
    return mx >= r.x and mx < r.x + @as(i32, @intCast(r.w)) and my >= r.y and my < r.y + @as(i32, @intCast(r.h));
}

/// Which button slot (if any) was clicked, given how many windows have
/// a taskbar entry right now.
pub fn buttonSlotAt(mx: i32, my: i32, entry_count: u32) ?u32 {
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        if (buttonHit(mx, my, i)) return i;
    }
    return null;
}

const MENU_W_BASE: u32 = 188;
const SIDEBAR_W_BASE: u32 = 24;
const ROW_H_BASE: u32 = 22;
const ROW_COUNT: u32 = 6; // Programs, Documents, Settings, Find, Help, Run
const FLYOUT_W_BASE: u32 = 144;
const FLYOUT_ROW_H_BASE: u32 = 22;

fn menuW() u32 { return MENU_W_BASE * fb.uiScale(); }
fn sidebarW() u32 { return SIDEBAR_W_BASE * fb.uiScale(); }
fn rowH() u32 { return ROW_H_BASE * fb.uiScale(); }
fn menuH() u32 { return (10 + ROW_COUNT * ROW_H_BASE + 10 + ROW_H_BASE + 6) * fb.uiScale(); }
fn flyoutW() u32 { return FLYOUT_W_BASE * fb.uiScale(); }
fn flyoutRowH() u32 { return FLYOUT_ROW_H_BASE * fb.uiScale(); }

/// Formats the current RTC time as zero-padded "HH:MM" into a
/// caller-provided 5-byte buffer (no allocation - this runs every
/// taskbar redraw, including on every mouse move, so it stays as cheap
/// as the literal string it replaces).
fn formatClock(buf: *[5]u8) []const u8 {
    const t = rtc.nowEuropeStockholm();
    buf[0] = '0' + (t.hour / 10);
    buf[1] = '0' + (t.hour % 10);
    buf[2] = ':';
    buf[3] = '0' + (t.minute / 10);
    buf[4] = '0' + (t.minute % 10);
    return buf[0..5];
}

fn draw3DBorder(x: u32, y: u32, w: u32, h: u32, raised: bool) void {
    const light = if (raised) colors.WHITE else colors.DARK_GREY;
    const dark = if (raised) colors.DARK_GREY else colors.WHITE;
    fb.fillRect(x, y, w, 1, light);
    fb.fillRect(x, y, 1, h, light);
    fb.fillRect(x, y + h - 1, w, 1, dark);
    fb.fillRect(x + w - 1, y, 1, h, dark);
}

pub fn startButtonHit(mx: i32, my: i32) bool {
    const task_y: i32 = @intCast(fb.fb_height - height());
    return my >= task_y and mx >= @as(i32, @intCast(START_X)) and mx <= @as(i32, @intCast(START_X + START_W));
}

fn menuX() u32 { return 2; }
fn menuY() u32 { return fb.fb_height - height() - menuH(); }

fn rowY(row: u32) u32 { return menuY() + 10 + row * rowH(); }
fn shutdownRowY() u32 { return rowY(ROW_COUNT) + 6; }

fn rowHit(mx: i32, my: i32, row: u32) bool {
    const x: i32 = @intCast(menuX() + sidebarW() + 2);
    const y: i32 = @intCast(rowY(row));
    return mx >= x and mx < x + @as(i32, @intCast(menuW() - sidebarW() - 4)) and my >= y and my < y + @as(i32, @intCast(rowH()));
}

pub fn startMenuProgramsHit(mx: i32, my: i32) bool { return rowHit(mx, my, 0); }
pub fn startMenuDocumentsHit(mx: i32, my: i32) bool { return rowHit(mx, my, 1); }

pub fn startMenuShutdownHit(mx: i32, my: i32) bool {
    const x: i32 = @intCast(menuX() + sidebarW() + 2);
    const y: i32 = @intCast(shutdownRowY());
    return mx >= x and mx < x + @as(i32, @intCast(menuW() - sidebarW() - 4)) and my >= y and my < y + @as(i32, @intCast(rowH()));
}

/// Anywhere inside the main Start menu panel (used to decide whether a
/// click outside of it should close the menu).
pub fn startMenuContains(mx: i32, my: i32) bool {
    const x: i32 = @intCast(menuX());
    const y: i32 = @intCast(menuY());
    return mx >= x and mx < x + @as(i32, @intCast(menuW())) and my >= y and my < y + @as(i32, @intCast(menuH()));
}

fn flyoutX() u32 { return menuX() + menuW() - 2; }
fn flyoutY() u32 { return rowY(0); }
fn flyoutH() u32 { return 8 * flyoutRowH() + 8; }

fn flyoutRowHit(mx: i32, my: i32, row: u32) bool {
    const x: i32 = @intCast(flyoutX() + 2);
    const y: i32 = @intCast(flyoutY() + 4 + row * flyoutRowH());
    return mx >= x and mx < x + @as(i32, @intCast(flyoutW() - 4)) and my >= y and my < y + @as(i32, @intCast(flyoutRowH()));
}

pub fn programsFlyoutNotepadHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 0); }
pub fn programsFlyoutExplorerHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 1); }
pub fn programsFlyoutCounterHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 2); }
pub fn programsFlyoutDeviceManagerHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 3); }
pub fn programsFlyoutCommandPromptHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 4); }
pub fn programsFlyoutTaskManagerHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 5); }
pub fn programsFlyoutControlPanelHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 6); }
pub fn programsFlyoutBrowserHit(mx: i32, my: i32) bool { return flyoutRowHit(mx, my, 7); }

pub fn programsFlyoutContains(mx: i32, my: i32) bool {
    const x: i32 = @intCast(flyoutX());
    const y: i32 = @intCast(flyoutY());
    return mx >= x and mx < x + @as(i32, @intCast(flyoutW())) and my >= y and my < y + @as(i32, @intCast(flyoutH()));
}

fn ditherShadow(x: u32, y: u32, w: u32, h: u32) void {
    var yy: u32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < w) : (xx += 1) {
            if (((xx + yy) & 1) == 0) fb.putPixel(x + xx, y + yy, colors.DARK_GREY);
        }
    }
}

fn drawStartLogo(x: u32, y: u32) void {
    // Four-color Windows 95-style flag.
    fb.fillRect(x + 1, y + 2, 6, 5, 0xFF0000);
    fb.fillRect(x + 8, y + 1, 6, 5, 0x00A000);
    fb.fillRect(x + 1, y + 8, 6, 5, 0x0000C0);
    fb.fillRect(x + 8, y + 7, 6, 5, 0xFFFF00);
    fb.fillRect(x, y + 1, 1, 13, colors.BLACK);
}

fn drawFolderIcon(x: u32, y: u32) void {
    fb.fillRect(x, y + 5, 16, 10, 0xFFFF80);
    fb.fillRect(x + 2, y + 3, 8, 3, 0xFFFF80);
    draw3DBorder(x, y + 5, 16, 10, true);
}

fn drawDocIcon(x: u32, y: u32) void {
    fb.fillRect(x + 2, y + 2, 13, 15, colors.WHITE);
    draw3DBorder(x + 2, y + 2, 13, 15, true);
    fb.fillRect(x + 5, y + 7, 7, 1, colors.DARK_GREY);
    fb.fillRect(x + 5, y + 10, 7, 1, colors.DARK_GREY);
}

fn drawGearIcon(x: u32, y: u32) void {
    fb.fillRect(x + 3, y + 3, 10, 10, colors.DARK_GREY);
    fb.fillRect(x, y + 6, 16, 4, colors.DARK_GREY);
    fb.fillRect(x + 6, y, 4, 16, colors.DARK_GREY);
    fb.fillRect(x + 6, y + 6, 4, 4, colors.GREY);
}

fn drawFindIcon(x: u32, y: u32) void {
    draw3DBorder(x + 1, y + 1, 10, 10, false);
    fb.fillRect(x + 2, y + 2, 8, 8, colors.WHITE);
    fb.fillRect(x + 9, y + 9, 2, 2, colors.BLACK);
    fb.fillRect(x + 10, y + 10, 2, 2, colors.BLACK);
    fb.fillRect(x + 11, y + 11, 2, 2, colors.BLACK);
}

fn drawHelpIcon(x: u32, y: u32) void {
    fb.fillRect(x + 1, y + 1, 14, 14, colors.BLUE);
    fb.drawString(x + 5, y + 4, "?", colors.WHITE, colors.BLUE);
}

fn drawRunIcon(x: u32, y: u32) void {
    fb.fillRect(x + 1, y + 1, 14, 10, colors.WHITE);
    draw3DBorder(x + 1, y + 1, 14, 10, false);
    fb.fillRect(x + 4, y + 12, 8, 2, colors.DARK_GREY);
}


fn taskLooksLike(title: []const u8, needle: []const u8) bool {
    if (needle.len > title.len) return false;
    var i: usize = 0;
    while (i + needle.len <= title.len) : (i += 1) {
        var ok = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (title[i + j] != needle[j]) { ok = false; break; }
        }
        if (ok) return true;
    }
    return false;
}

fn drawComputerTiny(x: u32, y: u32) void {
    fb.fillRect(x + 2, y + 1, 13, 10, colors.GREY);
    draw3DBorder(x + 2, y + 1, 13, 10, true);
    fb.fillRect(x + 4, y + 3, 9, 5, colors.BLUE);
    fb.fillRect(x + 6, y + 12, 6, 2, colors.DARK_GREY);
}

fn drawTrashTiny(x: u32, y: u32) void {
    fb.fillRect(x + 4, y + 3, 9, 11, colors.GREY);
    draw3DBorder(x + 4, y + 3, 9, 11, true);
    fb.fillRect(x + 3, y + 1, 11, 3, colors.DARK_GREY);
    fb.drawString(x + 6, y + 6, "x", 0x008000, colors.GREY);
}

fn drawTaskIcon(title: []const u8, x: u32, y: u32) void {
    if (taskLooksLike(title, "TRASH")) {
        drawTrashTiny(x, y);
    } else if (taskLooksLike(title, "MY COMPUTER")) {
        drawComputerTiny(x, y);
    } else if (taskLooksLike(title, "CONTROL")) {
        drawGearIcon(x, y);
    } else if (taskLooksLike(title, "COMMAND")) {
        drawRunIcon(x, y);
    } else if (taskLooksLike(title, "NOTEPAD")) {
        drawDocIcon(x, y);
    } else {
        drawFolderIcon(x, y);
    }
}

fn drawPowerIcon(x: u32, y: u32) void {
    fb.fillRect(x + 6, y, 2, 8, colors.RED);
    fb.fillRect(x + 2, y + 4, 10, 10, colors.RED);
    fb.fillRect(x + 4, y + 6, 6, 6, colors.GREY);
}

fn drawArrow(x: u32, y: u32) void {
    fb.fillRect(x, y, 1, 7, colors.BLACK);
    fb.fillRect(x + 1, y + 1, 1, 5, colors.BLACK);
    fb.fillRect(x + 2, y + 2, 1, 3, colors.BLACK);
    fb.fillRect(x + 3, y + 3, 1, 1, colors.BLACK);
}

fn drawMenuRow(x: u32, y: u32, label: []const u8, enabled: bool, has_arrow: bool, icon: *const fn (u32, u32) void) void {
    const row_w = menuW() - sidebarW() - 4;
    const hovered = enabled and ui.hit(x - 2, y, row_w, rowH());
    const bg = if (hovered) colors.BLUE else colors.GREY;
    const fg = if (!enabled) colors.DARK_GREY else if (hovered) colors.WHITE else colors.BLACK;
    if (hovered) fb.fillRect(x - 2, y, row_w, rowH(), bg);
    icon(x + 2, y);
    fb.drawString(x + 24, y + 4, label, fg, bg);
    if (has_arrow) drawArrow(x + menuW() - sidebarW() - 16, y + 5);
}

fn drawStartMenu(programs_open: bool) void {
    const x = menuX();
    const y = menuY();
    ditherShadow(x + 5, y + 5, menuW(), menuH());
    fb.fillRect(x, y, menuW(), menuH(), colors.GREY);
    draw3DBorder(x, y, menuW(), menuH(), true);

    // Sidebar logo strip with rotated "CORE 97" text, like the real
    // the rotated logo text on a classic retro desktop sidebar.
    fb.fillRect(x + 3, y + 3, sidebarW(), menuH() - 6, colors.BLUE);
    fb.drawStringVertical(x + 9, y + 10, "CORE 97", colors.WHITE, colors.BLUE);
    drawStartLogo(x + 6, y + menuH() - 22);

    const item_x = x + sidebarW() + 4;
    drawMenuRow(item_x, rowY(0), "Programs", true, true, &drawFolderIcon);
    drawMenuRow(item_x, rowY(1), "Documents", true, true, &drawDocIcon);
    drawMenuRow(item_x, rowY(2), "Settings", false, true, &drawGearIcon);
    drawMenuRow(item_x, rowY(3), "Find", false, true, &drawFindIcon);
    drawMenuRow(item_x, rowY(4), "Help", false, false, &drawHelpIcon);
    drawMenuRow(item_x, rowY(5), "Run...", false, false, &drawRunIcon);

    fb.fillRect(x + sidebarW() + 6, shutdownRowY() - 4, menuW() - sidebarW() - 12, 1, colors.DARK_GREY);
    fb.fillRect(x + sidebarW() + 6, shutdownRowY() - 3, menuW() - sidebarW() - 12, 1, colors.WHITE);
    drawMenuRow(item_x, shutdownRowY(), "Shut Down...", true, false, &drawPowerIcon);

    if (programs_open) drawProgramsFlyout();
}

fn drawScriptIcon(x: u32, y: u32) void {
    fb.fillRect(x + 2, y + 2, 13, 15, colors.WHITE);
    draw3DBorder(x + 2, y + 2, 13, 15, true);
    fb.fillRect(x + 4, y + 5, 4, 1, 0x008000);
    fb.fillRect(x + 4, y + 8, 6, 1, 0x008000);
    fb.fillRect(x + 4, y + 11, 5, 1, 0x008000);
}


fn drawFlyoutRow(fx: u32, fy: u32, row: u32, label: []const u8, icon: *const fn (u32, u32) void) void {
    const y = fy + 4 + row * flyoutRowH();
    const hovered = ui.hit(fx + 2, y, flyoutW() - 4, flyoutRowH());
    const bg = if (hovered) colors.BLUE else colors.GREY;
    const fg = if (hovered) colors.WHITE else colors.BLACK;
    if (hovered) fb.fillRect(fx + 2, y, flyoutW() - 4, flyoutRowH(), bg);
    icon(fx + 6, y);
    fb.drawString(fx + 28, y + 5, label, fg, bg);
}

fn drawProgramsFlyout() void {
    const fx = flyoutX();
    const fy = flyoutY();
    const fh = flyoutH();
    ditherShadow(fx + 5, fy + 5, flyoutW(), fh);
    fb.fillRect(fx, fy, flyoutW(), fh, colors.GREY);
    draw3DBorder(fx, fy, flyoutW(), fh, true);

    drawFlyoutRow(fx, fy, 0, "Notepad", &drawDocIcon);
    drawFlyoutRow(fx, fy, 1, "File Explorer", &drawFolderIcon);
    drawFlyoutRow(fx, fy, 2, "Counter (Demo)", &drawScriptIcon);
    drawFlyoutRow(fx, fy, 3, "Device Manager", &drawGearIcon);
    drawFlyoutRow(fx, fy, 4, "Command Prompt", &drawRunIcon);
    drawFlyoutRow(fx, fy, 5, "Task Manager", &drawGearIcon);
    drawFlyoutRow(fx, fy, 6, "Control Panel", &drawGearIcon);
    drawFlyoutRow(fx, fy, 7, "Internet Browser", &drawFindIcon);
}

pub fn draw(start_menu_open: bool, programs_flyout_open: bool, entries: []const TaskbarEntry) void {
    const y = fb.fb_height - height();
    fb.fillRect(0, y, fb.fb_width, height(), colors.GREY);
    fb.fillRect(0, y, fb.fb_width, 1, colors.WHITE);
    fb.fillRect(0, y + 1, fb.fb_width, 1, 0xE8E8E8);

    const btn_x: u32 = START_X;
    const btn_y: u32 = y + 2;
    const btn_w: u32 = START_W;
    const btn_h: u32 = height() - 4;
    const start_hovered = ui.hit(btn_x, btn_y, btn_w, btn_h);
    _ = start_hovered;
    const start_bg = colors.GREY;
    fb.fillRect(btn_x, btn_y, btn_w, btn_h, start_bg);
    draw3DBorder(btn_x, btn_y, btn_w, btn_h, !start_menu_open);
    drawStartLogo(btn_x + 5, btn_y + 5);
    fb.drawString(btn_x + 23, btn_y + 8, "Start", colors.BLACK, start_bg);

    for (entries, 0..) |entry, i| {
        const r = buttonRect(@intCast(i));
        const ux: u32 = @intCast(r.x);
        const uy: u32 = @intCast(r.y);
        const hovered = ui.hit(ux, uy, r.w, r.h);
        _ = hovered;
        const bg = colors.GREY;
        fb.fillRect(ux, uy, r.w, r.h, bg);
        draw3DBorder(ux, uy, r.w, r.h, !entry.active);
        drawTaskIcon(entry.title, ux + 6, uy + 4);
        fb.drawString(ux + 28, uy + 7, entry.title, colors.BLACK, bg);
    }

    const clock_w: u32 = 66;
    const clock_x: u32 = fb.fb_width - clock_w - 2;
    const net_x: u32 = if (clock_x > 28) clock_x - 26 else clock_x;
    fb.fillRect(net_x, btn_y, 22, btn_h, colors.GREY);
    draw3DBorder(net_x, btn_y, 22, btn_h, false);
    const online = network.linkIsUp();
    fb.fillRect(net_x + 5, btn_y + 8, 11, 7, if (online) 0x00A000 else colors.DARK_GREY);
    fb.fillRect(net_x + 7, btn_y + 6, 7, 2, if (online) 0x00A000 else colors.DARK_GREY);
    if (!online) {
        fb.fillRect(net_x + 5, btn_y + 16, 11, 1, colors.RED);
        fb.fillRect(net_x + 10, btn_y + 11, 1, 9, colors.RED);
    }
    fb.fillRect(clock_x, btn_y, clock_w, btn_h, colors.GREY);
    draw3DBorder(clock_x, btn_y, clock_w, btn_h, false);
    var clock_buf: [5]u8 = undefined;
    fb.drawString(clock_x + 12, btn_y + 8, formatClock(&clock_buf), colors.BLACK, colors.GREY);

    if (start_menu_open) drawStartMenu(programs_flyout_open);
}
