// gui/framebuffer.zig - raw pixel buffer and primitive drawing.
// Everything here is "below" window/widget concepts: it only knows about
// pixels, rectangles, and the linear framebuffer GRUB handed us.

const colors = @import("colors.zig");
const font = @import("font.zig");

// --- Dynamic framebuffer canvas ---
//
// Core97 now treats fb_width/fb_height as the live desktop size, not a
// hard-coded design resolution. That means QEMU, VirtualBox, and bare metal
// all use the same GUI code path:
//   * Boot: GRUB's multiboot framebuffer size becomes the desktop size.
//   * QEMU/VirtualBox std/VBoxVGA: the Bochs VBE driver can switch modes.
//   * QEMU virtio-gpu: optional polling can ask the host for its preferred
//     scanout size, then the same VBE path applies the new mode.
//   * Bare metal: if runtime VBE mode setting is unavailable, the boot
//     framebuffer still works and the desktop lays out against that size.
//
// This deliberately avoids stretching a fixed 1280x800 image. Text, icons,
// menus, hit testing, taskbar placement, and windows all operate directly in
// real pixels, so the UI stays crisp. The backbuffer is a maximum-sized static
// canvas; only the active fb_width x fb_height region is used.
pub const MAX_WIDTH: u32 = 1920;
pub const MAX_HEIGHT: u32 = 1200;
pub const MAX_PIXELS: usize = @as(usize, MAX_WIDTH) * @as(usize, MAX_HEIGHT);

pub var fb_width: u32 = 640;
pub var fb_height: u32 = 480;
pub var resize_generation: u32 = 0;

pub fn configureCanvas(width: u32, height: u32) void {
    if (width == 0 or height == 0) return;
    const new_w = if (width > MAX_WIDTH) MAX_WIDTH else width;
    const new_h = if (height > MAX_HEIGHT) MAX_HEIGHT else height;
    if (new_w != fb_width or new_h != fb_height) resize_generation +%= 1;
    fb_width = new_w;
    fb_height = new_h;
}

// --- Real hardware framebuffer (set by kernel_main from Multiboot and by
// runtime mode drivers such as drivers/vbe.zig). Most GUI code should only use
// fb_width/fb_height and the drawing primitives above it.
pub var real_fb_addr: usize = 0;
pub var real_fb_pitch: u32 = 0;
pub var real_fb_width: u32 = 0;
pub var real_fb_height: u32 = 0;
pub var real_fb_bpp: u8 = 0;

// One static maximum-sized backbuffer. Dynamic allocation would be nicer, but
// this kernel is still early enough that a bounded static buffer is safer and
// works consistently on emulators and real machines.
var backbuffer: [MAX_PIXELS]u32 = undefined;

inline fn activeIndex(x: u32, y: u32) usize {
    return @as(usize, y) * @as(usize, MAX_WIDTH) + @as(usize, x);
}

// Sets a pixel in the back buffer (NOT directly on screen)
pub fn putPixel(x: u32, y: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height) return;
    const idx = activeIndex(x, y);
    if (idx >= backbuffer.len) return;
    backbuffer[idx] = color;
}

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (x >= fb_width or y >= fb_height or w == 0 or h == 0) return;
    const x_end = if (x + w > fb_width) fb_width else x + w;
    const y_end = if (y + h > fb_height) fb_height else y + h;

    var row: u32 = y;
    while (row < y_end) : (row += 1) {
        const row_start = activeIndex(x, row);
        const row_end = activeIndex(x_end, row);
        if (row_end > backbuffer.len) continue;
        @memset(backbuffer[row_start..row_end], color);
    }
}

inline fn writeRealPixel(rx: u32, ry: u32, color: u32) void {
    const bytes_per_pixel = real_fb_bpp / 8;
    const offset = real_fb_addr + @as(usize, ry) * @as(usize, real_fb_pitch) + @as(usize, rx) * @as(usize, bytes_per_pixel);
    const dest: *u32 = @ptrFromInt(offset);
    dest.* = color;
}

