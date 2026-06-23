// arch/x86/paging.zig - Phase 1 virtual memory: identity-mapped 4 MiB pages.
//
// Goal of this phase: turn paging ON without breaking anything that
// already works. Every driver in this kernel (network.zig's NIC MMIO
// registers, the framebuffer, UHCI, PCI config space) talks to raw
// physical addresses today. If we paged in only "the bits we think we
// need", any address we forgot would page-fault the instant a driver
// touched it - usually mid-frame, with no useful diagnostic.
//
// The fix: identity-map the ENTIRE 4 GiB address space 1:1 (virtual ==
// physical) using x86's 4 MiB "huge page" feature (PSE - Page Size
// Extension). A single 4 KiB Page Directory, where each of its 1024
// entries directly maps a 4 MiB chunk, covers all 4 GiB with no separate
// page tables at all. Nothing currently running can tell the difference
// between "no paging" and "fully identity-mapped paging" - same
// addresses resolve to the same physical memory either way.
//
// What this buys us that "no paging" didn't: CR3/CR2/the page-fault
// handler are now live and exercised (kernel/fault.zig already prints
// CR2 on exception 14), and we have a real Page Directory in memory we
// can start punching holes in later - e.g. per-process page directories
// with their own 4 KiB mappings for userspace, once that phase lands.
// This file deliberately does NOT do per-page protection or demand
// paging yet; that's the next phase, built on top of this one.

const PAGE_DIRECTORY_ENTRIES: usize = 1024;
const FOUR_MIB: u32 = 4 * 1024 * 1024;

// --- 4 MiB Page Directory Entry (CR4.PSE=1, PDE.PS=1) ---
// Bit layout per Intel SDM Vol 3A, 4.3 (32-bit paging, PSE 4 MiB pages):
//   0     Present
//   1     Read/Write
//   2     User/Supervisor
//   3     Page-level write-through
//   4     Page-level cache disable
//   5     Accessed
//   6     Dirty
//   7     Page Size (must be 1 here - this is what makes it a 4 MiB page)
//   8     Global
//   9-11  Available for OS use (unused here)
//   12    PAT
//   13-21 Reserved, must be 0
//   22-31 Physical base address bits 31:22 (the 4 MiB-aligned frame number)
//
// Because a 4 MiB-aligned address is exactly `frame_index << 22`, the
// frame_index we want to put in base_addr_high10 is just the loop index
// (0, 1, 2, ...) when building an identity map - frame N covers bytes
// [N * 4MiB, (N+1) * 4MiB).
const PageDirectoryEntry4M = packed struct(u32) {
    present: u1 = 0,
    read_write: u1 = 0,
    user_supervisor: u1 = 0,
    write_through: u1 = 0,
    cache_disabled: u1 = 0,
    accessed: u1 = 0,
    dirty: u1 = 0,
    page_size: u1 = 0,
    global: u1 = 0,
    avail: u3 = 0,
    pat: u1 = 0,
    reserved: u9 = 0,
    base_addr_high10: u10 = 0,
};

// Must be 4 KiB-aligned - CR3 only stores the top 20 bits of the
// directory's physical address and silently truncates the rest.
var page_directory: [PAGE_DIRECTORY_ENTRIES]PageDirectoryEntry4M align(4096) = undefined;

var paging_enabled: bool = false;

// --- CR0/CR3/CR4 access ---
// idt.zig already has readCr2() for the page-fault address; these three
// are paging-specific (enabling it, pointing it at our directory) so
// they live here instead.

fn readCr0() u32 {
    return asm volatile ("mov %%cr0, %[result]"
        : [result] "={eax}" (-> u32),
    );
}

fn writeCr0(value: u32) void {
    asm volatile ("mov %[value], %%cr0"
        :
        : [value] "{eax}" (value),
    );
}

fn writeCr3(value: u32) void {
    asm volatile ("mov %[value], %%cr3"
        :
        : [value] "{eax}" (value),
    );
}

fn readCr4() u32 {
    return asm volatile ("mov %%cr4, %[result]"
        : [result] "={eax}" (-> u32),
    );
}

fn writeCr4(value: u32) void {
    asm volatile ("mov %[value], %%cr4"
        :
        : [value] "{eax}" (value),
    );
}

const CR4_PSE_BIT: u32 = 1 << 4; // Page Size Extension - enables 4 MiB pages
const CR0_PG_BIT: u32 = 1 << 31; // Paging enable

