// keyboard.zig - PS/2-tangentbordsdrivrutin
// Tangentbordet skickar "scancodes" (inte ASCII) via port 0x60 när en
// tangent trycks ner eller släpps. Vi översätter scancode -> ASCII med
// en enkel uppslagstabell (US QWERTY-layout, bara grundläggande tangenter).

const idt = @import("idt.zig");

const KEYBOARD_DATA_PORT: u16 = 0x60;

// Scancode set 1 (US QWERTY). Index = scancode, värde = ASCII-tecken.
// 0 betyder "ingen ASCII-mappning" (t.ex. Shift, Ctrl, pilknappar).
const scancode_to_ascii = [_]u8{
    0,    27,   '1',  '2',  '3',  '4',  '5',  '6', // 0x00-0x07
    '7',  '8',  '9',  '0',  '-',  '=',  8,    9, // 0x08-0x0F (8=backspace, 9=tab)
    'q',  'w',  'e',  'r',  't',  'y',  'u',  'i', // 0x10-0x17
    'o',  'p',  '[',  ']',  13,   0,    'a',  's', // 0x18-0x1F (13=enter, 0=ctrl)
    'd',  'f',  'g',  'h',  'j',  'k',  'l',  ';', // 0x20-0x27
    '\'', '`',  0,    '\\', 'z',  'x',  'c',  'v', // 0x28-0x2F (0=left shift)
    'b',  'n',  'm',  ',',  '.',  '/',  0,    '*', // 0x30-0x37 (0=right shift)
    0,    ' ',  0,    0,    0,    0,    0,    0, // 0x38-0x3F (alt, space, capslock, F1-F5)
};

// Callback som main-kerneln sätter, så vi kan skicka vidare tecken
var on_key_press: ?*const fn (u8) void = null;

pub fn setKeyHandler(handler: *const fn (u8) void) void {
    on_key_press = handler;
}

export fn keyboard_handler() callconv(.C) void {
    const scancode = idt.inb(KEYBOARD_DATA_PORT);

    // Bit 7 satt = tangenten släpptes (key release), vi ignorerar det än
    if (scancode & 0x80 == 0) {
        if (scancode < scancode_to_ascii.len) {
            const ascii = scancode_to_ascii[scancode];
            if (ascii != 0) {
                if (on_key_press) |handler| {
                    handler(ascii);
                }
            }
        }
    }

    idt.picSendEoi(1);
}
