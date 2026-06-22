// apps/keymap.zig - USB-HID keycode to character translation.
//
// Keeps layout-specific symbol tables out of the editor core so Notepad can
// later be reused by a code editor without carrying keyboard-driver logic.

const fb = @import("../gui/framebuffer.zig");

pub const KeyboardLayout = enum { us, sv };

fn keycodeToAsciiUS(code: u8, shift: bool, altgr: bool) u8 {
    _ = altgr;
    return switch (code) {
        0x04...0x1D => if (shift) code - 0x04 + 'A' else code - 0x04 + 'a',
        0x1E => if (shift) '!' else '1',
        0x1F => if (shift) '@' else '2',
        0x20 => if (shift) '#' else '3',
        0x21 => if (shift) '$' else '4',
        0x22 => if (shift) '%' else '5',
        0x23 => if (shift) '^' else '6',
        0x24 => if (shift) '&' else '7',
        0x25 => if (shift) '*' else '8',
        0x26 => if (shift) '(' else '9',
        0x27 => if (shift) ')' else '0',
        0x2C => ' ',
        0x2D => if (shift) '_' else '-',
        0x2E => if (shift) '+' else '=',
        0x2F => if (shift) '{' else '[',
        0x30 => if (shift) '}' else ']',
        0x31 => if (shift) '|' else '\\',
        0x33 => if (shift) ':' else ';',
        0x34 => if (shift) '"' else '\'',
        0x35 => if (shift) '~' else '`',
        0x36 => if (shift) '<' else ',',
        0x37 => if (shift) '>' else '.',
        0x38 => if (shift) '?' else '/',
        0x64 => if (shift) '|' else '\\',
        else => 0,
    };
}

fn keycodeToAsciiSV(code: u8, shift: bool, altgr: bool) u8 {
    if (code >= 0x04 and code <= 0x1D) {
        return if (shift) code - 0x04 + 'A' else code - 0x04 + 'a';
    }

    if (altgr) {
        return switch (code) {
            0x1F => '@',
            0x20 => '#',
            0x21 => '$',
            0x24 => '{',
            0x25 => '[',
            0x26 => ']',
            0x27 => '}',
            0x2D => '\\',
            0x64 => '|',
            else => 0,
        };
    }

    return switch (code) {
        0x1E => if (shift) '!' else '1',
        0x1F => if (shift) '"' else '2',
        0x20 => if (shift) '#' else '3',
        0x21 => if (shift) 0 else '4',
        0x22 => if (shift) '%' else '5',
        0x23 => if (shift) '&' else '6',
        0x24 => if (shift) '/' else '7',
        0x25 => if (shift) '(' else '8',
        0x26 => if (shift) ')' else '9',
        0x27 => if (shift) '=' else '0',
        0x2C => ' ',
        0x2D => if (shift) '?' else '+',
        0x2E => if (shift) '`' else 0,
        0x2F => if (shift) fb.CH_A_RING_UPPER else fb.CH_A_RING_LOWER, // Å / å
        0x30 => if (shift) '^' else 0,
        0x31 => if (shift) '*' else '\'',
        0x33 => if (shift) fb.CH_O_UML_UPPER else fb.CH_O_UML_LOWER, // Ö / ö
        0x34 => if (shift) fb.CH_A_UML_UPPER else fb.CH_A_UML_LOWER, // Ä / ä
        0x35 => if (shift) 0 else 0,
        0x36 => if (shift) ';' else ',',
        0x37 => if (shift) ':' else '.',
        0x38 => if (shift) '_' else '-',
        0x64 => if (shift) '>' else '<',
        else => 0,
    };
}

pub fn keycodeToAscii(code: u8, modifiers: u8, layout: KeyboardLayout) u8 {
    const shift = (modifiers & 0x22) != 0;
    const altgr = (modifiers & 0x40) != 0 or ((modifiers & 0x44) == 0x44);
    return switch (layout) {
        .us => keycodeToAsciiUS(code, shift, altgr),
        .sv => keycodeToAsciiSV(code, shift, altgr),
    };
}

