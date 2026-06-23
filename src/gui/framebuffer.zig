// gui/framebuffer.zig - raw pixel buffer and primitive drawing.
// Everything here is "below" window/widget concepts: it only knows about
// pixels, rectangles, and the linear framebuffer GRUB handed us.

const colors = @import("colors.zig");
const font = @import("font.zig");

// --- Framebuffer state (set once by kernel_main from Multiboot info) ---
pub var fb_addr: usize = 0;
pub var fb_pitch: u32 = 0;
pub var fb_width: u32 = 0;
pub var fb_height: u32 = 0;
pub var fb_bpp: u8 = 0;

// --- Double buffering ---
// Drawing directly to framebuffer memory pixel-by-pixel causes visible
// flicker (we see the screen mid-redraw, especially during fast mouse
// movement that triggers many redraws/second). The fix: draw everything
// to a buffer in regular RAM, then copy the ENTIRE buffer to the screen
// in a single sweep once we're done.
// Sized generously rather than exactly 1024x768, since boot.asm no
// longer demands that specific resolution - the bootloader picks
// whatever it thinks is appropriate (see boot.asm's multiboot header),
// and this needs to be able to hold whatever that turns out to be.
// 1920x1200 comfortably covers the VESA modes a BIOS/VBE is likely to
// offer; kernel.zig refuses to boot into anything bigger than this
// rather than silently rendering a partial/corrupted screen.
pub const MAX_BACKBUFFER_PIXELS: usize = 1920 * 1200;
var backbuffer: [MAX_BACKBUFFER_PIXELS]u32 = undefined;

// Sets a pixel in the back buffer (NOT directly on screen)
pub fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height) return;
    const idx = y * fb_width + x;
    if (idx >= backbuffer.len) return;
    backbuffer[idx] = color;
}

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height or w == 0 or h == 0) return;
    const x_end = if (x + w > fb_width) fb_width else x + w;
    const y_end = if (y + h > fb_height) fb_height else y + h;

    var row: u32 = y;
    while (row < y_end) : (row += 1) {
        const row_start = row * fb_width + x;
        const row_end = row * fb_width + x_end;
        if (row_end > backbuffer.len) continue;
        @memset(backbuffer[row_start..row_end], color);
    }
}

// Copies the entire back buffer to the real screen in one sweep.
// Must be called once at the END of every frame, never mid-frame.
//
// This used to be a putPixel-style loop: one volatile store *and* one
// fresh `row*pitch + x*bpp` address recompute *and* one bounds check,
// per pixel, every single frame. At 1024x768 that's ~786k of all of the
// above per present - and since this OS calls present on every mouse
// IRQ, that cost was the actual root of the "feels sluggish" complaint.
// A plain framebuffer write has no MMIO side effects worth worrying
// about, so a bulk @memcpy (one per row, or a single one when the video
// mode has no row padding) is both correct and dramatically cheaper.
pub fn presentFrame() void {
    const total_raw: usize = @as(usize, fb_width) * @as(usize, fb_height);
    const total = if (total_raw > backbuffer.len) backbuffer.len else total_raw;
    const bytes_per_pixel = fb_bpp / 8;

    if (fb_pitch == fb_width * bytes_per_pixel) {
        const dest: [*]u32 = @ptrFromInt(fb_addr);
        @memcpy(dest[0..total], backbuffer[0..total]);
        return;
    }

    // Fallback for a padded row pitch (not the mode this kernel asks
    // for, but keep it correct if a different one ever gets negotiated).
    var y: u32 = 0;
    while (y < fb_height) : (y += 1) {
        const src_start = y * fb_width;
        if (src_start >= backbuffer.len) break;
        const src_end = if (src_start + fb_width > backbuffer.len) backbuffer.len else src_start + fb_width;
        const dest_row: [*]u32 = @ptrFromInt(fb_addr + y * fb_pitch);
        @memcpy(dest_row[0 .. src_end - src_start], backbuffer[src_start..src_end]);
    }
}

/// Copies only one rectangle from the backbuffer to the real framebuffer.
/// This is used while dragging windows to reduce tearing/slowness compared
/// with a full-screen present every mouse packet.
pub fn presentRect(x0: u32, y0: u32, w0: u32, h0: u32) void {
    if (x0 >= fb_width or y0 >= fb_height) return;
    const max_x = if (x0 + w0 > fb_width) fb_width else x0 + w0;
    const max_y = if (y0 + h0 > fb_height) fb_height else y0 + h0;
    if (max_x <= x0 or max_y <= y0) return;
    const row_w = max_x - x0;
    const bytes_per_pixel = fb_bpp / 8;

    var y: u32 = y0;
    while (y < max_y) : (y += 1) {
        const src_start = y * fb_width + x0;
        if (src_start >= backbuffer.len) continue;
        const src_end = if (src_start + row_w > backbuffer.len) backbuffer.len else src_start + row_w;
        const dest_row: [*]u32 = @ptrFromInt(fb_addr + y * fb_pitch + x0 * bytes_per_pixel);
        @memcpy(dest_row[0 .. src_end - src_start], backbuffer[src_start..src_end]);
    }
}

