// mouse.zig - PS/2-musdrivrutin
// Musen pratar via samma PS/2-controller som tangentbordet, men på en
// annan "kanal". Vi måste skicka kommandon för att aktivera den innan
// den börjar skicka rörelsedata.
//
// Varje musrapport är 3 bytes:
//   byte 0: knappstatus + tecken-bitar för x/y
//   byte 1: x-rörelse (relativ, kan vara negativ)
//   byte 2: y-rörelse (relativ, kan vara negativ, omvänd riktning)

const idt = @import("idt.zig");

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

    // Stäng av interrupts under hela handskakningen - annars kan ett
    // IRQ (t.ex. tangentbord) störa läs/skriv-sekvensen mot PS/2-porten.
    asm volatile ("cli");

    if (checkpoint) |cp| cp(2);

    // Aktivera "andra PS/2-porten" (musen sitter oftast där)
    writeCommand(0xA8);

    if (checkpoint) |cp| cp(3);

    // Slå på interrupts för mus i PS/2-controllerns konfiguration
    writeCommand(0x20); // läs config-byte
    if (checkpoint) |cp| cp(4);
    var status = readData();
    if (checkpoint) |cp| cp(5);
    status |= 0b10; // bit 1 = aktivera IRQ12 för mus
    writeCommand(0x60); // skriv config-byte
    writeData(status);

    if (checkpoint) |cp| cp(6);

    // Sätt musen i "default" läge och aktivera dataströmning
    writeCommand(0xD4); // nästa byte går till musen, inte tangentbordet
    writeData(0xF6); // "set defaults"
    if (checkpoint) |cp| cp(7);
    _ = readData(); // ACK
    if (checkpoint) |cp| cp(8);

    writeCommand(0xD4);
    writeData(0xF4); // "enable data reporting"
    if (checkpoint) |cp| cp(9);
    _ = readData(); // ACK
    if (checkpoint) |cp| cp(10);

    // Handskakningen klar - säkert att slå på interrupts igen
    asm volatile ("sti");
}

// Musens state — position begränsas av skärmstorleken (sätts från kernel.zig)
pub var mouse_x: i32 = 400;
pub var mouse_y: i32 = 300;
pub var left_button: bool = false;
pub var screen_width: i32 = 1024;
pub var screen_height: i32 = 768;

var packet: [3]u8 = .{ 0, 0, 0 };
var packet_index: u8 = 0;

var on_mouse_update: ?*const fn () void = null;

pub fn setMouseHandler(handler: *const fn () void) void {
    on_mouse_update = handler;
}

export fn mouse_handler() callconv(.C) void {
    const data = idt.inb(PS2_DATA_PORT);

    // Synk-kontroll: byte 0 i ett PS/2-musspaket har ALLTID bit 3 satt
    // till 1 (det är en inbyggd protokoll-markör). Om vi väntar på byte 0
    // men den biten saknas, är vi ur synk - kasta byten och vänta på nästa.
    if (packet_index == 0) {
        if (data & 0x08 == 0) {
            idt.picSendEoi(12);
            return;
        }
        // Overflow-bitar (6/7) satta betyder paketet är skräp - hoppa över
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

        // x/y är 9-bit signed värden: bit 4/5 i flags är teckenbiten
        var dx: i32 = @as(i32, packet[1]);
        var dy: i32 = @as(i32, packet[2]);

        if (flags & 0x10 != 0) dx -= 256; // negativ x
        if (flags & 0x20 != 0) dy -= 256; // negativ y

        mouse_x += dx;
        mouse_y -= dy; // PS/2 har y inverterad jämfört med skärmkoordinater

        // Klampa till skärmens gränser
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
