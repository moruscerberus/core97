// apps/control_panel.zig - Core97-style Control Panel with real pages.
//
// Used to be one long scrolling list with Display settings, NTP, and
// Network all stacked in the same window - functional, but not how an
// actual OS's Control Panel works (separate applet pages, one visible
// at a time). Restructured into a small tab bar (Display / Date&Time /
// Network / Sound / Background) with each page owning its own draw +
// click handling, dispatched from one shared shell.

const fb = @import("../gui/framebuffer.zig");
const window = @import("../gui/window.zig");
const network = @import("../drivers/network.zig");
const vbe = @import("../drivers/vbe.zig");
const rtc = @import("../drivers/rtc.zig");
const audio = @import("../drivers/audio.zig");
const colors = @import("../gui/colors.zig");
const ui = @import("../gui/ui.zig");

const Resolution = struct { w: u32, h: u32 };
const PRESETS = [_]Resolution{
    .{ .w = 800, .h = 600 },
    .{ .w = 1024, .h = 768 },
    .{ .w = 1280, .h = 720 },
    .{ .w = 1920, .h = 1080 },
};

const Page = enum { display, datetime, network, sound, background };
const TABS = [_]struct { page: Page, label: []const u8 }{
    .{ .page = .display, .label = "Display" },
    .{ .page = .datetime, .label = "Date/Time" },
    .{ .page = .network, .label = "Network" },
    .{ .page = .sound, .label = "Sound" },
    .{ .page = .background, .label = "Background" },
};
const TAB_W: u32 = 96;
const TAB_H: u32 = 22;
const TAB_BAR_Y_OFFSET: u32 = 8;
const PAGE_Y_OFFSET: u32 = 36;

var current_page: Page = .display;

// Local editable copy of the NTP server address (network.zig owns the
// actual value used when syncing - this just mirrors it while the field
// is being typed into, and pushes each change straight back via
// network.setNtpServerAddress() so there's no separate "commit" step:
// the Sync Time button always uses whatever's currently in the field).
var ntp_edit_buf: [64]u8 = undefined;
var ntp_edit_len: usize = 0;
var ntp_edit_initialized: bool = false;
var ntp_field_focused: bool = false;

fn ensureNtpEditInitialized() void {
    if (ntp_edit_initialized) return;
    ntp_edit_initialized = true;
    const current = network.ntpServerAddress();
    var i: usize = 0;
    while (i < current.len and i < ntp_edit_buf.len) : (i += 1) ntp_edit_buf[i] = current[i];
    ntp_edit_len = current.len;
}

// --- Small text helpers shared by every page ---
fn append(buf: []u8, pos: *usize, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len and pos.* < buf.len) : (i += 1) { buf[pos.*] = text[i]; pos.* += 1; }
}
fn dec(buf: []u8, pos: *usize, v: u8) void {
    if (v >= 100) { buf[pos.*] = '0' + @as(u8, @intCast(v / 100)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast((v / 10) % 10)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast(v % 10)); pos.* += 1; }
    else if (v >= 10) { buf[pos.*] = '0' + @as(u8, @intCast(v / 10)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast(v % 10)); pos.* += 1; }
    else { buf[pos.*] = '0' + v; pos.* += 1; }
}
fn decU32(buf: []u8, pos: *usize, value: u32) void {
    if (value == 0) { buf[pos.*] = '0'; pos.* += 1; return; }
    var tmp: [10]u8 = undefined;
    var n = value;
    var len: usize = 0;
    while (n > 0) { tmp[len] = @as(u8, @intCast(n % 10)) + '0'; n /= 10; len += 1; }
    var i: usize = 0;
    while (i < len and pos.* < buf.len) : (i += 1) { buf[pos.*] = tmp[len - 1 - i]; pos.* += 1; }
}
/// Like decU32, but always exactly 2 digits (zero-padded) - for
/// month/day/hour/minute, where "6" should read as "06".
fn decU32Padded2(buf: []u8, pos: *usize, value: u32) void {
    if (pos.* + 2 > buf.len) return;
    buf[pos.*] = '0' + @as(u8, @intCast((value / 10) % 10));
    buf[pos.* + 1] = '0' + @as(u8, @intCast(value % 10));
    pos.* += 2;
}
fn drawIp(x: u32, y: u32, label: []const u8, ip: [4]u8) void {
    var buf: [80]u8 = undefined;
    var p: usize = 0;
    append(&buf, &p, label); append(&buf, &p, ": "); dec(&buf, &p, ip[0]); append(&buf, &p, "."); dec(&buf, &p, ip[1]); append(&buf, &p, "."); dec(&buf, &p, ip[2]); append(&buf, &p, "."); dec(&buf, &p, ip[3]);
    fb.drawString(x, y, buf[0..p], fb.CORE97_BLACK, fb.CORE97_WHITE);
}
fn drawResButton(x: u32, y: u32, res: Resolution) void {
    var buf: [16]u8 = undefined;
    var p: usize = 0;
    decU32(&buf, &p, res.w);
    append(&buf, &p, "x");
    decU32(&buf, &p, res.h);
    ui.drawButton(x, y, 82, 22, buf[0..p], true);
}

