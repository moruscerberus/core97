// arch/x86_64/idt.zig - GDT, TSS, IDT, and PIC setup for long mode.
//
// This is the x86_64 analog of arch/x86/idt.zig. Port I/O is byte-for-byte
// identical between 32-bit and 64-bit mode (the in/out instructions don't
// care about the current mode), so those functions are duplicated rather
// than shared across a cross-arch import - see main.zig/main64.zig for
// why this project keeps the two architectures as separate trees instead
// of threading conditional imports through shared driver files.

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

// CR2 holds the faulting linear address after a page fault (#14). Read on
// a 64-bit register since long-mode addresses can exceed 32 bits.
pub fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[result]"
        : [result] "={rax}" (-> u64),
    );
}

// --- GDT (64-bit) ---
// In long mode, the CPU mostly ignores segment base/limit for code and
// data - only a handful of access-rights bits matter. Rather than fight
// a packed-struct layout for that, each descriptor is built as a single
// 64-bit value with just those bits set, following the standard segment
// descriptor bit layout (this is the common "long mode GDT" idiom seen
// across OSDev references).
const SEG_WRITABLE: u64 = 1 << 41;
const SEG_EXECUTABLE: u64 = 1 << 43;
const SEG_NOT_SYSTEM: u64 = 1 << 44; // S bit: 1 = code/data, 0 = system segment
const SEG_PRESENT: u64 = 1 << 47;
const SEG_LONG_MODE: u64 = 1 << 53; // L bit: only meaningful for code segments

const GDT_NULL: u64 = 0;
const GDT_CODE: u64 = SEG_EXECUTABLE | SEG_NOT_SYSTEM | SEG_PRESENT | SEG_LONG_MODE;
const GDT_DATA: u64 = SEG_WRITABLE | SEG_NOT_SYSTEM | SEG_PRESENT;

pub const KERNEL_CODE_SELECTOR: u16 = 0x08;
pub const KERNEL_DATA_SELECTOR: u16 = 0x10;
pub const TSS_SELECTOR: u16 = 0x18;

const Gdt64 = extern struct {
    null_entry: u64 = GDT_NULL,
    code: u64 = GDT_CODE,
    data: u64 = GDT_DATA,
    tss_low: u64 = 0, // filled in at init() once the TSS's address is known
    tss_high: u64 = 0,
};

const DescriptorPointer = packed struct {
    limit: u16,
    base: u64,
};

var gdt: Gdt64 = .{};
var gdt_ptr: DescriptorPointer = undefined;

// --- TSS (Task State Segment) ---
// We don't use hardware task-switching - the only thing we need the TSS
// for is its IST (Interrupt Stack Table) slots, which let specific
// vectors force a stack switch on entry regardless of what the current
// stack looks like. That's what makes the double-fault handler reliable
// even if the fault was caused by stack overflow/corruption: vector 8's
// IDT entry below points at IST1, so the CPU switches to
// `double_fault_stack` before running our handler, instead of trying
// (and failing) to push onto whatever stack got it into trouble.
//
// Field layout matches the Intel SDM's 64-bit TSS exactly, including its
// slightly odd non-8-byte-aligned u64 fields - `packed struct` in Zig
// lays fields out with zero implicit padding, which is exactly what the
// hardware expects here.
const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = 0,
};

var tss: Tss = .{};

const DOUBLE_FAULT_STACK_SIZE: usize = 16 * 1024;
var double_fault_stack: [DOUBLE_FAULT_STACK_SIZE]u8 align(16) = undefined;

fn tssDescriptorLow(base: u64, limit: u32) u64 {
    const limit_low: u64 = limit & 0xFFFF;
    const base_low: u64 = base & 0xFFFF;
    const base_mid: u64 = (base >> 16) & 0xFF;
    const access: u64 = 0x89; // present(1) | type=9 (64-bit TSS, available)
    const limit_high: u64 = (limit >> 16) & 0xF;
    const base_high: u64 = (base >> 24) & 0xFF;
    return limit_low | (base_low << 16) | (base_mid << 32) | (access << 40) | (limit_high << 48) | (base_high << 56);
}

fn tssDescriptorHigh(base: u64) u64 {
    return (base >> 32) & 0xFFFFFFFF;
}

extern fn gdt64_flush(ptr: *const DescriptorPointer) void;
extern fn tss64_flush(selector: u16) void;

fn initGdtAndTss() void {
    tss.ist1 = @intFromPtr(&double_fault_stack) + DOUBLE_FAULT_STACK_SIZE;

    const tss_base: u64 = @intFromPtr(&tss);
    const tss_limit: u32 = @sizeOf(Tss) - 1;
    gdt.tss_low = tssDescriptorLow(tss_base, tss_limit);
    gdt.tss_high = tssDescriptorHigh(tss_base);

    gdt_ptr = .{
        .limit = @sizeOf(Gdt64) - 1,
        .base = @intFromPtr(&gdt),
    };

    gdt64_flush(&gdt_ptr);
    tss64_flush(TSS_SELECTOR);
}

// --- IDT (64-bit) ---
// Each gate is 16 bytes (vs 8 on x86-32) so it can hold a full 64-bit
// handler address, plus an IST index that the double-fault entry uses
// (see above).
const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8, // low 3 bits = IST index; 0 = don't switch stacks
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

