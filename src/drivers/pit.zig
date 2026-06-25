// drivers/pit.zig - Programmable Interval Timer (legacy 8253/8254, IRQ0).
//
// Until now this kernel had no real time base at all - every delay
// (tinyDelay in kernel.zig) is a bare `nop` busy-loop, which is wildly
// inaccurate across different CPU speeds and burns 100% of a core for no
// reason. This gives the kernel an actual hardware heartbeat. Nothing
// consumes `ticks` yet beyond exposing it for future use (a real taskbar
// clock, timeouts, scheduling in Phase 4/5) - but having the IRQ wired up
// and counting is the foundation those need.

const idt = @import("../arch/x86/idt.zig");
const audio = @import("audio.zig");

const PIT_CHANNEL0: u16 = 0x40;
const PIT_COMMAND: u16 = 0x43;
const PIT_BASE_FREQUENCY: u32 = 1193182; // Hz - fixed PIT input clock

/// Free-running tick counter, incremented once per IRQ0. Wraps silently
/// on overflow (+%=) since it's just a heartbeat, not something that
/// should ever crash the kernel.
pub var ticks: u32 = 0;

/// Programs PIT channel 0 for periodic IRQ0 at approximately
/// `frequency_hz`. Call once during boot, after idt.init() and before
/// interrupts are enabled (mouse.init() does the `sti`).
pub fn init(frequency_hz: u32) void {
    const divisor: u32 = PIT_BASE_FREQUENCY / frequency_hz;

    // 0x36 = channel 0, lobyte/hibyte access, mode 3 (square wave), binary
    idt.outb(PIT_COMMAND, 0x36);
    idt.outb(PIT_CHANNEL0, @truncate(divisor & 0xFF));
    idt.outb(PIT_CHANNEL0, @truncate((divisor >> 8) & 0xFF));
}

pub export fn timer_handler() callconv(.C) void {
    ticks +%= 1;
    audio.onTimerTick();
    idt.picSendEoi(0);
}
