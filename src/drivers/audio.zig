// drivers/audio.zig - minimal PC speaker audio driver stub.

const idt = @import("../arch/x86/idt.zig");

pub var present: bool = true;
pub var enabled: bool = false;

pub fn detect() void { present = true; }

pub fn beep() void {
    // Short PC speaker chirp using PIT channel 2. This is deliberately tiny:
    // useful for proving the audio path exists, not a real mixer yet.
    const divisor: u16 = 1193180 / 880;
    idt.outb(0x43, 0xB6);
    idt.outb(0x42, @truncate(divisor & 0xFF));
    idt.outb(0x42, @truncate(divisor >> 8));
    const tmp = idt.inb(0x61);
    idt.outb(0x61, tmp | 0x03);
    enabled = true;
}

pub fn silence() void {
    const tmp = idt.inb(0x61) & 0xFC;
    idt.outb(0x61, tmp);
    enabled = false;
}
