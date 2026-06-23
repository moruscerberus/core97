// main64.zig - the file passed to `zig build-obj` for the x86_64 build.
//
// Same two reasons this exists as main.zig has for the 32-bit build:
// rooting the module at src/ so "../" imports from kernel64.zig don't
// escape the module path, and force-referencing every cross-file
// `export fn` so it's guaranteed to survive into the final object
// regardless of whether anything else happens to reference it.
//
// _start itself needs no such forcing - it's reached directly as the
// ELF entry point, not via extern/asm lookup - but exception_handler,
// timer_handler, and keyboard_handler are all called only from asm via
// `extern`, so the same "is this file actually part of the compiled
// graph" question applies to them as it did on the 32-bit side.

const kernel = @import("kernel/kernel64.zig");
const pit = @import("drivers/pit64.zig");
const keyboard = @import("drivers/keyboard64.zig");
const mem = @import("lib/mem.zig");

pub const panic = kernel.panic;

comptime {
    _ = kernel._start;
    _ = kernel.exception_handler;
    _ = pit.timer_handler;
    _ = keyboard.keyboard_handler;
    _ = mem.memset;
    _ = mem.memcpy;
    _ = mem.memmove;
}
