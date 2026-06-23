// drivers/keyboard64.zig - minimal PS/2 keyboard IRQ handler, x86_64 build.
//
// Deliberately minimal for this first x86_64 pass: it proves IRQ1 is
// wired correctly end-to-end (PIC unmasked -> IDT gate -> ISR -> here)
// by reading the scancode and keeping the last one around, without yet
// pulling in the full scancode-to-USB-keycode table, modifier tracking,
// or GUI dispatch that drivers/keyboard.zig has for the 32-bit kernel.
// That richer behavior can come once gui/apps gets ported to this arch -
// see docs/roadmap.md Phase 3.

const idt = @import("../arch/x86_64/idt.zig");

const KEYBOARD_DATA_PORT: u16 = 0x60;

pub var last_scancode: u8 = 0;
pub var key_event_count: u32 = 0;

pub export fn keyboard_handler() callconv(.C) void {
    last_scancode = idt.inb(KEYBOARD_DATA_PORT);
    key_event_count +%= 1;
    idt.picSendEoi(1);
}
