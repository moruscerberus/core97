// arch/x86_64/serial.zig - bare COM1 (16450/8250 UART) debug output.
//
// Deliberately independent of everything Limine-related: this only
// touches hardware I/O ports that exist on essentially every x86 board
// and every QEMU machine type, so it works even if a Limine request
// failed, the framebuffer never came up, or something faulted before
// gui code could run. Pair with `qemu-system-x86_64 -serial stdio` to
// see these on your terminal. This is the main debugging tool available
// for this port, since there's no way to single-step or print to a
// screen we can't yet prove is working.

const idt = @import("idt.zig");

const COM1: u16 = 0x3F8;

pub fn init() void {
    idt.outb(COM1 + 1, 0x00); // disable interrupts
    idt.outb(COM1 + 3, 0x80); // enable DLAB (set baud rate divisor)
    idt.outb(COM1 + 0, 0x03); // divisor low byte (3 -> 38400 baud)
    idt.outb(COM1 + 1, 0x00); // divisor high byte
    idt.outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    idt.outb(COM1 + 2, 0xC7); // enable FIFO, clear, 14-byte threshold
    idt.outb(COM1 + 4, 0x0B); // IRQs disabled, RTS/DSR set
}

fn isTransmitEmpty() bool {
    return (idt.inb(COM1 + 5) & 0x20) != 0;
}

pub fn writeByte(c: u8) void {
    while (!isTransmitEmpty()) {}
    idt.outb(COM1, c);
}

pub fn writeString(s: []const u8) void {
    for (s) |c| writeByte(c);
}

pub fn writeLine(s: []const u8) void {
    writeString(s);
    writeByte('\r');
    writeByte('\n');
}

fn hexDigit(nibble: u4) u8 {
    return if (nibble < 10) '0' + @as(u8, nibble) else 'A' + @as(u8, nibble - 10);
}

/// Writes a value as "0x" + 16 hex digits. Handy for pointers/addresses
/// without needing std.fmt on a freestanding target.
pub fn writeHex64(value: u64) void {
    writeString("0x");
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const nibble: u4 = @truncate(value >> shift);
        writeByte(hexDigit(nibble));
    }
}
