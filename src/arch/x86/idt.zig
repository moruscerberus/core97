// idt.zig - Interrupt Descriptor Table + PIC reprogramming
// This is the "infrastructure" required for the CPU to be able
// to handle interrupts from the keyboard and mouse.

// --- Low-level port I/O ---
// The CPU talks to hardware via "ports" (not memory addresses).
// Zig has inline assembly for this.

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

// 32-bit variants - required for the PCI configuration space, which is
// always read/written in 32-bit dwords even if we only want a byte/word.
pub fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32)
        : [port] "{dx}" (port),
    );
}

// 16-bit variant - used by UHCI's I/O registers, which are 16 bits wide
pub fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16)
        : [port] "{dx}" (port),
    );
}

// CR2 holds the faulting linear address after a page fault (#14). Only
// meaningful to read immediately when handling that specific exception -
// it's overwritten the instant another page fault happens.
pub fn readCr2() u32 {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "={eax}" (-> u32),
    );
}

// --- IDT struct ---
// Each entry describes where the CPU should jump when a given interrupt occurs.
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
extern fn timer_isr() void;
extern fn default_isr() void;

// Loads a zero-limit IDT and immediately triggers a software interrupt.
// With nowhere valid to vector to, the CPU treats this as unrecoverable
// and resets itself - used by kernel/power.zig as a fallback reboot path
// if the 8042 keyboard-controller reset pulse doesn't work.
pub fn forceTripleFault() noreturn {
    const broken_ptr = IdtPointer{ .limit = 0, .base = 0 };
    idt_load(&broken_ptr);
    asm volatile ("int $0x03");
    while (true) {
        asm volatile ("hlt");
    }
}

// CPU exception handlers (ISR 0-19), defined in interrupts.asm
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
        .selector = 0x08, // kernel code segment (our own GDT, see boot.asm)
        .zero = 0,
        .type_attr = 0x8E, // present, ring 0, 32-bit interrupt gate
        .offset_high = @truncate(addr >> 16),
    };
}

// Sets ALL 256 entries to a safe default handler. Must run before
// the specific handlers are set, otherwise unused entries are filled
// with garbage (undefined), which causes a triple fault as soon as
// an unexpected interrupt (e.g. a spurious IRQ) occurs.
fn setAllDefault() void {
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        setIdtEntry(@truncate(i), @ptrCast(&default_isr));
    }
}

// --- PIC reprogramming ---
// The PIC (Programmable Interrupt Controller) sends IRQs on interrupts
// 0-15 by default, but that clashes with the CPU's own exceptions (0-31).
// We "remap" the PIC to 32-47 instead.

const PIC1_COMMAND = 0x20;
const PIC1_DATA = 0x21;
const PIC2_COMMAND = 0xA0;
const PIC2_DATA = 0xA1;

fn remapPic() void {
    // Initialize both PICs in "cascade mode"
    outb(PIC1_COMMAND, 0x11);
    outb(PIC2_COMMAND, 0x11);

    // Set new offsets: PIC1 -> 32, PIC2 -> 40
    outb(PIC1_DATA, 32);
    outb(PIC2_DATA, 40);

    // Tell the PICs how they are wired to each other
    outb(PIC1_DATA, 4);
    outb(PIC2_DATA, 2);

    // 8086 mode
    outb(PIC1_DATA, 0x01);
    outb(PIC2_DATA, 0x01);

    // Unmask (enable) IRQ0 (timer), IRQ1 (keyboard), IRQ2
    // (cascade to PIC2 - REQUIRED for the mouse to work, otherwise
    // no IRQs from PIC2/slave get through at all) and IRQ12 (mouse, on PIC2).
    // Mask byte: 1 = disabled, 0 = active
    outb(PIC1_DATA, 0b11111000); // bit 0 (IRQ0), bit 1 (IRQ1), bit 2 (cascade) active
    outb(PIC2_DATA, 0b11101111); // bit 4 = IRQ12 (IRQ12 = PIC2 bit 4) active
}

// Must be called at the end of every IRQ handler so the PIC knows we are done
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

    // Fill all entries with a safe default handler FIRST
    setAllDefault();

    // Wire up the CPU exception handlers (0-19) - these catch e.g.
    // Invalid Opcode (6), General Protection Fault (13), Page Fault (14)
    // and draw the error on screen instead of silently triple-faulting.
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

    setIdtEntry(32, @ptrCast(&timer_isr)); // IRQ0 -> interrupt 32+0
    setIdtEntry(33, @ptrCast(&keyboard_isr)); // IRQ1 -> interrupt 32+1
    setIdtEntry(44, @ptrCast(&mouse_isr)); // IRQ12 -> interrupt 32+12

    idt_load(&idt_ptr);
    remapPic();

    // NOTE: interrupts are NOT enabled here. The PS/2 mouse handshake in
    // mouse.init() must run with interrupts disabled so it isn't
    // disturbed by IRQs mid-sequence. mouse.init() does "sti" itself
    // when it's done.
}