fn drawTabBar(x: u32, y: u32) void {
    var tab_x = x + 8;
    for (TABS) |t| {
        const active = current_page == t.page;
        const bg: u32 = if (active) fb.CORE97_WHITE else fb.CORE97_GREY;
        fb.fillRect(tab_x, y, TAB_W, TAB_H, bg);
        fb.draw3DBorder(tab_x, y, TAB_W, TAB_H, !active);
        const label_w = fb.textWidth(t.label);
        const label_x = tab_x + (TAB_W - @as(u32, @intCast(label_w))) / 2;
        fb.drawString(label_x, y + 7, t.label, fb.CORE97_BLACK, bg);
        tab_x += TAB_W + 2;
    }
}

fn tabAt(mx: i32, my: i32, x: u32, y: u32) ?Page {
    const ty: i32 = @intCast(y);
    if (my < ty or my >= ty + @as(i32, @intCast(TAB_H))) return null;
    var tab_x: i32 = @intCast(x + 8);
    for (TABS) |t| {
        if (mx >= tab_x and mx < tab_x + @as(i32, @intCast(TAB_W))) return t.page;
        tab_x += @as(i32, @intCast(TAB_W)) + 2;
    }
    return null;
}

// ===========================================================================
// Display page - runtime resolution switching (drivers/vbe.zig). Works
// identically under QEMU std-vga or VirtualBox VBoxVGA (both speak the
// same Bochs dispi protocol). No way to auto-detect "the host wants
// this size" (see vbe.zig's header), so these are manual presets.
// ===========================================================================
fn drawDisplayPage(x: u32, y: u32, w: u32, h: u32) void {
    _ = h;
    fb.fillRect(x + 8, y, w - 16, 70, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 8, y, w - 16, 70, false);
    fb.drawString(x + 18, y + 9, "Screen Resolution", fb.CORE97_BLACK, fb.CORE97_WHITE);

    var buf: [40]u8 = undefined;
    var p: usize = 0;
    append(&buf, &p, "Current: ");
    decU32(&buf, &p, fb.real_fb_width);
    append(&buf, &p, " x ");
    decU32(&buf, &p, fb.real_fb_height);
    fb.drawString(x + 18, y + 29, buf[0..p], fb.CORE97_BLACK, fb.CORE97_WHITE);

    var preset_x = x + 18;
    for (PRESETS) |res| {
        drawResButton(preset_x, y + 50, res);
        preset_x += 88;
    }
}

fn displayPageMouseDown(mx: i32, my: i32, x: u32, y: u32) void {
    const row_y: i32 = @intCast(y + 50);
    if (my < row_y or my >= row_y + 22) return;
    var preset_x: i32 = @intCast(x + 18);
    for (PRESETS) |res| {
        if (mx >= preset_x and mx < preset_x + 82) {
            _ = vbe.setMode(res.w, res.h);
            return;
        }
        preset_x += 88;
    }
}

