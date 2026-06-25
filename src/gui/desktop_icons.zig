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
const pit = @import("../drivers/pit.zig");
const ui = @import("ui.zig");

pub const Kind = enum { my_computer, documents, explorer, control_panel, trash };

const ICON_W_BASE: u32 = 48;
const ICON_H_BASE: u32 = 40; // glyph box only; label is drawn below it
const CELL_W_BASE: u32 = 76; // total hit/selection box, glyph + label + padding
const GRID_GAP_BASE: u32 = 18;
const GRID_ORIGIN_X: i32 = 16;
const GRID_ORIGIN_Y: i32 = 16;

fn iconW() u32 { return ICON_W_BASE * fb.uiScale(); }
fn iconH() u32 { return ICON_H_BASE * fb.uiScale(); }
fn labelH() u32 { return fb.fontHeight() + 4 * fb.uiScale(); }
fn cellW() u32 { return CELL_W_BASE * fb.uiScale(); }
fn cellH() u32 { return iconH() + labelH() + 4 * fb.uiScale(); }
fn gridCellW() i32 { return @intCast(cellW() + GRID_GAP_BASE * fb.uiScale()); }
fn gridCellH() i32 { return @intCast(cellH() + GRID_GAP_BASE * fb.uiScale()); }

const Icon = struct {
    kind: Kind,
    label: []const u8,
    x: i32 = 0,
    y: i32 = 0,
    selected: bool = false,
};

var icons: [5]Icon = .{
    .{ .kind = .my_computer, .label = "My Computer" },
    .{ .kind = .documents, .label = "Documents" },
    .{ .kind = .explorer, .label = "Explorer" },
    .{ .kind = .control_panel, .label = "Control Panel" },
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
// Set in onMouseDown (where the press, and therefore the double-click
// check, actually happens) and consumed in onMouseUp. Double-click
// detection lives here instead of the low-level PS/2 mouse driver so it
// works identically for PS/2, USB mice, and USB tablets.
var pending_activate: bool = false;

const DOUBLE_CLICK_MAX_TICKS: u32 = 40; // ~400ms at the 100Hz PIT rate
const DOUBLE_CLICK_MAX_DIST: i32 = 6;

var last_click_tick: u32 = 0;
var last_click_x: i32 = -1000;
var last_click_y: i32 = -1000;
var last_click_icon: usize = icons.len;

fn isDoubleClickOnIcon(idx: usize, mx: i32, my: i32) bool {
    const dt = pit.ticks -% last_click_tick;
    const dx = mx - last_click_x;
    const dy = my - last_click_y;
    const same_icon = idx == last_click_icon;
    const close_enough = dx * dx + dy * dy <= DOUBLE_CLICK_MAX_DIST * DOUBLE_CLICK_MAX_DIST;
    const hit = same_icon and dt <= DOUBLE_CLICK_MAX_TICKS and close_enough;

    if (hit) {
        // Consume the pair. A rapid triple-click should not create two
        // activations, and clearing the history also prevents a stale
        // double-click from being delivered to a later unrelated click.
        last_click_tick = 0;
        last_click_x = -1000;
        last_click_y = -1000;
        last_click_icon = icons.len;
        return true;
    }

    last_click_tick = pit.ticks;
    last_click_x = mx;
    last_click_y = my;
    last_click_icon = idx;
    return false;
}

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
    icons[1].y = 16 + @as(i32, @intCast(cellH())) + 12;
    icons[2].x = 16;
    icons[2].y = 16 + 2 * (@as(i32, @intCast(cellH())) + 12);
    icons[3].x = 16;
    icons[3].y = 16 + 3 * (@as(i32, @intCast(cellH())) + 12);
    icons[4].x = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(cellW())) - 20;
    icons[4].y = @as(i32, @intCast(fb.fb_height)) - @as(i32, @intCast(taskbar.height())) - @as(i32, @intCast(cellH())) - 20;
}


pub fn onScreenResize() void {
    ensurePositioned();
    for (&icons) |*i| {
        const snapped = snapToGrid(i.x, i.y);
        i.x = snapped.x;
        i.y = snapped.y;
    }
    // Keep Trash in the familiar bottom-right corner unless the user has
    // explicitly dragged it elsewhere. The clamp above still protects tiny
    // resolutions.
    icons[4].x = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(cellW())) - 20;
    icons[4].y = @as(i32, @intCast(fb.fb_height)) - @as(i32, @intCast(taskbar.height())) - @as(i32, @intCast(cellH())) - 20;
    const t = snapToGrid(icons[4].x, icons[4].y);
    icons[4].x = t.x;
    icons[4].y = t.y;
}

