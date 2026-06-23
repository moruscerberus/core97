// gui/desktop_icons.zig - movable, selectable icons on the desktop
// background (My Computer, Documents, Trash).
//
// Click-and-drag on empty desktop space draws a rubber-band (see
// selection.zig) and multi-selects whichever icons it overlaps, the
// same convention as the file list in file_explorer.zig. Click-and-drag
// starting ON an icon moves it (and every other currently-selected icon
// along with it, so a multi-selected group drags together) instead.
//
// There's no double-click detection anywhere in this kernel yet (see
// the lack of any timestamp/last-click tracking in mouse.zig), so
// "activate" uses the next best convention: clicking an icon that was
// ALREADY selected (and isn't being dragged) opens it. A fresh click on
// a previously-unselected icon just selects it first - exactly two
// clicks to open, same physical action as a double-click, just without
// a timing window. If real double-click detection gets added later,
// this can switch over without changing how icons are stored or drawn.

const fb = @import("framebuffer.zig");
const window = @import("window.zig");
const selection = @import("selection.zig");
const vfs = @import("../fs/vfs.zig");
const taskbar = @import("taskbar.zig");

pub const Kind = enum { my_computer, documents, trash };

const ICON_W: u32 = 48;
const ICON_H: u32 = 40; // glyph box only; label is drawn below it
const LABEL_H: u32 = 14;
const CELL_W: u32 = 64; // total hit/selection box, glyph + label + padding
const CELL_H: u32 = ICON_H + LABEL_H + 4;

// Grid spacing for snap-to-grid: each cell is the icon's own box plus a
// fixed gap, so icons line up the way a real desktop's icon grid does
// instead of landing at whatever arbitrary pixel they were dropped on.
const GRID_GAP: u32 = 16;
const GRID_CELL_W: i32 = @intCast(CELL_W + GRID_GAP);
const GRID_CELL_H: i32 = @intCast(CELL_H + GRID_GAP);
const GRID_ORIGIN_X: i32 = 16;
const GRID_ORIGIN_Y: i32 = 16;

const Icon = struct {
    kind: Kind,
    label: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    selected: bool = false,
};

var icons: [3]Icon = .{
    .{ .kind = .my_computer, .label = "My Computer" },
    .{ .kind = .documents, .label = "Documents" },
    .{ .kind = .trash, .label = "Trash" },
};

var positioned: bool = false;
var rubber_band: selection.RubberBand = .{};

// Drag state for moving icon(s). drag_index is which icon the press
// actually landed on (so its offset-from-cursor stays fixed); every
// OTHER currently-selected icon moves by the same delta each frame so a
// multi-selected group drags as one unit.
var dragging: bool = false;
var drag_index: usize = 0;
var drag_offset_x: i32 = 0;
var drag_offset_y: i32 = 0;
var drag_moved: bool = false; // crossed the move threshold - suppresses "activate" on release

/// Lays out the default positions the first time this runs (needs
/// fb.fb_height, which isn't known at comptime) - top-left column for
/// My Computer/Documents, bottom-right corner for Trash, the classic
/// retro desktop arrangement.
fn ensurePositioned() void {
    if (positioned) return;
    positioned = true;
    icons[0].x = 16;
    icons[0].y = 16;
    icons[1].x = 16;
    icons[1].y = 16 + @as(i32, @intCast(CELL_H)) + 12;
    icons[2].x = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(CELL_W)) - 20;
    icons[2].y = @as(i32, @intCast(fb.fb_height)) - @as(i32, @intCast(taskbar.HEIGHT)) - @as(i32, @intCast(CELL_H)) - 20;
}

fn cellRect(i: *const Icon) selection.Rect {
    return .{ .x = i.x, .y = i.y, .w = CELL_W, .h = CELL_H };
}

/// Rounds (x, y) to the nearest grid cell, then clamps so the icon stays
/// fully on screen (and above the taskbar) even if it was dragged past
/// an edge. Called once a drag ends, not on every frame while dragging
/// - the icon should follow the cursor smoothly during the drag itself
/// and only "click" into place on release, the same feel real desktop
/// icon grids have.
fn snapToGrid(x: i32, y: i32) struct { x: i32, y: i32 } {
    const col = @divFloor(x - GRID_ORIGIN_X + @divFloor(GRID_CELL_W, 2), GRID_CELL_W);
    const row = @divFloor(y - GRID_ORIGIN_Y + @divFloor(GRID_CELL_H, 2), GRID_CELL_H);

    const max_x: i32 = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(CELL_W)) - 4;
    const max_y: i32 = @as(i32, @intCast(fb.fb_height)) - @as(i32, @intCast(taskbar.HEIGHT)) - @as(i32, @intCast(CELL_H)) - 4;

    var snapped_x = GRID_ORIGIN_X + col * GRID_CELL_W;
    var snapped_y = GRID_ORIGIN_Y + row * GRID_CELL_H;
    if (snapped_x < 4) snapped_x = 4;
    if (snapped_y < 4) snapped_y = 4;
    if (snapped_x > max_x) snapped_x = max_x;
    if (snapped_y > max_y) snapped_y = max_y;
    return .{ .x = snapped_x, .y = snapped_y };
}

fn clearSelection() void {
    for (&icons) |*i| i.selected = false;
}

fn iconAt(mx: i32, my: i32) ?usize {
    var idx: usize = icons.len;
    while (idx > 0) {
        idx -= 1;
        const r = cellRect(&icons[idx]);
        if (mx >= r.x and mx < r.x + @as(i32, @intCast(r.w)) and my >= r.y and my < r.y + @as(i32, @intCast(r.h))) return idx;
    }
    return null;
}

