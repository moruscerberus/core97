// gui/window.zig - Core97-style window chrome and titlebar buttons.

const fb = @import("framebuffer.zig");
const ui = @import("ui.zig");

fn ditherShadow(x: u32, y: u32, w: u32, h: u32) void {
    var yy: u32 = 0;
    while (yy < h) : (yy += 1) {
        var xx: u32 = 0;
        while (xx < w) : (xx += 1) {
            if (((xx + yy) & 1) == 0) fb.putPixel(x + xx, y + yy, 0x404040);
        }
    }
}

fn drawTitlebarButton(x: u32, y: u32) void {
    const w: u32 = 16;
    const h: u32 = 14;
    const hovered = ui.hit(x, y, w, h);
    fb.fillRect(x, y, w, h, if (hovered) 0xD8E8FF else fb.CORE97_GREY);
    fb.draw3DBorder(x, y, w, h, true);
}

fn drawMinimizeIcon(x: u32, y: u32) void {
    drawTitlebarButton(x, y);
    fb.fillRect(x + 3, y + 9, 8, 2, fb.CORE97_BLACK);
}

fn drawMaximizeIcon(x: u32, y: u32) void {
    drawTitlebarButton(x, y);
    fb.fillRect(x + 3, y + 3, 10, 8, fb.CORE97_BLACK);
    fb.fillRect(x + 4, y + 5, 8, 5, fb.CORE97_GREY);
}

fn drawCloseIcon(x: u32, y: u32) void {
    drawTitlebarButton(x, y);
    const size: u32 = 8;
    const ox = x + 4;
    const oy = y + 3;
    var i: u32 = 0;
    while (i < size) : (i += 1) {
        fb.putPixel(ox + i, oy + i, fb.CORE97_BLACK);
        fb.putPixel(ox + i + 1, oy + i, fb.CORE97_BLACK);
        fb.putPixel(ox + (size - 1 - i), oy + i, fb.CORE97_BLACK);
        fb.putPixel(ox + (size - 1 - i) + 1, oy + i, fb.CORE97_BLACK);
    }
}

pub fn drawChrome(x: i32, y: i32, w: u32, h: u32, title: []const u8) void {
    const safe_x: i32 = if (x < 0) 0 else x;
    const safe_y: i32 = if (y < 0) 0 else y;
    const ux: u32 = @intCast(safe_x);
    const uy: u32 = @intCast(safe_y);

    // Simple classic desktop shadow. It gives windows depth without
    // needing alpha blending: a dark offset rectangle behind the chrome.
    if (ux + 4 < fb.fb_width and uy + 4 < fb.fb_height) {
        ditherShadow(ux + 4, uy + 4, w, h);
    }

    fb.fillRect(ux, uy, w, h, fb.CORE97_GREY);
    fb.draw3DBorder(ux, uy, w, h, true);
    fb.fillRect(ux + 2, uy + 2, w - 4, 18, fb.CORE97_BLUE);
    fb.drawString(ux + 8, uy + 7, title, fb.CORE97_WHITE, fb.CORE97_BLUE);

    const btn_y = uy + 3;
    const btn_spacing: u32 = 18;
    const close_x = ux + w - 2 - 16;
    const maximize_x = close_x - btn_spacing;
    const minimize_x = maximize_x - btn_spacing;

    drawMinimizeIcon(minimize_x, btn_y);
    drawMaximizeIcon(maximize_x, btn_y);
    drawCloseIcon(close_x, btn_y);
}

pub fn drawEditorPane(x: u32, y: u32, w: u32, h: u32) void {
    fb.fillRect(x, y, w, h, fb.CORE97_WHITE);
    fb.draw3DBorder(x, y, w, h, false);
}

// ===========================================================================
// Windowing framework
// ===========================================================================
// Everything below is the generic "be a window" behavior: position, size,
// open/closed/minimized/maximized state, chrome (titlebar + buttons),
// dragging, z-order, and the taskbar entry list. None of it knows or
// cares what's *inside* a window - that's supplied per-app through the
// AppVTable below, which is Zig's usual stand-in for inheritance: shared
// mechanics live once, here; only the genuinely per-app parts (drawing
// content, handling clicks inside it, taking keyboard input) are
// supplied by each app through a small set of function pointers.