// Core97 palette re-exported here for old call sites.
pub const CORE97_TEAL: u32 = colors.TEAL;
pub const CORE97_GREY: u32 = colors.GREY;
pub const CORE97_DARK_GREY: u32 = colors.DARK_GREY;
pub const CORE97_WHITE: u32 = colors.WHITE;
pub const CORE97_BLUE: u32 = colors.BLUE;
pub const CORE97_BLACK: u32 = colors.BLACK;
pub const CORE97_RED: u32 = colors.RED;

// Font/private character code re-exports.
pub const CH_A_RING_LOWER: u8 = font.CH_A_RING_LOWER;
pub const CH_A_UML_LOWER: u8 = font.CH_A_UML_LOWER;
pub const CH_O_UML_LOWER: u8 = font.CH_O_UML_LOWER;
pub const CH_A_RING_UPPER: u8 = font.CH_A_RING_UPPER;
pub const CH_A_UML_UPPER: u8 = font.CH_A_UML_UPPER;
pub const CH_O_UML_UPPER: u8 = font.CH_O_UML_UPPER;
pub const CH_POUND: u8 = font.CH_POUND;
pub const CH_EURO: u8 = font.CH_EURO;
pub const CH_CURRENCY: u8 = font.CH_CURRENCY;

// Draws a "raised" 3D block in Core97 style (button/window border)
pub fn draw3DBorder(x: u32, y: u32, w: u32, h: u32, raised: bool) void {
    const light = if (raised) CORE97_WHITE else CORE97_DARK_GREY;
    const dark = if (raised) CORE97_DARK_GREY else CORE97_WHITE;

    fillRect(x, y, w, 1, light);
    fillRect(x, y, 1, h, light);
    fillRect(x, y + h - 1, w, 1, dark);
    fillRect(x + w - 1, y, 1, h, dark);
}

// Classic "marching ants" rubber-band selection rectangle: an outline
// made of alternating on/off pixels (dash=3, gap=2) rather than a solid
// line, so it reads as "this is a selection in progress", not a real
// border. Used by gui/selection.zig's RubberBand and reusable by any
// future app that embeds one - see selection.zig's header comment.
pub fn drawDashedRect(x: i32, y: i32, w: u32, h: u32, color: u32) void {
    if (w == 0 or h == 0) return;
    const x0: i32 = x;
    const y0: i32 = y;
    const x1: i32 = x + @as(i32, @intCast(w)) - 1;
    const y1: i32 = y + @as(i32, @intCast(h)) - 1;

    const dash: i32 = 3;
    const gap: i32 = 2;
    const period = dash + gap;

    var i: i32 = 0;
    while (x0 + i <= x1) : (i += 1) {
        if (@mod(i, period) < dash) {
            if (x0 + i >= 0 and y0 >= 0) putPixel(@intCast(x0 + i), @intCast(y0), color);
            if (x0 + i >= 0 and y1 >= 0) putPixel(@intCast(x0 + i), @intCast(y1), color);
        }
    }
    i = 0;
    while (y0 + i <= y1) : (i += 1) {
        if (@mod(i, period) < dash) {
            if (x0 >= 0 and y0 + i >= 0) putPixel(@intCast(x0), @intCast(y0 + i), color);
            if (x1 >= 0 and y0 + i >= 0) putPixel(@intCast(x1), @intCast(y0 + i), color);
        }
    }
}

pub fn drawChar(x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        const bits = font.glyphRow(c, row);
        var col: u32 = 0;
        while (col < 5) : (col += 1) {
            const mask: u8 = @as(u8, 1) << @intCast(4 - col);
            putPixel(x + col, y + @as(u32, @intCast(row)), if ((bits & mask) != 0) fg else bg);
        }
    }
}

pub fn drawString(x: u32, y: u32, text: []const u8, fg: u32, bg: u32) void {
    var cx = x;
    for (text) |c| {
        drawChar(cx, y, c, fg, bg);
        cx += 6;
    }
}

// Same 5x7 glyph data as drawChar, but rotated 90 degrees so the text
// reads going down the screen instead of across it - used for the
// "CORE 97" logo strip on the side of the Start menu. Each glyph's original
// (col, row) pixel maps to (x + row, y + (4 - col)): the old left-right
// axis becomes the new top-bottom axis.
pub fn drawCharVertical(x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        const bits = font.glyphRow(c, row);
        var col: u32 = 0;
        while (col < 5) : (col += 1) {
            const mask: u8 = @as(u8, 1) << @intCast(4 - col);
            const on = (bits & mask) != 0;
            putPixel(x + @as(u32, @intCast(row)), y + (4 - col), if (on) fg else bg);
        }
    }
}

pub fn drawStringVertical(x: u32, y: u32, text: []const u8, fg: u32, bg: u32) void {
    var cy = y;
    for (text) |c| {
        drawCharVertical(x, cy, c, fg, bg);
        cy += 6;
    }
}