fn cellRect(i: *const Icon) selection.Rect {
    return .{ .x = i.x, .y = i.y, .w = cellW(), .h = cellH() };
}

/// Rounds (x, y) to the nearest grid cell, then clamps so the icon stays
/// fully on screen (and above the taskbar) even if it was dragged past
/// an edge. Called once a drag ends, not on every frame while dragging
/// - the icon should follow the cursor smoothly during the drag itself
/// and only "click" into place on release, the same feel real desktop
/// icon grids have.
fn snapToGrid(x: i32, y: i32) struct { x: i32, y: i32 } {
    const col = @divFloor(x - GRID_ORIGIN_X + @divFloor(gridCellW(), 2), gridCellW());
    const row = @divFloor(y - GRID_ORIGIN_Y + @divFloor(gridCellH(), 2), gridCellH());

    const max_x: i32 = @as(i32, @intCast(fb.fb_width)) - @as(i32, @intCast(cellW())) - 4;
    const max_y: i32 = @as(i32, @intCast(fb.fb_height)) - @as(i32, @intCast(taskbar.height())) - @as(i32, @intCast(cellH())) - 4;

    var snapped_x = GRID_ORIGIN_X + col * gridCellW();
    var snapped_y = GRID_ORIGIN_Y + row * gridCellH();
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


fn sFillRect(base_x: u32, base_y: u32, ox: u32, oy: u32, w: u32, h: u32, color: u32) void {
    const sc = fb.uiScale();
    fb.fillRect(base_x + ox * sc, base_y + oy * sc, w * sc, h * sc, color);
}

fn sPixel(base_x: u32, base_y: u32, ox: u32, oy: u32, color: u32) void {
    const sc = fb.uiScale();
    fb.fillRect(base_x + ox * sc, base_y + oy * sc, sc, sc, color);
}

fn sBorder(base_x: u32, base_y: u32, ox: u32, oy: u32, w: u32, h: u32, raised: bool) void {
    const sc = fb.uiScale();
    fb.draw3DBorder(base_x + ox * sc, base_y + oy * sc, w * sc, h * sc, raised);
}

fn drawGlyph(kind: Kind, x: i32, y: i32) void {
    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    switch (kind) {
        .my_computer => {
            // Win95-inspired 32x32 computer: beige CRT, blue screen, base.
            sFillRect(ux, uy, 11, 5, 27, 22, 0xD8D0B8);
            sBorder(ux, uy, 11, 5, 27, 22, true);
            sFillRect(ux, uy, 15, 9, 19, 13, 0x000080);
            sBorder(ux, uy, 14, 8, 21, 15, false);
            sFillRect(ux, uy, 19, 12, 10, 6, 0x008080);
            sFillRect(ux, uy, 31, 24, 2, 2, 0x00A000);
            sFillRect(ux, uy, 20, 27, 10, 4, 0x808080);
            sFillRect(ux, uy, 14, 31, 23, 3, 0xC0C0C0);
            sBorder(ux, uy, 14, 31, 23, 3, true);
        },
        .documents => {
            // Open folder with papers peeking out.
            sFillRect(ux, uy, 13, 7, 9, 9, fb.CORE97_WHITE);
            sBorder(ux, uy, 13, 7, 9, 9, false);
            sFillRect(ux, uy, 23, 8, 8, 8, fb.CORE97_WHITE);
            sBorder(ux, uy, 23, 8, 8, 8, false);
            sFillRect(ux, uy, 7, 16, 33, 20, 0xFFFF80);
            sFillRect(ux, uy, 9, 11, 15, 7, 0xFFFF80);
            sBorder(ux, uy, 7, 16, 33, 20, true);
            sFillRect(ux, uy, 10, 19, 27, 2, 0xFFF0A0);
        },
        .explorer => {
            // Folder plus magnifying glass, close to the classic Explorer idea
            // without copying the original artwork.
            sFillRect(ux, uy, 5, 17, 31, 18, 0xFFFF80);
            sFillRect(ux, uy, 7, 12, 14, 7, 0xFFFF80);
            sBorder(ux, uy, 5, 17, 31, 18, true);
            sFillRect(ux, uy, 30, 23, 10, 10, 0xC0FFFF);
            sBorder(ux, uy, 29, 22, 12, 12, false);
            sFillRect(ux, uy, 39, 33, 6, 2, 0x000080);
            sPixel(ux, uy, 38, 32, 0x000080);
            sPixel(ux, uy, 37, 31, 0x000080);
        },
        .control_panel => {
            // Yellow control-panel folder with colored slider controls.
            sFillRect(ux, uy, 7, 9, 33, 27, 0xFFFF80);
            sFillRect(ux, uy, 10, 5, 14, 7, 0xFFFF80);
            sBorder(ux, uy, 7, 9, 33, 27, true);
            sFillRect(ux, uy, 13, 17, 5, 13, fb.CORE97_DARK_GREY);
            sFillRect(ux, uy, 23, 15, 5, 15, fb.CORE97_DARK_GREY);
            sFillRect(ux, uy, 33, 18, 5, 12, fb.CORE97_DARK_GREY);
            sFillRect(ux, uy, 11, 21, 9, 3, 0xC00000);
            sFillRect(ux, uy, 21, 19, 9, 3, 0x008000);
            sFillRect(ux, uy, 31, 24, 9, 3, 0x0000C0);
        },
        .trash => {
            // Crisper bin: light body, dark lid, green recycle hint.
            sFillRect(ux, uy, 12, 6, 25, 4, fb.CORE97_DARK_GREY);
            sFillRect(ux, uy, 18, 2, 13, 4, fb.CORE97_DARK_GREY);
            sFillRect(ux, uy, 14, 11, 20, 24, 0xD8D8D8);
            sBorder(ux, uy, 14, 11, 20, 24, true);
            sFillRect(ux, uy, 18, 15, 2, 16, 0x808080);
            sFillRect(ux, uy, 24, 15, 2, 16, 0x808080);
            sFillRect(ux, uy, 30, 15, 2, 16, 0x808080);
            sFillRect(ux, uy, 21, 20, 7, 2, 0x008000);
            sFillRect(ux, uy, 19, 22, 2, 5, 0x008000);
            sFillRect(ux, uy, 28, 22, 2, 5, 0x008000);
        },
    }
}

pub fn draw() void {
    ensurePositioned();
    for (&icons) |*icon| {
        const r = cellRect(icon);
        const ux: u32 = @intCast(r.x);
        const uy: u32 = @intCast(r.y);
        if (icon.selected) {
            fb.fillRect(ux + 1, uy + 1, r.w - 2, r.h - 2, 0x316AC5);
            fb.draw3DBorder(ux, uy, r.w, r.h, false);
        } else if (ui.hit(ux, uy, r.w, r.h)) {
            // Win95 icons do not use a big hover tile; selection is explicit.
        }
        const glyph_x = icon.x + @as(i32, @intCast((cellW() - iconW()) / 2));
        // Small shadow under the glyph, then the actual pixel icon.
        fb.fillRect(@intCast(glyph_x + 10), @intCast(icon.y + 36), 34, 3, 0x004848);
        drawGlyph(icon.kind, glyph_x, icon.y + 2);

        const selected_or_hover = icon.selected;
        const label_bg: u32 = if (icon.selected) 0x000080 else 0x008080;
        const label_fg: u32 = fb.CORE97_WHITE;
        const label_w = fb.textWidth(icon.label);
        const label_x = icon.x + @as(i32, @intCast(cellW() / 2)) - @as(i32, @intCast(label_w / 2));
        const lx: u32 = @intCast(@max(label_x, icon.x));
        const ly: u32 = @intCast(icon.y + @as(i32, @intCast(iconH())) + 4);
        if (!selected_or_hover) fb.drawString(lx + 1, ly + 1, icon.label, 0x004040, label_bg);
        fb.drawString(lx, ly, icon.label, label_fg, label_bg);
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
        pending_activate = isDoubleClickOnIcon(idx, mx, my);
        if (!icons[idx].selected) {
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

pub const Activation = enum { none, open_my_computer, open_documents, open_explorer, open_control_panel, open_trash };

/// Returns what (if anything) should happen as a result of this
/// release - the caller (desktop.zig) is responsible for actually
/// opening File Explorer, since this module doesn't know about window
/// management.
pub fn onMouseUp() Activation {
    if (dragging) {
        dragging = false;
        const moved = drag_moved;
        const idx = drag_index;
        const activate = pending_activate;
        drag_moved = false;
        pending_activate = false;
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
        if (!activate) return .none;
        return switch (icons[idx].kind) {
            .my_computer => .open_my_computer,
            .documents => .open_documents,
            .explorer => .open_explorer,
            .control_panel => .open_control_panel,
            .trash => .open_trash,
        };
    }

    const r = rubber_band.end() orelse return .none;
    for (&icons) |*icon| {
        if (selection.rectsIntersect(r, cellRect(icon))) icon.selected = true;
    }
    return .none;
}