var idt: [256]IdtEntry = undefined;
var idt_ptr: DescriptorPointer = undefined;

extern fn idt64_load(ptr: *const DescriptorPointer) void;
extern fn idt64_keyboard_isr() void;
extern fn idt64_timer_isr() void;
extern fn idt64_default_isr() void;

extern fn idt64_exception_isr_0() void;
extern fn idt64_exception_isr_1() void;
extern fn idt64_exception_isr_2() void;
extern fn idt64_exception_isr_3() void;
extern fn idt64_exception_isr_4() void;
extern fn idt64_exception_isr_5() void;
extern fn idt64_exception_isr_6() void;
extern fn idt64_exception_isr_7() void;
extern fn idt64_exception_isr_8() void;
extern fn idt64_exception_isr_9() void;
extern fn idt64_exception_isr_10() void;
extern fn idt64_exception_isr_11() void;
extern fn idt64_exception_isr_12() void;
extern fn idt64_exception_isr_13() void;
extern fn idt64_exception_isr_14() void;
extern fn idt64_exception_isr_15() void;
extern fn idt64_exception_isr_16() void;
extern fn idt64_exception_isr_17() void;
extern fn idt64_exception_isr_18() void;
extern fn idt64_exception_isr_19() void;

fn setIdtEntry(num: u8, handler: *const fn () callconv(.Naked) void, ist: u8) void {
    const addr: u64 = @intFromPtr(handler);
    idt[num] = IdtEntry{
        .offset_low = @truncate(addr),
        .selector = KERNEL_CODE_SELECTOR,
        .ist = ist,
        .type_attr = 0x8E, // present, ring 0, 64-bit interrupt gate
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
    };
}

fn setAllDefault() void {
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        setIdtEntry(@truncate(i), @ptrCast(&idt64_default_isr), 0);
    }
}

// --- PIC remap --- (same procedure as the 32-bit kernel; the PIC itself
// doesn't know or care what CPU mode it's talking to)
const PIC1_COMMAND = 0x20;
const PIC1_DATA = 0x21;
const PIC2_COMMAND = 0xA0;
const PIC2_DATA = 0xA1;

fn remapPic() void {
    outb(PIC1_COMMAND, 0x11);
    outb(PIC2_COMMAND, 0x11);

    outb(PIC1_DATA, 32);
    outb(PIC2_DATA, 40);

    outb(PIC1_DATA, 4);
    outb(PIC2_DATA, 2);

    outb(PIC1_DATA, 0x01);
    outb(PIC2_DATA, 0x01);

    // Unmask IRQ0 (timer) and IRQ1 (keyboard) only - no PS/2 mouse or
    // cascade-dependent IRQ12 in this first x86_64 pass.
    outb(PIC1_DATA, 0b11111100);
    outb(PIC2_DATA, 0b11111111);
}

pub fn picSendEoi(irq: u8) void {
    if (irq >= 8) {
        outb(PIC2_COMMAND, 0x20);
    }
    outb(PIC1_COMMAND, 0x20);
}

pub fn init() void {
    initGdtAndTss();

    idt_ptr = .{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    setAllDefault();

    setIdtEntry(0, @ptrCast(&idt64_exception_isr_0), 0);
    setIdtEntry(1, @ptrCast(&idt64_exception_isr_1), 0);
    setIdtEntry(2, @ptrCast(&idt64_exception_isr_2), 0);
    setIdtEntry(3, @ptrCast(&idt64_exception_isr_3), 0);
    setIdtEntry(4, @ptrCast(&idt64_exception_isr_4), 0);
    setIdtEntry(5, @ptrCast(&idt64_exception_isr_5), 0);
    setIdtEntry(6, @ptrCast(&idt64_exception_isr_6), 0);
    setIdtEntry(7, @ptrCast(&idt64_exception_isr_7), 0);
    setIdtEntry(8, @ptrCast(&idt64_exception_isr_8), 1); // double fault -> IST1
    setIdtEntry(9, @ptrCast(&idt64_exception_isr_9), 0);
    setIdtEntry(10, @ptrCast(&idt64_exception_isr_10), 0);
    setIdtEntry(11, @ptrCast(&idt64_exception_isr_11), 0);
    setIdtEntry(12, @ptrCast(&idt64_exception_isr_12), 0);
    setIdtEntry(13, @ptrCast(&idt64_exception_isr_13), 0);
    setIdtEntry(14, @ptrCast(&idt64_exception_isr_14), 0);
    setIdtEntry(15, @ptrCast(&idt64_exception_isr_15), 0);
    setIdtEntry(16, @ptrCast(&idt64_exception_isr_16), 0);
    setIdtEntry(17, @ptrCast(&idt64_exception_isr_17), 0);
    setIdtEntry(18, @ptrCast(&idt64_exception_isr_18), 0);
    setIdtEntry(19, @ptrCast(&idt64_exception_isr_19), 0);

    setIdtEntry(32, @ptrCast(&idt64_timer_isr), 0); // IRQ0
    setIdtEntry(33, @ptrCast(&idt64_keyboard_isr), 0); // IRQ1

    idt64_load(&idt_ptr);
    remapPic();

    // Interrupts are NOT enabled here (no `sti`) - that's left to
    // kernel64.zig, once everything else is wired up.
}