// ===========================================================================
// Date/Time page - CMOS RTC (drivers/rtc.zig) + NTP sync
// (drivers/network.zig). Default NTP server is ntp.se - see network.zig's
// header comment for why.
// ===========================================================================
fn drawDateTimePage(x: u32, y: u32, w: u32, h: u32) void {
    _ = h;
    fb.fillRect(x + 8, y, w - 16, 78, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 8, y, w - 16, 78, false);
    fb.drawString(x + 18, y + 9, "Date and Time", fb.CORE97_BLACK, fb.CORE97_WHITE);

    var buf: [32]u8 = undefined;
    var p: usize = 0;
    const t = rtc.now();
    decU32(&buf, &p, t.year);
    append(&buf, &p, "-");
    decU32Padded2(&buf, &p, t.month);
    append(&buf, &p, "-");
    decU32Padded2(&buf, &p, t.day);
    append(&buf, &p, "   ");
    decU32Padded2(&buf, &p, t.hour);
    append(&buf, &p, ":");
    decU32Padded2(&buf, &p, t.minute);
    append(&buf, &p, ":");
    decU32Padded2(&buf, &p, t.second);
    fb.drawString(x + 18, y + 29, buf[0..p], fb.CORE97_BLACK, fb.CORE97_WHITE);

    ensureNtpEditInitialized();
    fb.drawString(x + 18, y + 53, "NTP Server:", fb.CORE97_BLACK, fb.CORE97_WHITE);
    const field_x = x + 96;
    const field_w: u32 = 220;
    const field_bg: u32 = if (ntp_field_focused) fb.CORE97_WHITE else 0xE8E8E8;
    fb.fillRect(field_x, y + 49, field_w, 18, field_bg);
    fb.draw3DBorder(field_x, y + 49, field_w, 18, false);
    fb.drawString(field_x + 4, y + 53, ntp_edit_buf[0..ntp_edit_len], fb.CORE97_BLACK, field_bg);
    if (ntp_field_focused) {
        const caret_x = field_x + 4 + @as(u32, @intCast(ntp_edit_len)) * fb.fontAdvance();
        fb.fillRect(caret_x, y + 51, 1, 12, fb.CORE97_BLACK);
    }
    ui.drawButton(field_x + field_w + 6, y + 49, 124, 22, "Sync Time (NTP)", true);
}

fn dateTimePageMouseDown(mx: i32, my: i32, x: u32, y: u32) void {
    const field_x: i32 = @intCast(x + 96);
    const field_y: i32 = @intCast(y + 49);
    const field_w: i32 = 220;
    ntp_field_focused = mx >= field_x and mx < field_x + field_w and my >= field_y and my < field_y + 18;

    const sync_x = field_x + field_w + 6;
    if (mx >= sync_x and mx < sync_x + 124 and my >= field_y and my < field_y + 22) {
        // Blocking (~2s max) is an accepted tradeoff, same as DHCP/static
        // below - no background task model exists for a button click to
        // hand this off to yet.
        _ = network.ntpSyncDefault();
    }
}

