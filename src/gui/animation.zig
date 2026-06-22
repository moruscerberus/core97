const fb = @import("framebuffer.zig");
const colors = @import("colors.zig");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
};

pub fn smallCenter(r: Rect) Rect {
    return Rect{
        .x = r.x + @as(i32, @intCast(r.w / 2)) - 2,
        .y = r.y + @as(i32, @intCast(r.h / 2)) - 2,
        .w = 4,
        .h = 4,
    };
}

fn delay() void {
    var i: u32 = 0;
    while (i < 25000) : (i += 1) {
        asm volatile ("nop");
    }
}

fn lerpI32(a: i32, b: i32, step: u32, steps: u32) i32 {
    const delta: i32 = b - a;
    const s: i32 = @intCast(step);
    const n: i32 = @intCast(steps);
    return a + @divTrunc(delta * s, n);
}

fn lerpU32(a: u32, b: u32, step: u32, steps: u32) u32 {
    if (b >= a) return a + @divTrunc((b - a) * step, steps);
    return a - @divTrunc((a - b) * step, steps);
}

fn drawOutline(r: Rect, color: u32) void {
    if (r.w < 2 or r.h < 2) return;
    if (r.x < 0 or r.y < 0) return;

    const x: u32 = @intCast(r.x);
    const y: u32 = @intCast(r.y);

    fb.fillRect(x, y, r.w, 1, color);
    fb.fillRect(x, y + r.h - 1, r.w, 1, color);
    fb.fillRect(x, y, 1, r.h, color);
    fb.fillRect(x + r.w - 1, y, 1, r.h, color);
}

pub fn animateRect(from: Rect, to: Rect) void {
    const steps: u32 = 5;
    var step: u32 = 0;

    while (step <= steps) : (step += 1) {
        const r = Rect{
            .x = lerpI32(from.x, to.x, step, steps),
            .y = lerpI32(from.y, to.y, step, steps),
            .w = lerpU32(from.w, to.w, step, steps),
            .h = lerpU32(from.h, to.h, step, steps),
        };

        drawOutline(r, colors.WHITE);
        fb.presentFrame();
        delay();
    }
}