const animation = @import("animation.zig");
const taskbar = @import("taskbar.zig");
const tasks = @import("../kernel/tasks.zig");
pub const Rect = animation.Rect;

pub const MouseButton = enum { left, right };
pub const ChromeButton = enum { none, minimize, maximize, close };
pub const WindowState = enum { closed, normal, minimized, maximized };

/// Apps built into the kernel binary. A future scripted app (run by the
/// small VM/SDK) would get its own AppVTable instance built at runtime
/// instead of a variant here - this enum only exists so launchers (the
/// Start menu, taskbar) can say "open the Notepad" without reaching into
/// notepad.zig directly.
pub const BuiltinApp = enum { notepad, explorer, counter_demo, device_manager, command_prompt, task_manager, control_panel, web_browser };

/// What a content-level event handler hands back to the WindowManager
/// when something needs to happen above the app's own window - closing
/// it, or asking for another app to be opened (e.g. Notepad's "Open..."
/// menu item wants Explorer to come to the front).
pub const AppAction = union(enum) {
    none,
    close,
    open_builtin: BuiltinApp,
};

/// The interface every window's content implements.
pub const AppVTable = struct {
    /// Chrome title bar text, e.g. "NOTEPAD".
    title: *const fn (ptr: *anyopaque) []const u8,
    /// Optional extra text drawn in the titlebar right after the title
    /// (Notepad uses this for the current filename). Return "" for none.
    titleDetail: *const fn (ptr: *anyopaque) []const u8,
    /// Draws content into the area below the titlebar. (x, y, w, h) is
    /// that content rectangle, in absolute screen coordinates.
    draw: *const fn (ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void,
    /// A mouse button went down at absolute screen coords (mx, my); the
    /// content rect is passed again so the app can hit-test the same
    /// way it always did. May return an action the manager needs to act
    /// on (closing this window, opening another app).
    onMouseDown: *const fn (ptr: *anyopaque, mx: i32, my: i32, button: MouseButton, x: u32, y: u32, w: u32, h: u32) AppAction,
    /// Mouse moved with the left button held, after this app accepted
    /// the mouse-down that started the drag (text selection, etc). Gets
    /// the same content rect as onMouseDown for hit-testing.
    onMouseDrag: *const fn (ptr: *anyopaque, mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) void,
    /// Left button released.
    onMouseUp: *const fn (ptr: *anyopaque) void,
    /// PS/2 ASCII fallback key, only delivered to the focused window.
    onKeyAscii: *const fn (ptr: *anyopaque, ascii: u8) void,
    /// USB-HID-style key code, only delivered to the focused window.
    /// Returns true if it changed something and needs a redraw.
    onKeyUsb: *const fn (ptr: *anyopaque, code: u8, modifiers: u8, area_w: u32) bool,
    /// True while this app wants to intercept the *next* click no matter
    /// where on screen it lands (Explorer's right-click context menu
    /// while it's open works this way).
    hasModalCapture: *const fn (ptr: *anyopaque) bool,
};

pub const App = struct {
    ptr: *anyopaque,
    vtable: *const AppVTable,

    pub fn title(self: App) []const u8 {
        return self.vtable.title(self.ptr);
    }
    pub fn titleDetail(self: App) []const u8 {
        return self.vtable.titleDetail(self.ptr);
    }
    pub fn draw(self: App, x: u32, y: u32, w: u32, h: u32) void {
        self.vtable.draw(self.ptr, x, y, w, h);
    }
    pub fn onMouseDown(self: App, mx: i32, my: i32, button: MouseButton, x: u32, y: u32, w: u32, h: u32) AppAction {
        return self.vtable.onMouseDown(self.ptr, mx, my, button, x, y, w, h);
    }
    pub fn onMouseDrag(self: App, mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) void {
        self.vtable.onMouseDrag(self.ptr, mx, my, x, y, w, h);
    }
    pub fn onMouseUp(self: App) void {
        self.vtable.onMouseUp(self.ptr);
    }
    pub fn onKeyAscii(self: App, ascii: u8) void {
        self.vtable.onKeyAscii(self.ptr, ascii);
    }
    pub fn onKeyUsb(self: App, code: u8, modifiers: u8, area_w: u32) bool {
        return self.vtable.onKeyUsb(self.ptr, code, modifiers, area_w);
    }
    pub fn hasModalCapture(self: App) bool {
        return self.vtable.hasModalCapture(self.ptr);
    }
};

/// Zig has no classes, so this is the closest equivalent to "inherit
/// from a common App base": pass any type T that implements the eight
/// methods below (same names/signatures as AppVTable, but as plain
/// methods taking *T instead of *anyopaque) and get back a window.App
/// for it. Every app - Notepad, Explorer, and later any scripted app
/// the SDK runs - goes through this same function, so there's exactly
/// one place that defines what "being a window's content" means.
///
///   pub const MyApp = struct {
///       pub fn title(self: *MyApp) []const u8 { ... }
///       pub fn titleDetail(self: *MyApp) []const u8 { ... }
///       pub fn draw(self: *MyApp, x: u32, y: u32, w: u32, h: u32) void { ... }
///       pub fn onMouseDown(self: *MyApp, mx: i32, my: i32, button: MouseButton, x: u32, y: u32, w: u32, h: u32) AppAction { ... }
///       pub fn onMouseDrag(self: *MyApp, mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) void { ... }
///       pub fn onMouseUp(self: *MyApp) void { ... }
///       pub fn onKeyAscii(self: *MyApp, ascii: u8) void { ... }
///       pub fn onKeyUsb(self: *MyApp, code: u8, modifiers: u8, area_w: u32) bool { ... }
///       pub fn hasModalCapture(self: *MyApp) bool { ... }
///   };
///   var instance: MyApp = .{};
///   pub fn asApp() App { return window.appFrom(MyApp, &instance); }
///
/// Missing or mis-typed method -> compile error at the appFrom() call
/// site, same guarantee a real interface/abstract base class gives you.
pub fn appFrom(comptime T: type, instance: *T) App {
    const Trampoline = struct {
        fn title(ptr: *anyopaque) []const u8 {
            return T.title(@as(*T, @ptrCast(@alignCast(ptr))));
        }
        fn titleDetail(ptr: *anyopaque) []const u8 {
            return T.titleDetail(@as(*T, @ptrCast(@alignCast(ptr))));
        }
        fn draw(ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32) void {
            T.draw(@as(*T, @ptrCast(@alignCast(ptr))), x, y, w, h);
        }
        fn onMouseDown(ptr: *anyopaque, mx: i32, my: i32, button: MouseButton, x: u32, y: u32, w: u32, h: u32) AppAction {
            return T.onMouseDown(@as(*T, @ptrCast(@alignCast(ptr))), mx, my, button, x, y, w, h);
        }
        fn onMouseDrag(ptr: *anyopaque, mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) void {
            T.onMouseDrag(@as(*T, @ptrCast(@alignCast(ptr))), mx, my, x, y, w, h);
        }
        fn onMouseUp(ptr: *anyopaque) void {
            T.onMouseUp(@as(*T, @ptrCast(@alignCast(ptr))));
        }
        fn onKeyAscii(ptr: *anyopaque, ascii: u8) void {
            T.onKeyAscii(@as(*T, @ptrCast(@alignCast(ptr))), ascii);
        }
        fn onKeyUsb(ptr: *anyopaque, code: u8, modifiers: u8, area_w: u32) bool {
            return T.onKeyUsb(@as(*T, @ptrCast(@alignCast(ptr))), code, modifiers, area_w);
        }
        fn hasModalCapture(ptr: *anyopaque) bool {
            return T.hasModalCapture(@as(*T, @ptrCast(@alignCast(ptr))));
        }

        const vtable = AppVTable{
            .title = title,
            .titleDetail = titleDetail,
            .draw = draw,
            .onMouseDown = onMouseDown,
            .onMouseDrag = onMouseDrag,
            .onMouseUp = onMouseUp,
            .onKeyAscii = onKeyAscii,
            .onKeyUsb = onKeyUsb,
            .hasModalCapture = hasModalCapture,
        };
    };
    return .{ .ptr = instance, .vtable = &Trampoline.vtable };
}

const TITLEBAR_H: u32 = 20;

fn pointInRect(mx: i32, my: i32, x: i32, y: i32, w: u32, h: u32) bool {
    return mx >= x and my >= y and mx < x + @as(i32, @intCast(w)) and my < y + @as(i32, @intCast(h));
}

/// Hit-tests the minimize/maximize/close buttons drawn by drawChrome.
pub fn chromeButtonAt(mx: i32, my: i32, x: i32, y: i32, w: u32) ChromeButton {
    const btn_y = y + 3;
    if (my < btn_y or my >= btn_y + 14) return .none;
    const close_x = x + @as(i32, @intCast(w)) - 2 - 16;
    const maximize_x = close_x - 18;
    const minimize_x = maximize_x - 18;
    if (mx >= close_x and mx < close_x + 16) return .close;
    if (mx >= maximize_x and mx < maximize_x + 16) return .maximize;
    if (mx >= minimize_x and mx < minimize_x + 16) return .minimize;
    return .none;
}

pub fn isOverTitlebar(mx: i32, my: i32, x: i32, y: i32, w: u32) bool {
    return pointInRect(mx, my, x + 2, y + 2, w - 4, 18);
}

pub const ResizeEdge = enum { none, left, right, top, bottom, top_left, top_right, bottom_left, bottom_right };

const RESIZE_MARGIN: i32 = 5;
pub const MIN_WINDOW_W: u32 = 140;
pub const MIN_WINDOW_H: u32 = 100;

/// Which edge/corner (if any) of a window (mx, my) is close enough to
/// for a resize drag to start. The hit band straddles the border itself
/// (a few px in, a few px out) rather than sitting only outside it -
/// real retro-desktop windows are forgiving about exactly where you grab them.
fn resizeEdgeAt(mx: i32, my: i32, x: i32, y: i32, w: u32, h: u32) ResizeEdge {
    const iw: i32 = @intCast(w);
    const ih: i32 = @intCast(h);
    const near_left = mx >= x - RESIZE_MARGIN and mx <= x + RESIZE_MARGIN;
    const near_right = mx >= x + iw - RESIZE_MARGIN and mx <= x + iw + RESIZE_MARGIN;
    const near_top = my >= y - RESIZE_MARGIN and my <= y + RESIZE_MARGIN;
    const near_bottom = my >= y + ih - RESIZE_MARGIN and my <= y + ih + RESIZE_MARGIN;
    const within_x = mx >= x - RESIZE_MARGIN and mx <= x + iw + RESIZE_MARGIN;
    const within_y = my >= y - RESIZE_MARGIN and my <= y + ih + RESIZE_MARGIN;

    if (!within_x or !within_y) return .none;
    if (near_left and near_top) return .top_left;
    if (near_right and near_top) return .top_right;
    if (near_left and near_bottom) return .bottom_left;
    if (near_right and near_bottom) return .bottom_right;
    if (near_left) return .left;
    if (near_right) return .right;
    if (near_top) return .top;
    if (near_bottom) return .bottom;
    return .none;
}

/// Grows/shrinks a [start, start+len) span from its low edge by `d`,
/// keeping the HIGH edge fixed - used for the left/top resize edges,
/// where dragging changes where the window starts but not where it ends.
fn growFromLow(start: i32, len: u32, d: i32, min_len_u: u32) struct { start: i32, len: u32 } {
    var new_len: i32 = @as(i32, @intCast(len)) - d;
    if (new_len < @as(i32, @intCast(min_len_u))) new_len = @intCast(min_len_u);
    const new_start = start + @as(i32, @intCast(len)) - new_len;
    return .{ .start = new_start, .len = @intCast(new_len) };
}

fn growFromHigh(len: u32, d: i32, min_len_u: u32) u32 {
    var new_len: i32 = @as(i32, @intCast(len)) + d;
    if (new_len < @as(i32, @intCast(min_len_u))) new_len = @intCast(min_len_u);
    return @intCast(new_len);
}

pub const ManagedWindow = struct {
    app: App,
    builtin: ?BuiltinApp,
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    normal_x: i32,
    normal_y: i32,
    normal_w: u32,
    normal_h: u32,
    state: WindowState,

    fn rect(self: ManagedWindow) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }
};

