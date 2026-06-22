// mouse.zig - PS/2 mouse driver
// The mouse talks over the same PS/2 controller as the keyboard, but on a
// different "channel". We have to send commands to enable it before it
// starts sending movement data.
//
// Each mouse report is 3 bytes:
//   byte 0: button status + sign bits for x/y
//   byte 1: x movement (relative, can be negative)
//   byte 2: y movement (relative, can be negative, inverted direction)

const idt = @import("../arch/x86/idt.zig");
const input = @import("input.zig");

const PS2_DATA_PORT: u16 = 0x60;
const PS2_STATUS_PORT: u16 = 0x64;
const PS2_COMMAND_PORT: u16 = 0x64;

fn waitInputBufferEmpty() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (idt.inb(PS2_STATUS_PORT) & 0x02 == 0) return;
    }
}

fn waitOutputBufferFull() void {
    var timeout: u32 = 100000;
    while (timeout > 0) : (timeout -= 1) {
        if (idt.inb(PS2_STATUS_PORT) & 0x01 != 0) return;
    }
}

fn writeCommand(cmd: u8) void {
    waitInputBufferEmpty();
    idt.outb(PS2_COMMAND_PORT, cmd);
}

fn writeData(data: u8) void {
    waitInputBufferEmpty();
    idt.outb(PS2_DATA_PORT, data);
}

fn readData() u8 {
    waitOutputBufferFull();
    return idt.inb(PS2_DATA_PORT);
}

pub fn init(checkpoint: ?*const fn (u32) void) void {
    if (checkpoint) |cp| cp(1);

    // Disable interrupts for the entire handshake - otherwise an
    // IRQ (e.g. keyboard) could disrupt the read/write sequence to the PS/2 port.
    asm volatile ("cli");

    if (checkpoint) |cp| cp(2);

    // Enable the "second PS/2 port" (the mouse usually lives there)
    writeCommand(0xA8);

    if (checkpoint) |cp| cp(3);

    // Turn on interrupts for the mouse in the PS/2 controller config
    writeCommand(0x20); // read config byte
    if (checkpoint) |cp| cp(4);
    var status = readData();
    if (checkpoint) |cp| cp(5);
    status |= 0b10; // bit 1 = enable IRQ12 for mouse
    writeCommand(0x60); // write config byte
    writeData(status);

    if (checkpoint) |cp| cp(6);

    // Put the mouse in "default" mode and enable data streaming
    writeCommand(0xD4); // next byte goes to the mouse, not the keyboard
    writeData(0xF6); // "set defaults"
    if (checkpoint) |cp| cp(7);
    _ = readData(); // ACK
    if (checkpoint) |cp| cp(8);

    writeCommand(0xD4);
    writeData(0xF4); // "enable data reporting"
    if (checkpoint) |cp| cp(9);
    _ = readData(); // ACK
    if (checkpoint) |cp| cp(10);

    // Handshake done - safe to turn interrupts back on
    asm volatile ("sti");
}

// Mouse state — position is clamped by screen size (set from kernel.zig)
pub var mouse_x: i32 = 400;
pub var mouse_y: i32 = 300;
pub var left_button: bool = false;
pub var right_button: bool = false;
pub var screen_width: i32 = 1024;
pub var screen_height: i32 = 768;

var packet: [3]u8 = .{ 0, 0, 0 };
var packet_index: u8 = 0;

var on_mouse_update: ?*const fn () void = null;

pub fn setMouseHandler(handler: *const fn () void) void {
    on_mouse_update = handler;
}

pub export fn mouse_handler() callconv(.C) void {
    input.notePs2Mouse();
    const data = idt.inb(PS2_DATA_PORT);

    // Sync check: byte 0 of a PS/2 mouse packet ALWAYS has bit 3 set
    // to 1 (it's a built-in protocol marker). If we're expecting byte 0
    // but that bit is missing, we're out of sync - drop the byte and wait for the next one.
    if (packet_index == 0) {
        if (data & 0x08 == 0) {
            idt.picSendEoi(12);
            return;
        }
        // Overflow bits (6/7) set means the packet is garbage - skip it
        if (data & 0xC0 != 0) {
            idt.picSendEoi(12);
            return;
        }
    }

    packet[packet_index] = data;
    packet_index += 1;

    if (packet_index == 3) {
        packet_index = 0;

        const flags = packet[0];
        left_button = (flags & 0x01) != 0;
        right_button = (flags & 0x02) != 0;
        // x/y are 9-bit signed values: bit 4/5 in flags is the sign bit
        var dx: i32 = @as(i32, packet[1]);
        var dy: i32 = @as(i32, packet[2]);

        if (flags & 0x10 != 0) dx -= 256; // negative x
        if (flags & 0x20 != 0) dy -= 256; // negative y

        mouse_x += dx;
        mouse_y -= dy; // PS/2 has y inverted relative to screen coordinates

        // Clamp to the screen bounds
        if (mouse_x < 0) mouse_x = 0;
        if (mouse_y < 0) mouse_y = 0;
        if (mouse_x >= screen_width) mouse_x = screen_width - 1;
        if (mouse_y >= screen_height) mouse_y = screen_height - 1;

        if (on_mouse_update) |handler| {
            handler();
        }
    }

    idt.picSendEoi(12);
}
