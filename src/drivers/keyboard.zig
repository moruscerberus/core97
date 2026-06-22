// keyboard.zig - PS/2 keyboard driver with scancode events
// Sends both old ASCII callbacks and full key events for editor shortcuts.

const idt = @import("../arch/x86/idt.zig");
const input = @import("input.zig");

const KEYBOARD_DATA_PORT: u16 = 0x60;

pub const KeyEvent = struct {
    // USB HID-style key code. This lets kernel.zig reuse the USB keyboard logic.
    code: u8,
    ascii: u8,
    pressed: bool,
    modifiers: u8, // USB modifier bits: ctrl=0x11, shift=0x22, alt=0x44, gui=0x88
};

var on_key_press: ?*const fn (u8) void = null;
var on_key_event: ?*const fn (KeyEvent) void = null;

var left_shift: bool = false;
var right_shift: bool = false;
var left_ctrl: bool = false;
var right_ctrl: bool = false;
var left_alt: bool = false;
var right_alt: bool = false;
var left_gui: bool = false;
var right_gui: bool = false;
var extended: bool = false;

pub fn setKeyHandler(handler: *const fn (u8) void) void {
    on_key_press = handler;
}

pub fn setEventHandler(handler: *const fn (KeyEvent) void) void {
    on_key_event = handler;
}

fn modifiers() u8 {
    var m: u8 = 0;
    if (left_ctrl) m |= 0x01;
    if (left_shift) m |= 0x02;
    if (left_alt) m |= 0x04;
    if (left_gui) m |= 0x08;
    if (right_ctrl) m |= 0x10;
    if (right_shift) m |= 0x20;
    if (right_alt) m |= 0x40;
    if (right_gui) m |= 0x80;
    return m;
}

fn scancodeToUsb(sc: u8, e0: bool) u8 {
    if (e0) {
        return switch (sc) {
            0x1D => 0,    // right ctrl modifier
            0x38 => 0,    // right alt modifier
            0x5B => 0xE3, // left Windows / GUI
            0x5C => 0xE7, // right Windows / GUI
            0x4B => 0x50, // left arrow
            0x4D => 0x4F, // right arrow
            0x48 => 0x52, // up arrow
            0x50 => 0x51, // down arrow
            0x47 => 0x4A, // home
            0x4F => 0x4D, // end
            0x53 => 0x4C, // delete
            else => 0,
        };
    }

    return switch (sc) {
        0x01 => 0x29, // escape
        0x02 => 0x1E, 0x03 => 0x1F, 0x04 => 0x20, 0x05 => 0x21,
        0x06 => 0x22, 0x07 => 0x23, 0x08 => 0x24, 0x09 => 0x25,
        0x0A => 0x26, 0x0B => 0x27,
        0x0C => 0x2D, // -
        0x0D => 0x2E, // =
        0x0E => 0x2A, // backspace
        0x0F => 0x2B, // tab
        0x10 => 0x14, // q
        0x11 => 0x1A, // w
        0x12 => 0x08, // e
        0x13 => 0x15, // r
        0x14 => 0x17, // t
        0x15 => 0x1C, // y
        0x16 => 0x18, // u
        0x17 => 0x0C, // i
        0x18 => 0x12, // o
        0x19 => 0x13, // p
        0x1A => 0x2F, // Swedish å key position
        0x1B => 0x30, // ] key position
        0x1C => 0x28, // enter
        0x1D => 0,    // left ctrl modifier
        0x1E => 0x04, // a
        0x1F => 0x16, // s
        0x20 => 0x07, // d
        0x21 => 0x09, // f
        0x22 => 0x0A, // g
        0x23 => 0x0B, // h
        0x24 => 0x0D, // j
        0x25 => 0x0E, // k
        0x26 => 0x0F, // l
        0x27 => 0x33, // Swedish ö key position
        0x28 => 0x34, // Swedish ä key position
        0x29 => 0x35, // `
        0x2A => 0,    // left shift modifier
        0x2B => 0x31, // backslash
        0x2C => 0x1D, // z
        0x2D => 0x1B, // x
        0x2E => 0x06, // c
        0x2F => 0x19, // v
        0x30 => 0x05, // b
        0x31 => 0x11, // n
        0x32 => 0x10, // m
        0x33 => 0x36, // comma
        0x34 => 0x37, // dot
        0x35 => 0x38, // slash
        0x36 => 0,    // right shift modifier
        0x38 => 0,    // left alt modifier
        0x39 => 0x2C, // space
        0x3B => 0x3A, // F1
        0x3C => 0x3B, // F2
        0x3D => 0x3C, // F3
        0x3E => 0x3D, // F4
        0x3F => 0x3E, // F5
        0x40 => 0x3F, // F6
        0x41 => 0x40, // F7
        0x42 => 0x41, // F8
        0x43 => 0x42, // F9
        0x44 => 0x43, // F10
        0x57 => 0x44, // F11
        0x58 => 0x45, // F12
        0x56 => 0x64, // 102nd key: <> on Swedish, non-US \| on US/ISO
        0x47 => 0x4A, // num home when numlock off-ish
        0x4B => 0x50, // num left
        0x4D => 0x4F, // num right
        0x4F => 0x4D, // num end
        0x48 => 0x52, // num up
        0x50 => 0x51, // num down
        0x53 => 0x4C, // num delete
        else => 0,
    };
}

