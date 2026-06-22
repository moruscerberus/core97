// apps/script_app.zig - a scripted app, loaded from a .ws file in the
// VFS and run by the SDK's tiny interpreter (sdk/script.zig). This is
// the concrete proof the SDK actually works: ScriptApp derives from the
// exact same window.App base as Notepad and File Explorer, via
// window.appFrom(), even though its content is interpreted rather than
// compiled Zig code.

const fb = @import("../gui/framebuffer.zig");
const vfs = @import("../fs/vfs.zig");
const window = @import("../gui/window.zig");
const script = @import("../sdk/script.zig");

/// Absolute screen origin of the app's content area, refreshed right
/// before every draw/click/key dispatch. This is what HostOps uses to
/// translate the content-relative coordinates scripts write in into
/// real screen coordinates - the script itself never sees a window
/// position, only its own (0,0)-origin content rect.
const DrawCtx = struct { ox: i32 = 0, oy: i32 = 0 };

fn clampToScreen(v: i32) u32 {
    return if (v < 0) 0 else @intCast(v);
}

fn colorOf(c: i32) u32 {
    return if (c < 0) 0 else @intCast(c);
}

fn opRect(ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, color: i32) void {
    if (w <= 0 or h <= 0) return;
    const origin: *DrawCtx = @ptrCast(@alignCast(ctx));
    fb.fillRect(clampToScreen(origin.ox + x), clampToScreen(origin.oy + y), @intCast(w), @intCast(h), colorOf(color));
}

fn opText(ctx: *anyopaque, x: i32, y: i32, text: []const u8, fg: i32, bg: i32) void {
    const origin: *DrawCtx = @ptrCast(@alignCast(ctx));
    fb.drawString(clampToScreen(origin.ox + x), clampToScreen(origin.oy + y), text, colorOf(fg), colorOf(bg));
}

fn opBorder(ctx: *anyopaque, x: i32, y: i32, w: i32, h: i32, raised: bool) void {
    if (w <= 0 or h <= 0) return;
    const origin: *DrawCtx = @ptrCast(@alignCast(ctx));
    fb.draw3DBorder(clampToScreen(origin.ox + x), clampToScreen(origin.oy + y), @intCast(w), @intCast(h), raised);
}

const ops = script.HostOps{
    .drawRect = opRect,
    .drawText = opText,
    .drawBorder = opBorder,
};

pub const ScriptApp = struct {
    prog: script.Program = .{ .valid = false, .error_msg = "not loaded" },
    interp: script.Interp = undefined,
    origin: DrawCtx = .{},
    title_text: []const u8 = "SCRIPT",

    /// Compiles the .ws file at `path` and resets all script state.
    /// Safe to call again later to reload after editing the file.
    pub fn loadFromVfs(self: *ScriptApp, path: []const u8, app_title: []const u8) void {
        self.title_text = app_title;
        if (vfs.resolvePath(path)) |h| {
            script.compileInto(vfs.readFile(h), &self.prog);
        } else {
            self.prog = .{ .valid = false, .error_msg = "file not found" };
        }
        self.interp = script.Interp.init(&self.prog, &ops, &self.origin);
        if (self.prog.valid) self.interp.loadVarDecls();
    }

    pub fn title(self: *ScriptApp) []const u8 {
        return self.title_text;
    }

    pub fn titleDetail(_: *ScriptApp) []const u8 {
        return "";
    }

    pub fn draw(self: *ScriptApp, x: u32, y: u32, w: u32, h: u32) void {
        fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        if (!self.prog.valid) {
            fb.drawString(x + 8, y + 8, "Script error:", fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 8, y + 22, self.prog.error_msg, fb.CORE97_RED, fb.CORE97_GREY);
            return;
        }
        self.origin = .{ .ox = @intCast(x), .oy = @intCast(y) };
        self.interp.runDraw(.{ .w = w, .h = h });
    }

    pub fn onMouseDown(self: *ScriptApp, mx: i32, my: i32, button: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        if (button != .left or !self.prog.valid) return .none;
        self.origin = .{ .ox = @intCast(x), .oy = @intCast(y) };
        self.interp.runClick(.{
            .w = w,
            .h = h,
            .mouse_x = mx - @as(i32, @intCast(x)),
            .mouse_y = my - @as(i32, @intCast(y)),
            .mouse_down = true,
        });
        return .none;
    }

    pub fn onMouseDrag(_: *ScriptApp, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *ScriptApp) void {}

    pub fn onKeyAscii(self: *ScriptApp, ascii: u8) void {
        if (!self.prog.valid) return;
        self.interp.runKey(.{ .key_ascii = ascii });
    }

    pub fn onKeyUsb(_: *ScriptApp, _: u8, _: u8, _: u32) bool {
        return false;
    }

    pub fn hasModalCapture(_: *ScriptApp) bool {
        return false;
    }
};

var instance: ScriptApp = .{};

pub fn asApp() window.App {
    return window.appFrom(ScriptApp, &instance);
}

pub fn load(path: []const u8, title: []const u8) void {
    instance.loadFromVfs(path, title);
}
