// drivers/pit64.zig - Programmable Interval Timer, x86_64 build.
// Identical in spirit to drivers/pit.zig (the PIT hardware doesn't care
// what mode the CPU is in) - duplicated rather than shared because it
// imports the x86_64 idt module specifically. See arch/x86_64/idt.zig's
// header comment for why this project doesn't thread one shared driver
// file across both architectures.

const idt = @import("../arch/x86_64/idt.zig");

const PIT_CHANNEL0: u16 = 0x40;
const PIT_COMMAND: u16 = 0x43;
const PIT_BASE_FREQUENCY: u32 = 1193182; // Hz - fixed PIT input clock

pub var ticks: u32 = 0;

pub fn init(frequency_hz: u32) void {
    const divisor: u32 = PIT_BASE_FREQUENCY / frequency_hz;

    idt.outb(PIT_COMMAND, 0x36); // channel 0, lobyte/hibyte, mode 3, binary
    idt.outb(PIT_CHANNEL0, @truncate(divisor & 0xFF));
    idt.outb(PIT_CHANNEL0, @truncate((divisor >> 8) & 0xFF));
}

pub export fn timer_handler() callconv(.C) void {
    ticks +%= 1;
    idt.picSendEoi(0);
}