pub const MAX_WINDOWS: usize = 16;

/// Owns every window's position/size/state and dispatches input to the
/// right one. Slots 0 and 1 are the built-in singleton apps (Notepad,
/// Explorer); slots 2.. are free for future scripted apps opened at
/// runtime by the SDK/VM, which is the reason this is a fixed table of
/// optional windows instead of just two named variables.
pub const WindowManager = struct {
    windows: [MAX_WINDOWS]?ManagedWindow = [_]?ManagedWindow{null} ** MAX_WINDOWS,
    /// Back-to-front draw order; the last entry is topmost/focused.
    order: [MAX_WINDOWS]usize = [_]usize{0} ** MAX_WINDOWS,
    order_len: usize = 0,
    dragging: ?usize = null,
    drag_offset_x: i32 = 0,
    drag_offset_y: i32 = 0,
    resizing: ?usize = null,
    resize_edge: ResizeEdge = .none,
    resize_start_mouse_x: i32 = 0,
    resize_start_mouse_y: i32 = 0,
    resize_start_rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn register(self: *WindowManager, slot: usize, builtin: ?BuiltinApp, app: App, default_rect: Rect) void {
        self.windows[slot] = ManagedWindow{
            .app = app,
            .builtin = builtin,
            .x = default_rect.x,
            .y = default_rect.y,
            .w = default_rect.w,
            .h = default_rect.h,
            .normal_x = default_rect.x,
            .normal_y = default_rect.y,
            .normal_w = default_rect.w,
            .normal_h = default_rect.h,
            .state = .closed,
        };
        tasks.register(slot, app.title());
        tasks.setState(slot, .closed);
    }

    pub fn findBuiltin(self: *WindowManager, kind: BuiltinApp) ?usize {
        for (self.windows, 0..) |maybe_w, i| {
            if (maybe_w) |w| {
                if (w.builtin != null and w.builtin.? == kind) return i;
            }
        }
        return null;
    }

    fn maxRect() Rect {
        return .{ .x = 0, .y = 0, .w = fb.fb_width, .h = fb.fb_height - taskbar.HEIGHT };
    }

    fn taskbarSlotOf(self: *WindowManager, slot: usize) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < slot) : (i += 1) {
            if (self.windows[i] != null and self.windows[i].?.state != .closed) n += 1;
        }
        return n;
    }

    fn taskbarRectFor(self: *WindowManager, slot: usize) Rect {
        const r = taskbar.buttonRect(self.taskbarSlotOf(slot));
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    fn smallCenterOf(w: ManagedWindow) Rect {
        return animation.smallCenter(w.rect());
    }

    pub fn bringToFront(self: *WindowManager, slot: usize) void {
        var i: usize = 0;
        var write: usize = 0;
        while (i < self.order_len) : (i += 1) {
            if (self.order[i] != slot) {
                self.order[write] = self.order[i];
                write += 1;
            }
        }
        self.order_len = write;
        self.order[self.order_len] = slot;
        self.order_len += 1;
        tasks.bumpSwitch(slot);
    }

    pub fn restore(self: *WindowManager, slot: usize) void {
        const w: *ManagedWindow = if (self.windows[slot]) |*win| win else return;
        if (w.state == .closed) {
            w.x = w.normal_x;
            w.y = w.normal_y;
            w.w = w.normal_w;
            w.h = w.normal_h;
            animation.animateRect(smallCenterOf(w.*), w.rect());
            w.state = .normal;
            tasks.setState(slot, .running);
        } else if (w.state == .minimized) {
            animation.animateRect(self.taskbarRectFor(slot), w.rect());
            w.state = .normal;
            tasks.setState(slot, .running);
        }
        self.bringToFront(slot);
    }

    pub fn minimize(self: *WindowManager, slot: usize) void {
        const w: *ManagedWindow = if (self.windows[slot]) |*win| win else return;
        animation.animateRect(w.rect(), self.taskbarRectFor(slot));
        w.state = .minimized;
        tasks.setState(slot, .minimized);
        if (self.dragging != null and self.dragging.? == slot) self.dragging = null;
    }

    pub fn close(self: *WindowManager, slot: usize) void {
        const w: *ManagedWindow = if (self.windows[slot]) |*win| win else return;
        animation.animateRect(w.rect(), smallCenterOf(w.*));
        w.state = .closed;
        tasks.setState(slot, .closed);
        if (self.dragging != null and self.dragging.? == slot) self.dragging = null;
    }

    pub fn toggleMaximize(self: *WindowManager, slot: usize) void {
        const w: *ManagedWindow = if (self.windows[slot]) |*win| win else return;
        if (w.state == .maximized) {
            animation.animateRect(w.rect(), .{ .x = w.normal_x, .y = w.normal_y, .w = w.normal_w, .h = w.normal_h });
            w.x = w.normal_x;
            w.y = w.normal_y;
            w.w = w.normal_w;
            w.h = w.normal_h;
            w.state = .normal;
            tasks.setState(slot, .running);
        } else {
            w.normal_x = w.x;
            w.normal_y = w.y;
            w.normal_w = w.w;
            w.normal_h = w.h;
            animation.animateRect(w.rect(), maxRect());
            const m = maxRect();
            w.x = m.x;
            w.y = m.y;
            w.w = m.w;
            w.h = m.h;
            w.state = .maximized;
            tasks.setState(slot, .maximized);
            if (self.dragging != null and self.dragging.? == slot) self.dragging = null;
        }
    }

    pub fn isOpen(self: *WindowManager, slot: usize) bool {
        const w = self.windows[slot] orelse return false;
        return w.state != .closed;
    }

    pub fn isVisible(self: *WindowManager, slot: usize) bool {
        const w = self.windows[slot] orelse return false;
        return w.state == .normal or w.state == .maximized;
    }

    pub fn contentArea(self: *WindowManager, slot: usize) Rect {
        const w = self.windows[slot] orelse return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        return .{ .x = w.x, .y = w.y + @as(i32, @intCast(TITLEBAR_H)), .w = w.w, .h = if (w.h > TITLEBAR_H) w.h - TITLEBAR_H else 0 };
    }

    /// Draws every open window back-to-front (so the focused one in
    /// `order` ends up on top), then lets each app draw its own content.
    pub fn drawAll(self: *WindowManager) void {
        var i: usize = 0;
        while (i < self.order_len) : (i += 1) {
            const slot = self.order[i];
            const w = self.windows[slot] orelse continue;
            if (w.state != .normal and w.state != .maximized) continue;
            drawChrome(w.x, w.y, w.w, w.h, w.app.title());
            const detail = w.app.titleDetail();
            if (detail.len != 0) {
                const safe_x: i32 = if (w.x < 0) 0 else w.x;
                const safe_y: i32 = if (w.y < 0) 0 else w.y;
                fb.drawString(@intCast(safe_x + 84), @intCast(safe_y + 7), detail, fb.CORE97_WHITE, fb.CORE97_BLUE);
            }
            const area = self.contentArea(slot);
            if (area.w > 0 and area.h > 0) {
                w.app.draw(@intCast(area.x), @intCast(area.y), area.w, area.h);
            }
        }
    }

    /// Slots in stable (registration) order, for the taskbar row and for
    /// picking which window catches a click when several overlap.
    pub fn taskbarEntries(self: *WindowManager, out: []taskbar.TaskbarEntry) usize {
        var n: usize = 0;
        const focused_slot: ?usize = if (self.order_len > 0) self.order[self.order_len - 1] else null;
        for (self.windows, 0..) |maybe_w, slot| {
            if (n >= out.len) break;
            const w = maybe_w orelse continue;
            if (w.state == .closed) continue;
            out[n] = .{ .title = w.app.title(), .active = focused_slot != null and focused_slot.? == slot };
            n += 1;
        }
        return n;
    }

    /// Inverse of taskbarEntries' ordering: which window slot is the Nth
    /// open window, for mapping a clicked taskbar button back to a slot.
    pub fn slotAtTaskbarIndex(self: *WindowManager, index: u32) ?usize {
        var n: u32 = 0;
        for (self.windows, 0..) |maybe_w, slot| {
            const w = maybe_w orelse continue;
            if (w.state == .closed) continue;
            if (n == index) return slot;
            n += 1;
        }
        return null;
    }

    fn topmostAt(self: *WindowManager, mx: i32, my: i32) ?usize {
        var i: usize = self.order_len;
        while (i > 0) {
            i -= 1;
            const slot = self.order[i];
            const w = self.windows[slot] orelse continue;
            if (w.state != .normal and w.state != .maximized) continue;
            if (pointInRect(mx, my, w.x, w.y, w.w, w.h)) return slot;
        }
        return null;
    }

    /// Topmost window whose border is close enough to (mx, my) to start
    /// a resize drag. Maximized windows are skipped - same as real
    /// classic desktop conventions, you un-maximize before you can resize.
    fn topmostResizableAt(self: *WindowManager, mx: i32, my: i32) ?struct { slot: usize, edge: ResizeEdge } {
        var i: usize = self.order_len;
        while (i > 0) {
            i -= 1;
            const slot = self.order[i];
            const w = self.windows[slot] orelse continue;
            if (w.state != .normal) continue;
            const edge = resizeEdgeAt(mx, my, w.x, w.y, w.w, w.h);
            if (edge != .none) return .{ .slot = slot, .edge = edge };
            // Don't fall through to windows behind this one once we're
            // inside its rect - same "topmost wins" rule topmostAt uses.
            if (pointInRect(mx, my, w.x, w.y, w.w, w.h)) return null;
        }
        return null;
    }

    /// True if any open window currently wants to capture the next click
    /// no matter where it lands (a context menu being open, say).
    fn modalCaptureSlot(self: *WindowManager) ?usize {
        var i: usize = 0;
        while (i < MAX_WINDOWS) : (i += 1) {
            const w = self.windows[i] orelse continue;
            if (w.state == .closed) continue;
            if (w.app.hasModalCapture()) return i;
        }
        return null;
    }

    /// Handles a left/right mouse-down at (mx, my). Returns the slot that
    /// ended up handling it (now focused), if any, plus any action it
    /// asked the caller to perform.
    pub const MouseDownResult = struct { slot: ?usize = null, action: AppAction = .none };

    pub fn handleMouseDown(self: *WindowManager, mx: i32, my: i32, button: MouseButton) MouseDownResult {
        if (self.modalCaptureSlot()) |slot| {
            const w = self.windows[slot].?;
            const area = self.contentArea(slot);
            const action = w.app.onMouseDown(mx, my, button, @intCast(area.x), @intCast(area.y), area.w, area.h);
            return .{ .slot = slot, .action = action };
        }

        if (button == .left) {
            if (self.topmostResizableAt(mx, my)) |hit| {
                self.bringToFront(hit.slot);
                self.resizing = hit.slot;
                self.resize_edge = hit.edge;
                self.resize_start_mouse_x = mx;
                self.resize_start_mouse_y = my;
                self.resize_start_rect = self.windows[hit.slot].?.rect();
                return .{ .slot = hit.slot };
            }
        }

        const slot = self.topmostAt(mx, my) orelse return .{};
        const w = self.windows[slot].?;
        self.bringToFront(slot);

        if (button == .left) {
            switch (chromeButtonAt(mx, my, w.x, w.y, w.w)) {
                .minimize => {
                    self.minimize(slot);
                    return .{ .slot = slot };
                },
                .maximize => {
                    self.toggleMaximize(slot);
                    return .{ .slot = slot };
                },
                .close => {
                    self.close(slot);
                    return .{ .slot = slot, .action = .close };
                },
                .none => {},
            }
        }
        if (button == .left and isOverTitlebar(mx, my, w.x, w.y, w.w)) {
            self.dragging = slot;
            self.drag_offset_x = mx - w.x;
            self.drag_offset_y = my - w.y;
            return .{ .slot = slot };
        }

        const area = self.contentArea(slot);
        if (area.w > 0 and area.h > 0 and pointInRect(mx, my, area.x, area.y, area.w, area.h)) {
            const action = w.app.onMouseDown(mx, my, button, @intCast(area.x), @intCast(area.y), area.w, area.h);
            return .{ .slot = slot, .action = action };
        }
        return .{ .slot = slot };
    }

    /// Continues a titlebar drag or border resize, or forwards to the
    /// dragging content's own onMouseDrag (e.g. text selection).
    pub fn handleMouseMove(self: *WindowManager, mx: i32, my: i32, left_down: bool) void {
        if (!left_down) {
            self.dragging = null;
            self.resizing = null;
            return;
        }
        if (self.resizing) |slot| {
            const w: *ManagedWindow = if (self.windows[slot]) |*win| win else return;
            const dx = mx - self.resize_start_mouse_x;
            const dy = my - self.resize_start_mouse_y;
            const start = self.resize_start_rect;
            var nx = start.x;
            var ny = start.y;
            var nw = start.w;
            var nh = start.h;

            switch (self.resize_edge) {
                .left, .top_left, .bottom_left => {
                    const r = growFromLow(start.x, start.w, dx, MIN_WINDOW_W);
                    nx = r.start;
                    nw = r.len;
                },
                .right, .top_right, .bottom_right => nw = growFromHigh(start.w, dx, MIN_WINDOW_W),
                else => {},
            }
            switch (self.resize_edge) {
                .top, .top_left, .top_right => {
                    const r = growFromLow(start.y, start.h, dy, MIN_WINDOW_H);
                    ny = r.start;
                    nh = r.len;
                },
                .bottom, .bottom_left, .bottom_right => nh = growFromHigh(start.h, dy, MIN_WINDOW_H),
                else => {},
            }

            if (nx < 0) nx = 0;
            if (ny < 0) ny = 0;
            w.x = nx;
            w.y = ny;
            w.w = nw;
            w.h = nh;
            return;
        }
        if (self.dragging) |slot| {
            const w: *ManagedWindow = if (self.windows[slot]) |*win| win else return;
            if (w.state == .maximized) return;
            w.x = mx - self.drag_offset_x;
            w.y = my - self.drag_offset_y;
            const max_x: i32 = @as(i32, @intCast(fb.fb_width)) - 20;
            const max_y: i32 = @as(i32, @intCast(fb.fb_height)) - 20 - @as(i32, @intCast(taskbar.HEIGHT));
            if (w.x < 0) w.x = 0;
            if (w.y < 0) w.y = 0;
            if (w.x > max_x) w.x = max_x;
            if (w.y > max_y) w.y = max_y;
        }
    }

    pub fn forwardDrag(self: *WindowManager, slot: usize, mx: i32, my: i32) void {
        const w = self.windows[slot] orelse return;
        const area = self.contentArea(slot);
        w.app.onMouseDrag(mx, my, @intCast(area.x), @intCast(area.y), area.w, area.h);
    }

    pub fn forwardMouseUp(self: *WindowManager, slot: usize) void {
        const w = self.windows[slot] orelse return;
        w.app.onMouseUp();
    }

    pub fn forceClose(self: *WindowManager, slot: usize) void {
        if (slot >= MAX_WINDOWS) return;
        self.close(slot);
    }

    pub fn forceSwitchTo(self: *WindowManager, slot: usize) void {
        if (slot >= MAX_WINDOWS) return;
        if (self.windows[slot] == null) return;
        self.restore(slot);
    }

    pub fn focused(self: *WindowManager) ?usize {
        if (self.order_len == 0) return null;
        return self.order[self.order_len - 1];
    }
};
