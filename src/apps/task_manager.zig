// apps/task_manager.zig - Core97-style Task Manager.

const fb = @import("../gui/framebuffer.zig");
const window = @import("../gui/window.zig");
const tasks = @import("../kernel/tasks.zig");
const memory = @import("../kernel/memory.zig");
const pit = @import("../drivers/pit.zig");
const ui = @import("../gui/ui.zig");

var selected_slot: ?usize = null;
var pending_switch: ?usize = null;
var pending_end: ?usize = null;

pub fn takeSwitchRequest() ?usize { const r = pending_switch; pending_switch = null; return r; }
pub fn takeEndRequest() ?usize { const r = pending_end; pending_end = null; return r; }

fn drawButton(x: u32, y: u32, w: u32, label: []const u8, enabled: bool) void {
    ui.drawButton(x, y, w, 22, label, enabled);
}

fn rowSlotAt(mx: i32, my: i32, x: u32, y: u32, w: u32, h: u32) ?usize {
    _ = w;
    if (my < @as(i32, @intCast(y + 58))) return null;
    if (my >= @as(i32, @intCast(y + h - 76))) return null;
    if (mx < @as(i32, @intCast(x + 10))) return null;
    const row: usize = @intCast(@divTrunc(my - @as(i32, @intCast(y + 58)), 18));
    var visible: usize = 0;
    var i: usize = 0;
    while (i < tasks.MAX_TASKS) : (i += 1) {
        const t = tasks.get(i) orelse continue;
        if (t.state == .closed) continue;
        if (visible == row) return t.slot;
        visible += 1;
    }
    return null;
}

const TaskManager = struct {
    pub fn title(_: *TaskManager) []const u8 { return "TASK MANAGER"; }
    pub fn titleDetail(_: *TaskManager) []const u8 { return ""; }

    pub fn draw(_: *TaskManager, x: u32, y: u32, w: u32, h: u32) void {
        fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        fb.drawString(x + 8, y + 6, "Applications", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + 104, y + 6, "Processes", fb.CORE97_DARK_GREY, fb.CORE97_GREY);
        fb.drawString(x + 190, y + 6, "Performance", fb.CORE97_DARK_GREY, fb.CORE97_GREY);

        const list_y = y + 24;
        const list_h = if (h > 96) h - 96 else 30;
        fb.fillRect(x + 8, list_y, w - 16, list_h, fb.CORE97_WHITE);
        fb.draw3DBorder(x + 8, list_y, w - 16, list_h, false);
        fb.fillRect(x + 10, list_y + 2, w - 20, 18, fb.CORE97_GREY);
        fb.drawString(x + 14, list_y + 8, "Task", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + w - 116, list_y + 8, "Status", fb.CORE97_BLACK, fb.CORE97_GREY);

        var row_y = list_y + 24;
        var i: usize = 0;
        while (i < tasks.MAX_TASKS) : (i += 1) {
            const t = tasks.get(i) orelse continue;
            if (t.state == .closed) continue;
            if (row_y + 18 >= list_y + list_h) break;
            const selected = selected_slot != null and selected_slot.? == t.slot;
            const hovered = ui.hit(x + 10, row_y - 2, w - 20, 18);
            const row_bg = if (selected) fb.CORE97_BLUE else if (hovered) 0xD8E8FF else fb.CORE97_WHITE;
            const row_fg = if (selected) fb.CORE97_WHITE else fb.CORE97_BLACK;
            if (selected or hovered) fb.fillRect(x + 10, row_y - 2, w - 20, 18, row_bg);
            fb.drawString(x + 16, row_y + 3, t.title, row_fg, row_bg);
            fb.drawString(x + w - 116, row_y + 3, tasks.stateName(t.state), row_fg, row_bg);
            row_y += 18;
        }

        const sy = y + h - 64;
        var buf: [80]u8 = undefined;
        var p: usize = 0;
        appendText(&buf, &p, "Tasks: "); appendDec(&buf, &p, tasks.countOpen());
        appendText(&buf, &p, "   Uptime ticks: "); appendDec(&buf, &p, @as(usize, @intCast(pit.ticks)));
        fb.drawString(x + 10, sy, buf[0..p], fb.CORE97_BLACK, fb.CORE97_GREY);

        const st = memory.stats();
        p = 0; appendText(&buf, &p, "RAM pages free: "); appendDec(&buf, &p, st.free_pages);
        appendText(&buf, &p, " / "); appendDec(&buf, &p, st.total_pages);
        fb.drawString(x + 10, sy + 14, buf[0..p], fb.CORE97_BLACK, fb.CORE97_GREY);

        const enabled = selected_slot != null;
        drawButton(x + w - 260, y + h - 34, 80, "Switch To", enabled);
        drawButton(x + w - 172, y + h - 34, 72, "End Task", enabled);
        drawButton(x + w - 92, y + h - 34, 74, "New Task", true);
    }

    pub fn onMouseDown(_: *TaskManager, mx: i32, my: i32, button: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        if (button != .left) return .none;
        const bx = x + w;
        const by = y + h - 34;
        if (my >= @as(i32, @intCast(by)) and my < @as(i32, @intCast(by + 22))) {
            if (mx >= @as(i32, @intCast(bx - 260)) and mx < @as(i32, @intCast(bx - 180))) {
                if (selected_slot) |s| { pending_switch = s; }
                return .none;
            }
            if (mx >= @as(i32, @intCast(bx - 172)) and mx < @as(i32, @intCast(bx - 100))) {
                if (selected_slot) |s| { pending_end = s; }
                return .none;
            }
            if (mx >= @as(i32, @intCast(bx - 92)) and mx < @as(i32, @intCast(bx - 18))) return .{ .open_builtin = .command_prompt };
        }
        if (rowSlotAt(mx, my, x, y, w, h)) |slot| selected_slot = slot;
        return .none;
    }
    pub fn onMouseDrag(_: *TaskManager, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *TaskManager) void {}
    pub fn onKeyAscii(_: *TaskManager, _: u8) void {}
    pub fn onKeyUsb(_: *TaskManager, _: u8, _: u8, _: u32) bool { return false; }
    pub fn hasModalCapture(_: *TaskManager) bool { return false; }
};

fn appendText(buf: []u8, pos: *usize, text: []const u8) void { var i: usize = 0; while (i < text.len and pos.* < buf.len) : (i += 1) { buf[pos.*] = text[i]; pos.* += 1; } }
fn appendDec(buf: []u8, pos: *usize, value: usize) void {
    if (value == 0) { if (pos.* < buf.len) { buf[pos.*] = '0'; pos.* += 1; } return; }
    var tmp: [20]u8 = undefined; var n = value; var len: usize = 0;
    while (n > 0 and len < tmp.len) : (len += 1) { tmp[len] = '0' + @as(u8, @intCast(n % 10)); n /= 10; }
    while (len > 0 and pos.* < buf.len) { len -= 1; buf[pos.*] = tmp[len]; pos.* += 1; }
}

var instance: TaskManager = .{};
pub fn asApp() window.App { return window.appFrom(TaskManager, &instance); }
