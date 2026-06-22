// gui/ui.zig - shared hover-aware controls for Core97 UI.

const fb = @import("framebuffer.zig");

pub var hover_x: i32 = -1;
pub var hover_y: i32 = -1;

pub fn setHover(mx: i32, my: i32) void {
    hover_x = mx;
    hover_y = my;
}

pub fn hit(x: u32, y: u32, w: u32, h: u32) bool {
    const ix: i32 = @intCast(x);
    const iy: i32 = @intCast(y);
    return hover_x >= ix and hover_y >= iy and hover_x < ix + @as(i32, @intCast(w)) and hover_y < iy + @as(i32, @intCast(h));
}

pub fn drawHoverFill(x: u32, y: u32, w: u32, h: u32) void {
    fb.fillRect(x, y, w, h, 0xD8E8FF);
}

pub fn drawButton(x: u32, y: u32, w: u32, h: u32, label: []const u8, enabled: bool) void {
    const hovered = enabled and hit(x, y, w, h);
    const bg: u32 = if (hovered) 0xD8E8FF else fb.CORE97_GREY;
    const fg: u32 = if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY;
    fb.fillRect(x, y, w, h, bg);
    fb.draw3DBorder(x, y, w, h, true);
    if (hovered) {
        fb.fillRect(x + 1, y + 1, w - 2, 1, fb.CORE97_WHITE);
        fb.fillRect(x + 1, y + 1, 1, h - 2, fb.CORE97_WHITE);
    }
    fb.drawString(x + 8, y + 7, label, fg, bg);
}