// ===========================================================================
// Network page - unchanged TCP/IP info + DHCP/Static, just on its own
// page now instead of sharing space with Display/NTP.
// ===========================================================================
fn drawNetworkPage(x: u32, y: u32, w: u32, h: u32) void {
    network.initAll();
    fb.fillRect(x + 8, y, w - 16, h - 8, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 8, y, w - 16, h - 8, false);
    fb.drawString(x + 18, y + 12, "TCP/IP Properties", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(x + 18, y + 32, "Adapter:", fb.CORE97_BLACK, fb.CORE97_WHITE);
    if (network.activeAdapter()) |a| fb.drawString(x + 86, y + 32, a.name, fb.CORE97_BLACK, fb.CORE97_WHITE) else fb.drawString(x + 86, y + 32, "No adapter", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(x + 18, y + 52, "Configuration:", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(x + 120, y + 52, network.modeName(), fb.CORE97_BLACK, fb.CORE97_WHITE);
    drawIp(x + 18, y + 76, "IP address", if (network.activeAdapter()) |a| a.ip else .{0,0,0,0});
    drawIp(x + 18, y + 94, "Subnet mask", network.subnet_mask);
    drawIp(x + 18, y + 112, "Gateway", network.gateway);
    drawIp(x + 18, y + 130, "DNS server", network.dns);
    fb.drawString(x + 18, y + 158, "Use Command Prompt for custom values:", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(x + 18, y + 174, "NETCFG DHCP", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(x + 18, y + 190, "NETCFG STATIC 10.0.2.15 255.255.255.0 10.0.2.2 10.0.2.3", fb.CORE97_BLACK, fb.CORE97_WHITE);
    ui.drawButton(x + 18, y + h - 42, 118, 22, "Use DHCP", true);
    ui.drawButton(x + 146, y + h - 42, 150, 22, "Use QEMU Static", true);
}

fn networkPageMouseDown(mx: i32, my: i32, x: u32, y: u32, h: u32) void {
    const by: i32 = @intCast(y + h - 42);
    if (my < by or my >= by + 22) return;
    if (mx >= @as(i32, @intCast(x + 18)) and mx < @as(i32, @intCast(x + 136))) network.setDhcp();
    if (mx >= @as(i32, @intCast(x + 146)) and mx < @as(i32, @intCast(x + 296))) network.setStatic(.{10,0,2,15}, .{255,255,255,0}, .{10,0,2,2}, .{10,0,2,3});
}

// ===========================================================================
// Sound page - PC speaker UI feedback tones (drivers/audio.zig).
// ===========================================================================
fn drawSoundPage(x: u32, y: u32, w: u32, h: u32) void {
    _ = h;
    fb.fillRect(x + 8, y, w - 16, 70, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 8, y, w - 16, 70, false);
    fb.drawString(x + 18, y + 9, "Sound Events", fb.CORE97_BLACK, fb.CORE97_WHITE);
    fb.drawString(x + 18, y + 29, "PC speaker tones for clicks and window events.", fb.CORE97_BLACK, fb.CORE97_WHITE);

    const label = if (audio.ui_sounds_enabled) "UI Sounds: On" else "UI Sounds: Off";
    ui.drawButton(x + 18, y + 50, 140, 22, label, true);
    ui.drawButton(x + 166, y + 50, 100, 22, "Test Sound", true);
}

fn soundPageMouseDown(mx: i32, my: i32, x: u32, y: u32) void {
    const row_y: i32 = @intCast(y + 50);
    if (my < row_y or my >= row_y + 22) return;
    if (mx >= @as(i32, @intCast(x + 18)) and mx < @as(i32, @intCast(x + 158))) {
        audio.ui_sounds_enabled = !audio.ui_sounds_enabled;
    }
    if (mx >= @as(i32, @intCast(x + 166)) and mx < @as(i32, @intCast(x + 266))) {
        audio.playTone(700, 4); // bypasses ui_sounds_enabled - "Test" should always actually play
    }
}

// ===========================================================================
// Background page - desktop fill color (gui/colors.zig owns the actual
// state, so both this and gui/desktop.zig can read/write it without a
// circular import between them).
// ===========================================================================
fn drawBackgroundPage(x: u32, y: u32, w: u32, h: u32) void {
    _ = h;
    fb.fillRect(x + 8, y, w - 16, 70, fb.CORE97_WHITE);
    fb.draw3DBorder(x + 8, y, w - 16, 70, false);
    fb.drawString(x + 18, y + 9, "Desktop Background", fb.CORE97_BLACK, fb.CORE97_WHITE);

    var swatch_x = x + 18;
    for (colors.BACKGROUND_PRESETS) |preset| {
        const selected = colors.desktop_background == preset.color;
        fb.fillRect(swatch_x, y + 30, 60, 30, preset.color);
        fb.draw3DBorder(swatch_x, y + 30, 60, 30, !selected);
        if (selected) {
            fb.fillRect(swatch_x + 2, y + 28, 56, 2, fb.CORE97_BLACK);
        }
        swatch_x += 68;
    }
}

fn backgroundPageMouseDown(mx: i32, my: i32, x: u32, y: u32) void {
    const row_y: i32 = @intCast(y + 30);
    if (my < row_y or my >= row_y + 30) return;
    var swatch_x: i32 = @intCast(x + 18);
    for (colors.BACKGROUND_PRESETS) |preset| {
        if (mx >= swatch_x and mx < swatch_x + 60) {
            colors.desktop_background = preset.color;
            return;
        }
        swatch_x += 68;
    }
}

// ===========================================================================
// Shared shell: tab bar + page dispatch
// ===========================================================================
const ControlPanel = struct {
    pub fn title(_: *ControlPanel) []const u8 { return "Control Panel"; }
    pub fn titleDetail(_: *ControlPanel) []const u8 { return ""; }

    pub fn draw(_: *ControlPanel, x: u32, y: u32, w: u32, h: u32) void {
        fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        drawTabBar(x, y + TAB_BAR_Y_OFFSET);

        const py = y + PAGE_Y_OFFSET + TAB_BAR_Y_OFFSET;
        const ph = h - PAGE_Y_OFFSET - TAB_BAR_Y_OFFSET - 8;
        switch (current_page) {
            .display => drawDisplayPage(x, py, w, ph),
            .datetime => drawDateTimePage(x, py, w, ph),
            .network => drawNetworkPage(x, py, w, ph),
            .sound => drawSoundPage(x, py, w, ph),
            .background => drawBackgroundPage(x, py, w, ph),
        }
    }

    pub fn onMouseDown(_: *ControlPanel, mx: i32, my: i32, _: window.MouseButton, x: u32, y: u32, _: u32, h: u32) window.AppAction {
        if (tabAt(mx, my, x, y + TAB_BAR_Y_OFFSET)) |page| {
            current_page = page;
            return .none;
        }

        const py = y + PAGE_Y_OFFSET + TAB_BAR_Y_OFFSET;
        const ph = h - PAGE_Y_OFFSET - TAB_BAR_Y_OFFSET - 8;
        switch (current_page) {
            .display => displayPageMouseDown(mx, my, x, py),
            .datetime => dateTimePageMouseDown(mx, my, x, py),
            .network => networkPageMouseDown(mx, my, x, py, ph),
            .sound => soundPageMouseDown(mx, my, x, py),
            .background => backgroundPageMouseDown(mx, my, x, py),
        }
        return .none;
    }

    pub fn onMouseDrag(_: *ControlPanel, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *ControlPanel) void {}

    pub fn onKeyAscii(_: *ControlPanel, ascii: u8) void {
        if (current_page != .datetime or !ntp_field_focused) return;
        ensureNtpEditInitialized();
        if (ascii == 8) {
            if (ntp_edit_len > 0) ntp_edit_len -= 1;
        } else if (ascii == 13) {
            ntp_field_focused = false;
        } else if ((ascii >= 32 and ascii <= 126) and ntp_edit_len < ntp_edit_buf.len) {
            ntp_edit_buf[ntp_edit_len] = ascii;
            ntp_edit_len += 1;
        } else {
            return;
        }
        network.setNtpServerAddress(ntp_edit_buf[0..ntp_edit_len]);
    }
    pub fn onKeyUsb(_: *ControlPanel, _: u8, _: u8, _: u32) bool { return false; }
    pub fn hasModalCapture(_: *ControlPanel) bool { return false; }
};

var instance: ControlPanel = .{};
pub fn asApp() window.App { return window.appFrom(ControlPanel, &instance); }