fn updateModifier(sc: u8, e0: bool, pressed: bool) bool {
    if (e0) {
        switch (sc) {
            0x1D => { right_ctrl = pressed; return true; },
            0x38 => { right_alt = pressed; return true; },
            0x5B => { left_gui = pressed; return true; },
            0x5C => { right_gui = pressed; return true; },
            else => return false,
        }
    }

    switch (sc) {
        0x1D => { left_ctrl = pressed; return true; },
        0x2A => { left_shift = pressed; return true; },
        0x36 => { right_shift = pressed; return true; },
        0x38 => { left_alt = pressed; return true; },
        else => return false,
    }
}

/// Set directly from the IRQ handler below, independent of whatever
/// on_key_event callback is currently registered (i.e. independent of
/// window focus). This lets long-running blocking operations elsewhere in
/// the kernel - currently network.zig's DNS/TCP waits - poll for "the user
/// wants out" even though this kernel has no preemptive multitasking to
/// interrupt them otherwise. Consumers are expected to clear it after
/// observing a press.
pub var escape_pressed: bool = false;

pub export fn keyboard_handler() callconv(.C) void {
    input.notePs2Keyboard();
    const raw = idt.inb(KEYBOARD_DATA_PORT);

    if (raw == 0xE0) {
        extended = true;
        idt.picSendEoi(1);
        return;
    }

    const released = (raw & 0x80) != 0;
    const sc: u8 = raw & 0x7F;
    const e0 = extended;
    extended = false;

    if (sc == 0x01 and !released and !e0) escape_pressed = true;

    _ = updateModifier(sc, e0, !released);

    const code = scancodeToUsb(sc, e0);
    const ev = KeyEvent{
        .code = code,
        .ascii = 0,
        .pressed = !released,
        .modifiers = modifiers(),
    };

    if (on_key_event) |handler| {
        if (code != 0 or sc == 0x1D or sc == 0x2A or sc == 0x36 or sc == 0x38 or sc == 0x5B or sc == 0x5C) {
            handler(ev);
        }
    }

    // Old ASCII callback for compatibility. New editor code uses KeyEvent.
    if (!released and on_key_event == null and code != 0) {
        // Minimal fallback only; kernel should use event handler for real input.
        const ascii: u8 = switch (code) {
            0x04 => 'a', 0x05 => 'b', 0x06 => 'c', 0x07 => 'd',
            0x08 => 'e', 0x09 => 'f', 0x0A => 'g', 0x0B => 'h',
            0x0C => 'i', 0x0D => 'j', 0x0E => 'k', 0x0F => 'l',
            0x10 => 'm', 0x11 => 'n', 0x12 => 'o', 0x13 => 'p',
            0x14 => 'q', 0x15 => 'r', 0x16 => 's', 0x17 => 't',
            0x18 => 'u', 0x19 => 'v', 0x1A => 'w', 0x1B => 'x',
            0x1C => 'y', 0x1D => 'z', 0x2C => ' ', 0x28 => 13,
            0x2A => 8,
            else => 0,
        };
        if (ascii != 0) if (on_key_press) |handler| handler(ascii);
    }

    idt.picSendEoi(1);
}
