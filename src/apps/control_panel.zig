// apps/control_panel.zig - Core97-style Control Panel with Network settings.

const fb = @import("../gui/framebuffer.zig");
const window = @import("../gui/window.zig");
const network = @import("../drivers/network.zig");
const ui = @import("../gui/ui.zig");

const ControlPanel = struct {
    fn drawButton(x: u32, y: u32, w: u32, label: []const u8) void {
        ui.drawButton(x, y, w, 22, label, true);
    }
    fn drawIp(x: u32, y: u32, label: []const u8, ip: [4]u8) void {
        var buf: [80]u8 = undefined;
        var p: usize = 0;
        append(&buf, &p, label); append(&buf, &p, ": "); dec(&buf, &p, ip[0]); append(&buf, &p, "."); dec(&buf, &p, ip[1]); append(&buf, &p, "."); dec(&buf, &p, ip[2]); append(&buf, &p, "."); dec(&buf, &p, ip[3]);
        fb.drawString(x, y, buf[0..p], fb.CORE97_BLACK, fb.CORE97_WHITE);
    }
    fn append(buf: []u8, pos: *usize, text: []const u8) void { var i: usize = 0; while (i < text.len and pos.* < buf.len) : (i += 1) { buf[pos.*] = text[i]; pos.* += 1; } }
    fn dec(buf: []u8, pos: *usize, v: u8) void {
        if (v >= 100) { buf[pos.*] = '0' + @as(u8, @intCast(v / 100)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast((v / 10) % 10)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast(v % 10)); pos.* += 1; }
        else if (v >= 10) { buf[pos.*] = '0' + @as(u8, @intCast(v / 10)); pos.* += 1; buf[pos.*] = '0' + @as(u8, @intCast(v % 10)); pos.* += 1; }
        else { buf[pos.*] = '0' + v; pos.* += 1; }
    }

    pub fn title(_: *ControlPanel) []const u8 { return "Control Panel"; }
    pub fn titleDetail(_: *ControlPanel) []const u8 { return ""; }
    pub fn draw(_: *ControlPanel, x: u32, y: u32, w: u32, h: u32) void {
        network.initAll();
        fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        fb.fillRect(x + 8, y + 8, w - 16, 26, fb.CORE97_WHITE);
        fb.draw3DBorder(x + 8, y + 8, w - 16, 26, false);
        fb.drawString(x + 18, y + 17, "Network", fb.CORE97_BLACK, fb.CORE97_WHITE);

        fb.fillRect(x + 8, y + 44, w - 16, h - 54, fb.CORE97_WHITE);
        fb.draw3DBorder(x + 8, y + 44, w - 16, h - 54, false);
        fb.drawString(x + 18, y + 56, "TCP/IP Properties", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 18, y + 76, "Adapter:", fb.CORE97_BLACK, fb.CORE97_WHITE);
        if (network.activeAdapter()) |a| fb.drawString(x + 86, y + 76, a.name, fb.CORE97_BLACK, fb.CORE97_WHITE) else fb.drawString(x + 86, y + 76, "No adapter", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 18, y + 96, "Configuration:", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 120, y + 96, network.modeName(), fb.CORE97_BLACK, fb.CORE97_WHITE);
        drawIp(x + 18, y + 120, "IP address", if (network.activeAdapter()) |a| a.ip else .{0,0,0,0});
        drawIp(x + 18, y + 138, "Subnet mask", network.subnet_mask);
        drawIp(x + 18, y + 156, "Gateway", network.gateway);
        drawIp(x + 18, y + 174, "DNS server", network.dns);
        fb.drawString(x + 18, y + 202, "Use Command Prompt for custom values:", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 18, y + 218, "NETCFG DHCP", fb.CORE97_BLACK, fb.CORE97_WHITE);
        fb.drawString(x + 18, y + 234, "NETCFG STATIC 10.0.2.15 255.255.255.0 10.0.2.2 10.0.2.3", fb.CORE97_BLACK, fb.CORE97_WHITE);
        drawButton(x + 18, y + h - 34, 118, "Use DHCP");
        drawButton(x + 146, y + h - 34, 150, "Use QEMU Static");
    }
    pub fn onMouseDown(_: *ControlPanel, mx: i32, my: i32, _: window.MouseButton, x: u32, y: u32, _: u32, h: u32) window.AppAction {
        const by: i32 = @intCast(y + h - 34);
        if (my >= by and my < by + 22) {
            if (mx >= @as(i32, @intCast(x + 18)) and mx < @as(i32, @intCast(x + 136))) network.setDhcp();
            if (mx >= @as(i32, @intCast(x + 146)) and mx < @as(i32, @intCast(x + 296))) network.setStatic(.{10,0,2,15}, .{255,255,255,0}, .{10,0,2,2}, .{10,0,2,3});
        }
        return .none;
    }
    pub fn onMouseDrag(_: *ControlPanel, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *ControlPanel) void {}
    pub fn onKeyAscii(_: *ControlPanel, _: u8) void {}
    pub fn onKeyUsb(_: *ControlPanel, _: u8, _: u8, _: u32) bool { return false; }
    pub fn hasModalCapture(_: *ControlPanel) bool { return false; }
};

var instance: ControlPanel = .{};
pub fn asApp() window.App { return window.appFrom(ControlPanel, &instance); }