fn presentRows(x0: u32, y0: u32, x1: u32, y1: u32) void {
    if (real_fb_addr == 0 or real_fb_bpp != 32) return;
    if (fb_width == 0 or fb_height == 0) return;

    const max_x = if (x1 > fb_width) fb_width else x1;
    const max_y = if (y1 > fb_height) fb_height else y1;
    if (max_x <= x0 or max_y <= y0) return;

    const bytes_per_pixel = real_fb_bpp / 8;
    const copy_w: usize = @intCast(max_x - x0);
    var y = y0;
    while (y < max_y) : (y += 1) {
        const src_start = activeIndex(x0, y);
        const dest_row: [*]u32 = @ptrFromInt(real_fb_addr + @as(usize, y) * @as(usize, real_fb_pitch) + @as(usize, x0) * @as(usize, bytes_per_pixel));
        @memcpy(dest_row[0..copy_w], backbuffer[src_start .. src_start + copy_w]);
    }
}

// Copies the active desktop-size backbuffer to the real screen.
//
// Important: never stretch the desktop here. QEMU/VirtualBox can scale the
// host window, but the OS renderer must stay pixel-perfect. If the logical
// canvas and hardware framebuffer ever differ, we copy the overlapping region
// 1:1 and clear the unused area instead of nearest-neighbour scaling. Scaling
// the framebuffer was what made the shell font look fat, blurry, and uneven.
pub fn presentFrame() void {
    if (real_fb_addr == 0) return;
    if (real_fb_width == fb_width and real_fb_height == fb_height) {
        presentRows(0, 0, fb_width, fb_height);
        return;
    }

    if (real_fb_width == 0 or real_fb_height == 0) return;

    const copy_w = if (fb_width < real_fb_width) fb_width else real_fb_width;
    const copy_h = if (fb_height < real_fb_height) fb_height else real_fb_height;
    presentRows(0, 0, copy_w, copy_h);

    // Clear any exposed hardware-only area. This path should be rare; normal
    // boot and vbe.setMode() keep canvas and hardware mode identical.
    var y: u32 = 0;
    while (y < real_fb_height) : (y += 1) {
        var x: u32 = 0;
        while (x < real_fb_width) : (x += 1) {
            if (x >= copy_w or y >= copy_h) writeRealPixel(x, y, CORE97_TEAL);
        }
    }
}

