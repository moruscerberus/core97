// idt.zig - Interrupt Descriptor Table + PIC-omprogrammering
// Det här är "infrastrukturen" som krävs för att CPU:n ska kunna
// hantera avbrott från tangentbord och mus.

// --- Låg-nivå port I/O ---
// CPU:n pratar med hårdvara via "portar" (inte minnesadresser).
// Zig har inline-assembly för detta.

pub fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8)
        : [port] "{dx}" (port),
    );
}

// --- IDT-struct ---
// Varje entry beskriver var CPU:n ska hoppa när ett visst interrupt sker.
const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    zero: u8,
    type_attr: u8,
    offset_high: u16,
};

const IdtPointer = packed struct {
    limit: u16,
    base: u32,
};

var idt: [256]IdtEntry = undefined;
var idt_ptr: IdtPointer = undefined;

extern fn idt_load(ptr: *const IdtPointer) void;
extern fn keyboard_isr() void;
extern fn mouse_isr() void;
extern fn default_isr() void;

// CPU-exception-handlers (ISR 0-19), definierade i interrupts.asm
extern fn exception_isr_0() void;
extern fn exception_isr_1() void;
extern fn exception_isr_2() void;
extern fn exception_isr_3() void;
extern fn exception_isr_4() void;
extern fn exception_isr_5() void;
extern fn exception_isr_6() void;
extern fn exception_isr_7() void;
extern fn exception_isr_8() void;
extern fn exception_isr_9() void;
extern fn exception_isr_10() void;
extern fn exception_isr_11() void;
extern fn exception_isr_12() void;
extern fn exception_isr_13() void;
extern fn exception_isr_14() void;
extern fn exception_isr_15() void;
extern fn exception_isr_16() void;
extern fn exception_isr_17() void;
extern fn exception_isr_18() void;
extern fn exception_isr_19() void;

fn setIdtEntry(num: u8, handler: *const fn () callconv(.Naked) void) void {
    const addr: u32 = @intFromPtr(handler);
    idt[num] = IdtEntry{
        .offset_low = @truncate(addr),
        .selector = 0x08, // kernel code segment (vår egen GDT, se boot.asm)
        .zero = 0,
        .type_attr = 0x8E, // present, ring 0, 32-bit interrupt gate
        .offset_high = @truncate(addr >> 16),
    };
}

// Sätter ALLA 256 entries till en säker default-handler. Måste köras
// innan vi sätter de specifika handlerna, annars är oanvända entries
// fyllda med skräp (undefined) vilket orsakar en triple fault så fort
// ett oväntat interrupt (t.ex. spurious IRQ) inträffar.
fn setAllDefault() void {
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        setIdtEntry(@truncate(i), @ptrCast(&default_isr));
    }
}

// --- PIC-omprogrammering ---
// PIC:en (Programmable Interrupt Controller) skickar IRQ:er på interrupt
// 0-15 som standard, men det krockar med CPU:ns egna exceptions (0-31).
// Vi "remappar" PIC:en till 32-47 istället.

const PIC1_COMMAND = 0x20;
const PIC1_DATA = 0x21;
const PIC2_COMMAND = 0xA0;
const PIC2_DATA = 0xA1;

fn remapPic() void {
    // Initiera båda PIC:er i "cascade mode"
    outb(PIC1_COMMAND, 0x11);
    outb(PIC2_COMMAND, 0x11);

    // Sätt nya offset: PIC1 -> 32, PIC2 -> 40
    outb(PIC1_DATA, 32);
    outb(PIC2_DATA, 40);

    // Tala om för PIC:erna hur de är kopplade till varandra
    outb(PIC1_DATA, 4);
    outb(PIC2_DATA, 2);

    // 8086-läge
    outb(PIC1_DATA, 0x01);
    outb(PIC2_DATA, 0x01);

    // Avmaskera (aktivera) IRQ1 (tangentbord), IRQ2 (cascade till PIC2 -
    // KRÄVS för att musen ska fungera, annars kommer inga IRQ:er från
    // PIC2/slave fram alls) och IRQ12 (mus, på PIC2).
    // Mask-byte: 1 = avstängd, 0 = aktiv
    outb(PIC1_DATA, 0b11111001); // bit 1 (IRQ1) och bit 2 (cascade) aktiva
    outb(PIC2_DATA, 0b11101111); // bit 4 = IRQ12 (IRQ12 = PIC2 bit 4) aktiv
}

// Måste anropas i slutet av varje IRQ-handler så PIC:en vet att vi är klara
pub fn picSendEoi(irq: u8) void {
    if (irq >= 8) {
        outb(PIC2_COMMAND, 0x20);
    }
    outb(PIC1_COMMAND, 0x20);
}

pub fn init() void {
    idt_ptr = IdtPointer{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    // Fyll alla entries med en säker default-handler FÖRST
    setAllDefault();

    // Koppla in CPU-exception-handlers (0-19) - dessa fångar t.ex.
    // Invalid Opcode (6), General Protection Fault (13), Page Fault (14)
    // och ritar felet på skärmen istället för att trippelfaulta tyst.
    setIdtEntry(0, @ptrCast(&exception_isr_0));
    setIdtEntry(1, @ptrCast(&exception_isr_1));
    setIdtEntry(2, @ptrCast(&exception_isr_2));
    setIdtEntry(3, @ptrCast(&exception_isr_3));
    setIdtEntry(4, @ptrCast(&exception_isr_4));
    setIdtEntry(5, @ptrCast(&exception_isr_5));
    setIdtEntry(6, @ptrCast(&exception_isr_6));
    setIdtEntry(7, @ptrCast(&exception_isr_7));
    setIdtEntry(8, @ptrCast(&exception_isr_8));
    setIdtEntry(9, @ptrCast(&exception_isr_9));
    setIdtEntry(10, @ptrCast(&exception_isr_10));
    setIdtEntry(11, @ptrCast(&exception_isr_11));
    setIdtEntry(12, @ptrCast(&exception_isr_12));
    setIdtEntry(13, @ptrCast(&exception_isr_13));
    setIdtEntry(14, @ptrCast(&exception_isr_14));
    setIdtEntry(15, @ptrCast(&exception_isr_15));
    setIdtEntry(16, @ptrCast(&exception_isr_16));
    setIdtEntry(17, @ptrCast(&exception_isr_17));
    setIdtEntry(18, @ptrCast(&exception_isr_18));
    setIdtEntry(19, @ptrCast(&exception_isr_19));

    setIdtEntry(33, @ptrCast(&keyboard_isr)); // IRQ1 -> interrupt 32+1
    setIdtEntry(44, @ptrCast(&mouse_isr)); // IRQ12 -> interrupt 32+12

    idt_load(&idt_ptr);
    remapPic();

    // OBS: interrupts aktiveras INTE här. PS/2-mus-handskakningen i
    // mouse.init() måste köras med interrupts avstängda för att inte
    // störas av IRQ:er mitt i sekvensen. mouse.init() gör "sti" själv
    // när den är klar.
}

