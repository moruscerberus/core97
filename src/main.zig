// main.zig - the actual file passed to `zig build-obj`.
//
// Two separate Zig gotchas made this file necessary instead of just
// pointing the build at kernel/kernel.zig directly:
//
// 1. Module root: `zig build-obj` treats the directory of the given file
//    as the module root, and forbids @import paths that climb above it
//    with "../". kernel.zig needs ../gui, ../drivers, ../apps, ../arch,
//    ../lib - all siblings of kernel/, not descendants. Rooting one level
//    up at src/ fixes that.
//
// 2. Export reachability: boot.asm/interrupts.asm call kernel_main,
//    exception_handler, keyboard_handler, mouse_handler (and the Zig
//    compiler-builtins memset/memcpy/memmove) via `extern`. Those are
//    only guaranteed to make it into the final object if they're `pub`
//    and explicitly referenced from here - simply having kernel.zig
//    @import its drivers isn't reliably enough to pull cross-file
//    `export fn`s into a build-obj invocation that doesn't go through
//    them directly. So every export below is imported and referenced
//    by hand.

const kernel = @import("kernel/kernel.zig");
const keyboard = @import("drivers/keyboard.zig");
const mouse = @import("drivers/mouse.zig");
const pit = @import("drivers/pit.zig");
const memory = @import("kernel/memory.zig");
const device_manager = @import("apps/device_manager.zig");
const task_manager = @import("apps/task_manager.zig");
const tasks = @import("kernel/tasks.zig");
const mem = @import("lib/mem.zig");
const driver_registry = @import("drivers/driver_registry.zig");
const cpu = @import("drivers/cpu.zig");
const audio = @import("drivers/audio.zig");
const guest = @import("drivers/guest.zig");
const network = @import("drivers/network.zig");
const display = @import("drivers/display.zig");
const usb = @import("drivers/usb.zig");
const control_panel = @import("apps/control_panel.zig");
const scheduler = @import("kernel/scheduler.zig");
const syscall = @import("kernel/syscall.zig");

// Zig's freestanding panic mechanism looks specifically for a `pub fn
// panic` declared directly in the *root* module (via @import("root")).
pub const panic = kernel.panic;

comptime {
    _ = kernel.kernel_main;
    _ = kernel.exception_handler;
    _ = keyboard.keyboard_handler;
    _ = mouse.mouse_handler;
    _ = pit.timer_handler;
    _ = memory.stats;
    _ = device_manager.asApp;
    _ = task_manager.asApp;
    _ = tasks.countOpen;
    _ = mem.memset;
    _ = mem.memcpy;
    _ = mem.memmove;
    _ = driver_registry.refresh;
    _ = cpu.detect;
    _ = audio.beep;
    _ = guest.detect;
    _ = network.deviceName;
    _ = display.deviceName;
    _ = usb.scan;
    _ = control_panel.asApp;
    _ = scheduler.scheduler_tick;
    _ = syscall.syscall_dispatch;
}