/// Copies only a rectangle. Coordinates are live desktop pixels, not a fixed
/// virtual design space.
pub fn presentRect(x0: u32, y0: u32, w0: u32, h0: u32) void {
    if (real_fb_addr == 0) return;
    if (x0 >= fb_width or y0 >= fb_height) return;
    const max_x = if (x0 + w0 > fb_width) fb_width else x0 + w0;
    const max_y = if (y0 + h0 > fb_height) fb_height else y0 + h0;
    if (max_x <= x0 or max_y <= y0) return;

    if (real_fb_width == fb_width and real_fb_height == fb_height) {
        presentRows(x0, y0, max_x, max_y);
    } else {
        // Mismatched fallback: update the whole scaled frame. This path should
        // be rare; vbe.setMode() and boot configureCanvas() normally keep both
        // sizes equal.
        presentFrame();
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

// Core97 shell font metrics.
//
// The previous build scaled the 5x7 bitmap glyphs into a 7x11 cell. That made
// the UI larger, but because a 5x7 grid cannot scale evenly to 7x11, strokes
// became irregular and letters looked fuzzy after VM window scaling.
//
// This renderer is intentionally strict: one source pixel becomes exactly one
// framebuffer pixel. The cell is 6x8: 5 visible glyph columns, one blank
// spacer column, seven visible glyph rows, one blank descender/baseline row.
// It is not a copied Microsoft font; it is Core97's own tiny bitmap font drawn
// with Win95-era proportions and pixel-perfect rules.
pub const FONT_W: u32 = 6;  // base bitmap cell width at 1x
pub const FONT_H: u32 = 8;  // base bitmap cell height at 1x
pub const FONT_ADV: u32 = 6; // base advance at 1x

/// Global shell UI scale.  Core97 deliberately uses integer scale buckets:
/// generated icons/text are redrawn at 1x/2x instead of stretching a finished
/// framebuffer.  This keeps the 1995 pixel-art look crisp on 2026 displays.
pub fn uiScale() u32 {
    // Very wide fullscreen modes reported by QEMU/VirtualBox otherwise make
    // the shell feel microscopic.  Height OR width may trigger 2x because some
    // hosts expose ultrawide temporary surfaces such as 2048x576.
    if (fb_width >= 1600 or fb_height >= 900) return 2;
    return 1;
}

pub fn fontCellWidth() u32 { return FONT_W * uiScale(); }
pub fn fontHeight() u32 { return FONT_H * uiScale(); }
pub fn fontAdvance() u32 { return FONT_ADV * uiScale(); }

pub fn textWidth(text: []const u8) u32 {
    return @as(u32, @intCast(text.len)) * fontAdvance();
}

fn glyphOn(c: u8, src_col: u32, src_row: u32) bool {
    if (src_col >= 5 or src_row >= 7) return false;
    const bits = font.glyphRow(c, @intCast(src_row));
    const mask: u8 = @as(u8, 1) << @intCast(4 - src_col);
    return (bits & mask) != 0;
}

pub fn drawChar(x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
    // Pixel-perfect bitmap text. At high resolutions one source pixel becomes
    // an integer NxN block.  No interpolation, no fractional coordinates, no
    // scaling of the already-rendered framebuffer.
    const s = uiScale();
    var row: u32 = 0;
    while (row < FONT_H) : (row += 1) {
        var col: u32 = 0;
        while (col < FONT_W) : (col += 1) {
            fillRect(x + col * s, y + row * s, s, s, if (glyphOn(c, col, row)) fg else bg);
        }
    }
}

pub fn drawString(x: u32, y: u32, text: []const u8, fg: u32, bg: u32) void {
    var cx = x;
    for (text) |c| {
        drawChar(cx, y, c, fg, bg);
        cx += fontAdvance();
    }
}

// Same 5x7 glyph data as drawChar, but rotated 90 degrees clockwise so
// the text reads correctly going DOWN the screen without tilting your
// head - used for the "CORE 97" logo strip on the side of the Start
// menu. Each glyph's original (col, row) pixel maps to
// (x + (6 - row), y + col): the old left-right axis becomes the new
// top-bottom axis.
//
// Direction matters here, not just "rotated": rotating the other way
// (counter-clockwise) produces letters whose correct reading direction
// is bottom-to-top, which - combined with drawStringVertical drawing
// the first character at the smallest y (i.e. the top) - made the
// whole string read backwards top-to-bottom ("CORE 97" appeared as
// "79 EROC"). Clockwise rotation's natural top-to-bottom reading
// direction matches drawStringVertical's iteration order with no
// further changes needed there.
pub fn drawCharVertical(x: u32, y: u32, c: u8, fg: u32, bg: u32) void {
    const s = uiScale();
    var row: u32 = 0;
    while (row < FONT_H) : (row += 1) {
        var col: u32 = 0;
        while (col < FONT_W) : (col += 1) {
            fillRect(x + (FONT_H - 1 - row) * s, y + col * s, s, s, if (glyphOn(c, col, row)) fg else bg);
        }
    }
}

pub fn drawStringVertical(x: u32, y: u32, text: []const u8, fg: u32, bg: u32) void {
    var cy = y;
    for (text) |c| {
        drawCharVertical(x, cy, c, fg, bg);
        cy += fontAdvance();
    }
}
