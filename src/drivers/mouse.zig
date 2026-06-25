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
const pit = @import("pit.zig");

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
pub var screen_width: i32 = 1280;
pub var screen_height: i32 = 800;

var packet: [3]u8 = .{ 0, 0, 0 };
var packet_index: u8 = 0;

// --- Double-click detection ---
// There was no concept of this anywhere in the kernel before - every
// click was just "a press happened", with no way to tell a deliberate
// double-click from two unrelated single clicks. This tracks presses
// (rising edges of left_button) and flags one as a double-click if it
// lands within both a time window and a small distance of the previous
// one - the same two-part test every real desktop environment uses, so
// a slow click-drag-click doesn't false-positive just because it was
// quick, and a fast double-tap that drifted a few pixels still counts.
const DOUBLE_CLICK_MAX_TICKS: u32 = 40; // ~400ms at the 100Hz PIT rate kernel.zig configures
const DOUBLE_CLICK_MAX_DIST: i32 = 6; // pixels of allowed wobble between the two clicks

var prev_left_button: bool = false;
var last_click_tick: u32 = 0;
var last_click_x: i32 = -1000;
var last_click_y: i32 = -1000;
var pending_double_click: bool = false;

fn updateClickTracking() void {
    if (left_button and !prev_left_button) {
        const dt = pit.ticks -% last_click_tick;
        const dx_click = mouse_x - last_click_x;
        const dy_click = mouse_y - last_click_y;
        const dist_sq = dx_click * dx_click + dy_click * dy_click;
        if (dt <= DOUBLE_CLICK_MAX_TICKS and dist_sq <= DOUBLE_CLICK_MAX_DIST * DOUBLE_CLICK_MAX_DIST) {
            pending_double_click = true;
            // Reset the click history after a successful pair, so a
            // THIRD quick click doesn't also chain into a second
            // "double-click" against the previous pair's second click.
            last_click_tick = 0;
            last_click_x = -1000;
            last_click_y = -1000;
        } else {
            last_click_tick = pit.ticks;
            last_click_x = mouse_x;
            last_click_y = mouse_y;
        }
    }
    prev_left_button = left_button;
}

/// True at most once per actual double-click, then clears itself -
/// callers check this once when handling a fresh press (the same
/// moment they'd otherwise treat it as an ordinary single click) to
/// decide whether to "open" instead of just "select".
pub fn consumeDoubleClick() bool {
    if (!pending_double_click) return false;
    pending_double_click = false;
    return true;
}

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
        updateClickTracking();
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
