// gui/selection.zig - reusable drag-to-select ("rubber band") helper.
//
// Every app that wants multi-select (File Explorer's file list, the
// desktop's icon grid, and whatever comes next) needs the exact same
// three things: track a drag rectangle from mouse-down to mouse-up,
// draw it as a marching-ants outline while active, and let the caller
// ask "does my item's rect fall inside the selection rect" once it's
// finished. That's all this is - it owns none of the actual selection
// state (which items are selected), since that's inherently per-app
// (a list of rows vs. a grid of icons need different storage), but it
// makes adding drag-select to a new app a small, mechanical addition
// rather than something to design from scratch each time:
//
//   var band: selection.RubberBand = .{};
//
//   // mouse down, on empty space (not on an existing item):
//   band.begin(mx, my);
//
//   // mouse drag:
//   band.update(mx, my);
//
//   // mouse up:
//   if (band.end()) |rect| {
//       // for each of my items: if selection.rectsIntersect(rect, item_rect) mark it selected
//   }
//
//   // in draw():
//   band.draw();

const fb = @import("framebuffer.zig");
const window = @import("window.zig");

pub const Rect = window.Rect;

pub fn rectsIntersect(a: Rect, b: Rect) bool {
    const a_right = a.x + @as(i32, @intCast(a.w));
    const a_bottom = a.y + @as(i32, @intCast(a.h));
    const b_right = b.x + @as(i32, @intCast(b.w));
    const b_bottom = b.y + @as(i32, @intCast(b.h));
    return a.x < b_right and a_right > b.x and a.y < b_bottom and a_bottom > b.y;
}

pub const RubberBand = struct {
    active: bool = false,
    start_x: i32 = 0,
    start_y: i32 = 0,
    cur_x: i32 = 0,
    cur_y: i32 = 0,

    /// Call on mouse-down, once you've already checked the click wasn't
    /// on an existing item (a plain click on an item should select just
    /// that one item directly - the rubber band is for dragging across
    /// empty space to select several at once).
    pub fn begin(self: *RubberBand, x: i32, y: i32) void {
        self.active = true;
        self.start_x = x;
        self.start_y = y;
        self.cur_x = x;
        self.cur_y = y;
    }

    /// Call on every mouse-move while the button is held and `active`
    /// is true.
    pub fn update(self: *RubberBand, x: i32, y: i32) void {
        if (!self.active) return;
        self.cur_x = x;
        self.cur_y = y;
    }

    /// Call on mouse-up. Returns the final selection rectangle (in
    /// whatever coordinate space you fed in - typically screen
    /// coordinates, same as item hit-rects) if a drag was in progress,
    /// or null if nothing was active (so callers can tell "no rubber-
    /// band selection happened this click" apart from "selected an
    /// empty rectangle").
    pub fn end(self: *RubberBand) ?Rect {
        if (!self.active) return null;
        self.active = false;
        return self.rect();
    }

    /// The current (possibly still-growing) selection rectangle,
    /// normalized so width/height are always non-negative regardless of
    /// which direction the drag went.
    pub fn rect(self: *const RubberBand) Rect {
        const x0 = @min(self.start_x, self.cur_x);
        const y0 = @min(self.start_y, self.cur_y);
        const x1 = @max(self.start_x, self.cur_x);
        const y1 = @max(self.start_y, self.cur_y);
        return .{ .x = x0, .y = y0, .w = @intCast(x1 - x0), .h = @intCast(y1 - y0) };
    }

    /// Draws the marching-ants outline if a drag is in progress. Safe
    /// to call unconditionally from draw() every frame - it's a no-op
    /// when not active.
    pub fn draw(self: *const RubberBand) void {
        if (!self.active) return;
        const r = self.rect();
        fb.drawDashedRect(r.x, r.y, r.w, r.h, fb.CORE97_BLACK);
    }
};
