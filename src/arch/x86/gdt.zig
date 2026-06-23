// arch/x86/gdt.zig - Zig-owned GDT (kernel + user segments) and TSS.
//
// boot.asm's GDT only has a flat kernel code/data pair (selectors 0x08/
// 0x10) - just enough to get from real mode into a known-good 32-bit
// protected mode state. Userspace needs two more things a static
// assembly-time GDT can't easily provide: ring-3 (DPL=3) code/data
// segments, and a TSS whose base address points at a Zig struct we
// don't know the address of until link time. Building a second, richer
// GDT here - the same way idt.zig owns the IDT - solves both: Zig knows
// &tss at comptime-adjacent runtime, and we can just compute the right
// bytes.
//
// Selectors after gdt.init() runs (replacing boot.asm's GDT outright):
//   0x08  kernel code (ring 0) - same flat 4 GiB segment as boot.asm had
//   0x10  kernel data (ring 0) - ditto
//   0x18  user code   (ring 3)
//   0x20  user data   (ring 3)
//   0x28  TSS
// 0x08/0x10 are deliberately byte-identical in meaning to boot.asm's
// originals, so nothing that already assumed those selectors (IDT entry
// setup, segment registers loaded in boot.asm) needs to change.

const PageDirectoryStub = void; // (no dependency - kept import list minimal)

const GdtEntry = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    access: u8 = 0,
    limit_high: u4 = 0,
    flags: u4 = 0,
    base_high: u8 = 0,
};

const GdtPointer = packed struct {
    limit: u16,
    base: u32,
};

// Standard 32-bit TSS layout (Intel SDM Vol 3A, Figure 8-4). Most fields
// are unused with no hardware task-switching and a single CPU, but
// esp0/ss0 are load-bearing: the CPU reads them on every ring3->ring0
// transition (interrupt, syscall) to know which kernel stack to switch
// to. iomap_base is set to sizeof(Tss) so no I/O permission bitmap is
// accidentally treated as present.
const Tss = extern struct {
    prev_tss: u32 = 0,
    esp0: u32 = 0,
    ss0: u32 = 0,
    esp1: u32 = 0,
    ss1: u32 = 0,
    esp2: u32 = 0,
    ss2: u32 = 0,
    cr3: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    es: u32 = 0,
    cs: u32 = 0,
    ss: u32 = 0,
    ds: u32 = 0,
    fs: u32 = 0,
    gs: u32 = 0,
    ldt: u32 = 0,
    trap: u16 = 0,
    iomap_base: u16 = 0,
};

var gdt: [6]GdtEntry = undefined;
var gdt_ptr: GdtPointer = undefined;
var tss: Tss align(16) = .{};

extern fn gdt_load(ptr: *const GdtPointer) void;

fn setEntry(index: usize, base: u32, limit: u32, access: u8, flags: u4) void {
    gdt[index] = GdtEntry{
        .limit_low = @truncate(limit),
        .base_low = @truncate(base),
        .base_mid = @truncate(base >> 16),
        .access = access,
        .limit_high = @truncate(limit >> 16),
        .flags = flags,
        .base_high = @truncate(base >> 24),
    };
}

fn ltr(selector: u16) void {
    asm volatile ("ltr %[sel]"
        :
        : [sel] "{ax}" (selector),
    );
}

pub const KERNEL_CS: u16 = 0x08;
pub const KERNEL_DS: u16 = 0x10;
pub const USER_CS: u16 = 0x18 | 3; // | 3 = RPL 3, required for a valid ring-3 selector
pub const USER_DS: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;

/// Builds and loads the GDT + TSS. Must run before idt.init() touches
/// any selector other than 0x08/0x10, and before any code attempts to
/// enter ring 3.
pub fn init() void {
    setEntry(0, 0, 0, 0, 0); // null descriptor, required by the CPU

    // Flat 4 GiB kernel code/data - identical in effect to boot.asm's,
    // flags 0xC = G(4 KiB granularity)=1, D/B(32-bit)=1, L=0, AVL=0.
    setEntry(1, 0, 0xFFFFF, 0x9A, 0xC); // 0x08 kernel code
    setEntry(2, 0, 0xFFFFF, 0x92, 0xC); // 0x10 kernel data

    // Same flat layout, ring 3 (DPL=11 in the access byte).
    setEntry(3, 0, 0xFFFFF, 0xFA, 0xC); // 0x18 user code
    setEntry(4, 0, 0xFFFFF, 0xF2, 0xC); // 0x20 user data

    // TSS descriptor: a system segment (S=0), type 0x9 = 32-bit
    // available TSS, byte granularity (flags=0, this struct is tiny).
    setEntry(5, @intFromPtr(&tss), @sizeOf(Tss) - 1, 0x89, 0x0); // 0x28

    gdt_ptr = GdtPointer{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };
    gdt_load(&gdt_ptr);

    tss.ss0 = KERNEL_DS;
    tss.iomap_base = @sizeOf(Tss);
    ltr(TSS_SEL);
}

/// Sets the ring-0 stack the CPU will switch to the NEXT time a ring-3
/// transition happens (interrupt/syscall while running user code).
/// The scheduler calls this every time it switches to a different
/// process's context, so each process's syscalls/interrupts land on
/// THAT process's own kernel stack, not whichever ran last.
pub fn setKernelStack(esp0: u32) void {
    tss.esp0 = esp0;
}
