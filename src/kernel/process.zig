// kernel/process.zig - process table + first-run context construction.
//
// There's no ELF loader yet (that's a later phase), so a "process" here
// is: a small flat machine-code image (userland/user_demo.zig) copied
// into a dedicated, exclusive physical region, plus a dedicated kernel
// stack whose top is pre-built to LOOK like a real ring3->ring0
// interrupt already happened - a `pusha` register block followed by the
// hardware EIP/CS/EFLAGS/ESP/SS frame (see kernel/fault.zig's Registers
// comment for why the GP-register order is what it is). scheduler.zig's
// round-robin loop never needs to know whether a process has "really"
// run before or not - it just restores whatever esp is saved for that
// slot and lets popa+iretd do the rest, so a freshly created process's
// first scheduling is identical in mechanism to resuming one that was
// already running.
//
// Memory isolation: each process's code + user stack live in a fixed,
// EXCLUSIVE 4 MiB region (PROCESS_REGION_BASE + slot*PROCESS_REGION_SIZE)
// reserved up front via memory.reserveRange(), rather than coming from
// the general allocPage() pool. This matters because paging.zig's
// per-process page directories grant user-mode access one whole 4 MiB
// frame at a time - if two processes' code pages could land in the SAME
// 4 MiB frame (entirely possible with a generic bump allocator handing
// out individual 4 KiB pages), marking that frame user-accessible for
// one process would accidentally expose the other's memory too. Fixed,
// dedicated, never-shared regions sidestep that entirely: process slot
// N's region is physically incapable of overlapping slot M's.

const memory = @import("memory.zig");
const gdt = @import("../arch/x86/gdt.zig");
const paging = @import("../arch/x86/paging.zig");

pub const MAX_PROCESSES: usize = 4;
comptime {
    if (MAX_PROCESSES != paging.MAX_PROCESS_DIRECTORIES) {
        @compileError("process.MAX_PROCESSES must match paging.MAX_PROCESS_DIRECTORIES - " ++
            "each process slot needs its own pre-allocated page directory");
    }
}
const KERNEL_STACK_SIZE: u32 = memory.PAGE_SIZE; // 4 KiB - plenty for this tiny demo code

const FOUR_MIB: u32 = 4 * 1024 * 1024;
// Chosen to sit safely inside memory.zig's 256 MiB tracked window (well
// below it, away from the kernel/heap at the low end) while still being
// real backing RAM under QEMU's -m 512 configuration. 4 slots * 4 MiB =
// 16 MiB total, reserved once up front by init().
const PROCESS_REGION_BASE: u32 = 0x0C800000; // 200 MiB, 4 MiB-aligned
const PROCESS_REGION_SIZE: u32 = FOUR_MIB;

pub const State = enum(u8) {
    unused,
    ready,
    terminated,
};

pub const Process = struct {
    state: State = .unused,
    esp: u32 = 0, // where to resume - see frame layout below
    kernel_stack_top: u32 = 0, // top of THIS process's ring-0 stack, fed to the TSS on switch-in
    pdir_phys: u32 = 0, // physical address of this process's OWN page directory
};

pub var table: [MAX_PROCESSES]Process = [_]Process{.{}} ** MAX_PROCESSES;

/// Reserves all MAX_PROCESSES dedicated regions up front so the general
/// allocator (memory.allocPage()) never hands any of that range out for
/// something else. Call once, after memory.init(), before any
/// process.create() calls.
pub fn init() void {
    memory.reserveRange(PROCESS_REGION_BASE, PROCESS_REGION_SIZE * MAX_PROCESSES);
}

// Mirrors exactly what a real ring3->ring0 interrupt leaves on the
// stack: pusha's 8 registers (low to high address: edi..eax - see
// fault.zig), then the CPU's own EIP/CS/EFLAGS/ESP/SS frame. Building
// one of these by hand is what lets a process be "resumed" via the
// ordinary timer_isr popa+iretd path on its very first scheduling, with
// no special-casing anywhere in the interrupt path.
const FakeFrame = extern struct {
    edi: u32 = 0,
    esi: u32 = 0,
    ebp: u32 = 0,
    esp_dummy: u32 = 0,
    ebx: u32 = 0,
    edx: u32 = 0,
    ecx: u32 = 0,
    eax: u32 = 0,
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    user_ss: u32,
};

const EFLAGS_IF: u32 = 1 << 9; // interrupts enabled
const EFLAGS_RESERVED_BIT1: u32 = 1 << 1; // always set per the x86 spec

/// Creates a ring-3 process running `image`, with the byte at
/// `id_patch_offset` within the copied image overwritten to `id_char`
/// (see userland/user_demo.zig - lets several processes share one code
/// image but still be visually distinguishable on screen). Returns the
/// slot index, or null if the table is full or out of physical pages.
pub fn create(image: []const u8, id_patch_offset: usize, id_char: u8) ?usize {
    var slot: usize = 0;
    while (slot < MAX_PROCESSES) : (slot += 1) {
        if (table[slot].state == .unused) break;
    } else return null;

    const kernel_stack_page = memory.allocPage() orelse return null;

    // This process's own exclusive 4 MiB region. Code goes at the start;
    // the user stack gets a separate page later in the SAME region/SAME
    // 4 MiB frame, so marking just this one frame user-accessible (see
    // paging.createProcessDirectory) covers both.
    const region_base = PROCESS_REGION_BASE + @as(u32, @intCast(slot)) * PROCESS_REGION_SIZE;
    const code_page = region_base;
    const user_stack_page = region_base + memory.PAGE_SIZE; // second 4 KiB page in the same region

    // Identity-mapped (Phase 1 paging), so these physical addresses
    // double directly as usable pointers.
    const code_ptr: [*]u8 = @ptrFromInt(code_page);
    var i: usize = 0;
    while (i < image.len) : (i += 1) code_ptr[i] = image[i];
    if (id_patch_offset < image.len) code_ptr[id_patch_offset] = id_char;

    const kernel_stack_top = kernel_stack_page + KERNEL_STACK_SIZE;
    const user_stack_top = user_stack_page + memory.PAGE_SIZE;

    const frame_addr = kernel_stack_top - @sizeOf(FakeFrame);
    const frame: *FakeFrame = @ptrFromInt(frame_addr);
    frame.* = FakeFrame{
        .eip = code_page, // entry point = start of the copied image
        .cs = gdt.USER_CS,
        .eflags = EFLAGS_IF | EFLAGS_RESERVED_BIT1,
        .user_esp = user_stack_top,
        .user_ss = gdt.USER_DS,
    };

    const frame_index = region_base / FOUR_MIB;
    const pdir_phys = paging.createProcessDirectory(slot, frame_index);

    table[slot] = Process{
        .state = .ready,
        .esp = frame_addr,
        .kernel_stack_top = kernel_stack_top,
        .pdir_phys = pdir_phys,
    };
    return slot;
}

pub fn terminate(slot: usize) void {
    if (slot >= MAX_PROCESSES) return;
    table[slot].state = .terminated;
}