// Builds the identity-mapped Page Directory (no CPU state touched yet).
// Supervisor-only (user_supervisor=0): this is the KERNEL's own
// directory, used while slot 0 (the kernel main loop) is running. Ring 0
// can always read/write supervisor pages regardless of CPL, so this
// doesn't block anything the kernel itself does - it only blocks ring-3
// code, and the kernel loop never runs ring-3 code directly. Per-process
// isolation (below) works by giving each PROCESS its own directory: a
// copy of this exact template, with user-access added back in ONLY for
// that one process's own dedicated region.
fn buildIdentityMap(dir: *[PAGE_DIRECTORY_ENTRIES]PageDirectoryEntry4M) void {
    var i: u32 = 0;
    while (i < PAGE_DIRECTORY_ENTRIES) : (i += 1) {
        dir[i] = PageDirectoryEntry4M{
            .present = 1,
            .read_write = 1,
            .user_supervisor = 0, // supervisor-only by default
            .page_size = 1,
            .base_addr_high10 = @truncate(i),
        };
    }
}

// --- Per-process page directories (real isolation) ---
//
// Each process gets its own full copy of the kernel's identity map, with
// user_supervisor flipped to 1 for ONLY the single 4 MiB frame that
// process's dedicated code+stack region lives in (see process.zig -
// PROCESS_REGION_BASE/PROCESS_REGION_SIZE). Every other frame in that
// process's directory - including every OTHER process's region, and the
// kernel's own memory - stays supervisor-only, exactly as in the base
// template. That's the entire isolation mechanism: process A's ring-3
// code physically cannot address process B's memory, because in A's own
// page directory, B's frame is marked supervisor-only and any access to
// it from ring 3 raises a page fault, the same as touching kernel memory
// would.
//
// Trade-off, stated plainly: because this still uses 4 MiB pages (the
// same mechanism Phase 1 paging already proved works, rather than
// building a second, 4 KiB-granularity page-table system under time
// pressure), each process's dedicated region is a full 4 MiB even though
// the demo programs use only a few KiB of it. That's real isolation at
// a coarse granularity, not a security shortcut - two processes truly
// cannot reach each other's memory - it's just wasteful. 4 KiB-
// granularity (real page tables instead of huge pages) would be the
// natural follow-up if per-process memory footprint ever matters.
pub const MAX_PROCESS_DIRECTORIES: usize = 4;

var process_directories: [MAX_PROCESS_DIRECTORIES][PAGE_DIRECTORY_ENTRIES]PageDirectoryEntry4M align(4096) = undefined;

/// Builds slot `index`'s page directory: the standard supervisor-only
/// template, except `user_frame_index` (that process's one dedicated
/// 4 MiB frame) is marked user-accessible in THIS COPY ONLY. Returns the
/// directory's physical address, for loading into CR3 when that process
/// is scheduled.
pub fn createProcessDirectory(index: usize, user_frame_index: u32) u32 {
    const dir = &process_directories[index];
    buildIdentityMap(dir);
    dir[user_frame_index].user_supervisor = 1;
    return @intFromPtr(dir);
}

/// Loads a different page directory. Safe to call from ring 0 at any
/// time (including mid-interrupt, which is exactly where the scheduler
/// calls it) - CR3 just changes which mappings subsequent memory
/// accesses use, starting immediately.
pub fn switchDirectory(phys_addr: u32) void {
    writeCr3(phys_addr);
}

/// The kernel's own directory's physical address - what to switch back
/// to whenever the scheduler hands control back to slot 0 (the kernel
/// main loop), which never runs ring-3 code and so never needs any
/// user-accessible pages at all.
pub fn kernelDirectoryPhysAddr() u32 {
    return @intFromPtr(&page_directory);
}

/// Builds the identity map and switches the CPU into paging mode. Safe to
/// call exactly once, early in kernel_main, after the framebuffer address
/// is known (it doesn't need to be - the whole 4 GiB space is mapped
/// either way - but logically this runs right where memory.init() used
/// to be the "first real memory step").
///
/// Because this is a 1:1 identity map, every existing pointer (framebuffer,
/// PCI BARs, the kernel's own code/data, the stack) keeps resolving to
/// exactly the same physical memory as before paging was on - nothing
/// else in the kernel has to change for this to be safe.
pub fn init() void {
    buildIdentityMap(&page_directory);

    const cr4 = readCr4();
    writeCr4(cr4 | CR4_PSE_BIT);

    writeCr3(@intFromPtr(&page_directory));

    const cr0 = readCr0();
    writeCr0(cr0 | CR0_PG_BIT);

    paging_enabled = true;
}

pub fn isEnabled() bool {
    return paging_enabled;
}

/// Physical address of the page directory, for diagnostics (Device
/// Manager, future "memory map" debug view) - not needed by anything
/// functional yet.
pub fn directoryPhysAddr() u32 {
    return @intFromPtr(&page_directory);
}
