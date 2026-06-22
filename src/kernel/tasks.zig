// kernel/tasks.zig - tiny Core97 task/process table for Task Manager.

pub const MAX_TASKS: usize = 16;

pub const TaskState = enum { closed, running, minimized, maximized };

pub const TaskInfo = struct {
    used: bool = false,
    slot: usize = 0,
    title: []const u8 = "",
    state: TaskState = .closed,
    switches: u32 = 0,
};

var tasks: [MAX_TASKS]TaskInfo = [_]TaskInfo{.{}} ** MAX_TASKS;

pub fn register(slot: usize, title: []const u8) void {
    if (slot >= MAX_TASKS) return;
    tasks[slot] = .{ .used = true, .slot = slot, .title = title, .state = .closed, .switches = 0 };
}

pub fn setTitle(slot: usize, title: []const u8) void {
    if (slot >= MAX_TASKS) return;
    tasks[slot].used = true;
    tasks[slot].slot = slot;
    tasks[slot].title = title;
}

pub fn setState(slot: usize, state: TaskState) void {
    if (slot >= MAX_TASKS) return;
    tasks[slot].used = true;
    tasks[slot].slot = slot;
    tasks[slot].state = state;
}

pub fn bumpSwitch(slot: usize) void {
    if (slot >= MAX_TASKS) return;
    tasks[slot].switches += 1;
}

pub fn countOpen() usize {
    var n: usize = 0;
    for (tasks) |t| { if (t.used and t.state != .closed) n += 1; }
    return n;
}

pub fn get(index: usize) ?TaskInfo {
    if (index >= MAX_TASKS) return null;
    if (!tasks[index].used) return null;
    return tasks[index];
}

pub fn stateName(state: TaskState) []const u8 {
    return switch (state) {
        .closed => "Closed",
        .running => "Running",
        .minimized => "Minimized",
        .maximized => "Maximized",
    };
}