fn drawGlyph(kind: Kind, x: i32, y: i32) void {
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    switch (kind) {
        .my_computer => {
            // Simple monitor: screen + stand, beige/grey like the era.
            fb.fillRect(ux + 8, uy + 4, 32, 22, fb.CORE97_WHITE);
            fb.draw3DBorder(ux + 8, uy + 4, 32, 22, true);
            fb.fillRect(ux + 18, uy + 26, 12, 4, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 14, uy + 30, 20, 3, fb.CORE97_DARK_GREY);
        },
        .documents => {
            fb.fillRect(ux + 12, uy + 2, 22, 28, fb.CORE97_WHITE);
            fb.draw3DBorder(ux + 12, uy + 2, 22, 28, true);
            fb.fillRect(ux + 16, uy + 8, 14, 1, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 16, uy + 13, 14, 1, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 16, uy + 18, 14, 1, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 16, uy + 23, 10, 1, fb.CORE97_DARK_GREY);
        },
        .trash => {
            // A little bin: lid + tapered body with vertical ribs.
            fb.fillRect(ux + 10, uy + 4, 26, 4, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 16, uy + 0, 14, 4, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 13, uy + 9, 20, 22, fb.CORE97_GREY);
            fb.draw3DBorder(ux + 13, uy + 9, 20, 22, true);
            fb.fillRect(ux + 17, uy + 12, 2, 16, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 22, uy + 12, 2, 16, fb.CORE97_DARK_GREY);
            fb.fillRect(ux + 27, uy + 12, 2, 16, fb.CORE97_DARK_GREY);
        },
    }
}

pub fn draw() void {
    ensurePositioned();
    for (&icons) |*icon| {
        const r = cellRect(icon);
        if (icon.selected) {
            fb.fillRect(@intCast(r.x), @intCast(r.y), r.w, r.h, 0x3A6EA5);
        }
        const glyph_x = icon.x + @as(i32, @intCast((CELL_W - ICON_W) / 2));
        drawGlyph(icon.kind, glyph_x, icon.y + 2);

        const label_bg: u32 = if (icon.selected) 0x3A6EA5 else fb.CORE97_TEAL;
        const label_fg: u32 = if (icon.selected) fb.CORE97_WHITE else fb.CORE97_WHITE;
        const label_w = icon.label.len * 6; // matches font.zig's fixed glyph advance
        const label_x = icon.x + @as(i32, @intCast(CELL_W / 2)) - @as(i32, @intCast(label_w / 2));
        fb.drawString(@intCast(@max(label_x, icon.x)), @intCast(icon.y + @as(i32, @intCast(ICON_H)) + 4), icon.label, label_fg, label_bg);
    }
    rubber_band.draw();
}

/// Called from desktop.zig only when the click missed every open window
/// (manager.handleMouseDown returned no slot) - icons live on the
/// background, below windows, so a window on top of an icon should
/// always win the click.
pub fn onMouseDown(mx: i32, my: i32) void {
    ensurePositioned();
    if (iconAt(mx, my)) |idx| {
        const already_selected = icons[idx].selected;
        if (!already_selected) {
            clearSelection();
            icons[idx].selected = true;
        }
        dragging = true;
        drag_index = idx;
        drag_offset_x = mx - icons[idx].x;
        drag_offset_y = my - icons[idx].y;
        drag_moved = false;
        return;
    }
    clearSelection();
    rubber_band.begin(mx, my);
}

pub fn onMouseDrag(mx: i32, my: i32) void {
    if (dragging) {
        const new_x = mx - drag_offset_x;
        const new_y = my - drag_offset_y;
        const dx = new_x - icons[drag_index].x;
        const dy = new_y - icons[drag_index].y;
        if (dx != 0 or dy != 0) drag_moved = true;
        for (&icons) |*icon| {
            if (icon.selected) {
                icon.x += dx;
                icon.y += dy;
            }
        }
        if (!icons[drag_index].selected) {
            icons[drag_index].x = new_x;
            icons[drag_index].y = new_y;
        }
        return;
    }
    rubber_band.update(mx, my);
}

pub const Activation = enum { none, open_my_computer, open_documents };

/// Returns what (if anything) should happen as a result of this
/// release - the caller (desktop.zig) is responsible for actually
/// opening File Explorer, since this module doesn't know about window
/// management.
pub fn onMouseUp() Activation {
    if (dragging) {
        dragging = false;
        const moved = drag_moved;
        const idx = drag_index;
        drag_moved = false;
        if (moved) {
            // Snap every icon that was actually part of this drag - the
            // dragged one plus any others selected alongside it - each
            // to its own nearest grid cell, independently.
            for (&icons) |*icon| {
                if (icon.selected or &icons[idx] == icon) {
                    const snapped = snapToGrid(icon.x, icon.y);
                    icon.x = snapped.x;
                    icon.y = snapped.y;
                }
            }
            return .none;
        }
        return switch (icons[idx].kind) {
            .my_computer => .open_my_computer,
            .documents => .open_documents,
            .trash => .none, // nothing to open yet - selectable and movable, as asked for
        };
    }

    const r = rubber_band.end() orelse return .none;
    for (&icons) |*icon| {
        if (selection.rectsIntersect(r, cellRect(icon))) icon.selected = true;
    }
    return .none;
}
