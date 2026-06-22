// gui/cursor.zig - classic Core97 mouse cursor drawing.

const fb = @import("framebuffer.zig");

const shape = [_][2]i32{
    .{ 0, 0 }, .{ 0, 1 }, .{ 0, 2 }, .{ 0, 3 }, .{ 0, 4 },
    .{ 0, 5 }, .{ 0, 6 }, .{ 0, 7 }, .{ 0, 8 }, .{ 1, 1 },
    .{ 1, 2 }, .{ 1, 3 }, .{ 1, 4 }, .{ 1, 5 }, .{ 1, 6 },
    .{ 2, 2 }, .{ 2, 3 }, .{ 2, 4 }, .{ 2, 5 }, .{ 3, 3 },
    .{ 3, 4 }, .{ 1, 7 }, .{ 2, 6 }, .{ 4, 4 },
};

pub fn draw(x: i32, y: i32) void {
    for (shape) |offset| {
        const px = x + offset[0];
        const py = y + offset[1];
        if (px >= 0 and py >= 0) {
            fb.putPixel(@intCast(px), @intCast(py), fb.CORE97_BLACK);
        }
    }
}
