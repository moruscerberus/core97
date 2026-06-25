// kernel/memory.zig - early physical memory manager + tiny kernel heap.
// Parses the Multiboot memory map, tracks 4 KiB physical pages, and
// exposes stats for Device Manager. This is purely physical bookkeeping
// (which 4 KiB frames are free/used) - virtual memory (the actual
// page-table identity map, CR0/CR3 setup) lives in arch/x86/paging.zig
// and is enabled earlier in kernel_main, before this module's init() runs.
// Userspace (separate address spaces per process) is the next phase
// after this.

const multiboot = @import("multiboot.zig");
const fb = @import("../gui/framebuffer.zig");
const vbe = @import("../drivers/vbe.zig");

pub const PAGE_SIZE: u32 = 4096;
const MAX_TRACKED_MEM: u32 = 256 * 1024 * 1024;
const MAX_PAGES: usize = MAX_TRACKED_MEM / PAGE_SIZE;

const PAGE_FREE: u8 = 0;
const PAGE_USED: u8 = 1;

pub const Stats = struct {
    total_kib: u32,
    usable_kib: u32,
    free_kib: u32,
    used_kib: u32,
    kernel_end: u32,
    total_pages: u32,
    free_pages: u32,
    heap_used: u32,
    heap_total: u32,
    mmap_entries: u32,
};

pub const MmapEntry = extern struct {
    size: u32,
    base_addr_low: u32,
    base_addr_high: u32,
    length_low: u32,
    length_high: u32,
    type: u32,
};

extern var _kernel_start: u8;
extern var _kernel_end: u8;

var page_state: [MAX_PAGES]u8 = [_]u8{PAGE_USED} ** MAX_PAGES;
var total_pages: u32 = 0;
var free_pages: u32 = 0;
var total_kib: u32 = 0;
var usable_kib: u32 = 0;
var mmap_entries: u32 = 0;
var kernel_end_addr: u32 = 0;

const HEAP_SIZE: usize = 512 * 1024;
var heap: [HEAP_SIZE]u8 align(16) = [_]u8{0} ** HEAP_SIZE;
var heap_offset: usize = 0;

fn alignUp(value: u32, alignment: u32) u32 {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn pageOf(addr: u32) u32 {
    return addr / PAGE_SIZE;
}

fn markPage(page: u32, state: u8) void {
    if (page >= total_pages or page >= MAX_PAGES) return;
    const idx: usize = @intCast(page);
    if (page_state[idx] == state) return;
    if (state == PAGE_FREE) {
        free_pages += 1;
    } else {
        if (free_pages > 0) free_pages -= 1;
    }
    page_state[idx] = state;
}

fn markRange(addr: u32, len: u32, state: u8) void {
    if (len == 0) return;
    const start = pageOf(addr);
    const end = pageOf(alignUp(addr + len, PAGE_SIZE));
    var p = start;
    while (p < end) : (p += 1) markPage(p, state);
}

/// Marks [addr, addr+len) as permanently used, so allocPage() never
/// hands any of it out. Used by process.zig to carve out dedicated,
/// exclusive regions for per-process isolated memory (see
/// arch/x86/paging.zig's per-process page directories) - those regions
/// are assigned by fixed physical address, not via allocPage(), so they
/// must be reserved here or the general allocator could later give the
/// same physical pages to something else entirely.
pub fn reserveRange(addr: u32, len: u32) void {
    markRange(addr, len, PAGE_USED);
}

pub fn init(info: *const multiboot.MultibootInfo) void {
    kernel_end_addr = alignUp(@intFromPtr(&_kernel_end), PAGE_SIZE);
    total_pages = 0;
    free_pages = 0;
    total_kib = 0;
    usable_kib = 0;
    mmap_entries = 0;
    heap_offset = 0;

    var i: usize = 0;
    while (i < page_state.len) : (i += 1) page_state[i] = PAGE_USED;

    if ((info.flags & (1 << 6)) != 0 and info.mmap_addr != 0 and info.mmap_length != 0) {
        var offset: u32 = 0;
        while (offset < info.mmap_length) {
            const entry: *const MmapEntry = @ptrFromInt(info.mmap_addr + offset);
            mmap_entries += 1;

            // This first pass only tracks memory below 4 GiB, and caps the
            // bitmap to MAX_TRACKED_MEM so old 32-bit builds stay small.
            if (entry.base_addr_high == 0 and entry.length_high == 0) {
                const base = entry.base_addr_low;
                const len = entry.length_low;
                const end = base + len;
                if (end / 1024 > total_kib) total_kib = end / 1024;
                const capped_end = if (end > MAX_TRACKED_MEM) MAX_TRACKED_MEM else end;
                if (capped_end / PAGE_SIZE > total_pages) total_pages = capped_end / PAGE_SIZE;
            }
            offset += entry.size + 4;
        }

        offset = 0;
        while (offset < info.mmap_length) {
            const entry: *const MmapEntry = @ptrFromInt(info.mmap_addr + offset);
            if (entry.type == 1 and entry.base_addr_high == 0 and entry.length_high == 0) {
                const base = entry.base_addr_low;
                const raw_len = entry.length_low;
                if (base < MAX_TRACKED_MEM) {
                    var len = raw_len;
                    if (base + len > MAX_TRACKED_MEM) len = MAX_TRACKED_MEM - base;
                    usable_kib += len / 1024;
                    markRange(base, len, PAGE_FREE);
                }
            }
            offset += entry.size + 4;
        }
    } else {
        // Fallback for bootloaders without mmap: mem_upper is KiB above 1 MiB.
        total_kib = 1024 + info.mem_upper;
        var bytes = total_kib * 1024;
        if (bytes > MAX_TRACKED_MEM) bytes = MAX_TRACKED_MEM;
        total_pages = bytes / PAGE_SIZE;
        usable_kib = if (total_kib > 1024) total_kib - 1024 else 0;
        markRange(1024 * 1024, bytes - 1024 * 1024, PAGE_FREE);
    }

    // Never hand out low memory, the kernel image, or the framebuffer.
    // The framebuffer reservation must use the REAL hardware MMIO range
    // (real_fb_*) - the logical canvas (fb_width/fb_height) is just a
    // fixed-size RAM buffer the kernel already owns as part of its own
    // image, not a separate physical region that needs reserving here.
    //
    // Reserves vbe.MAX_FRAMEBUFFER_BYTES (the worst case, not just
    // whatever size GRUB happened to negotiate at boot) because
    // drivers/vbe.zig can change the active resolution at runtime
    // without rebooting. If only the boot-time size were reserved here,
    // switching to a LARGER resolution later could overlap physical
    // pages the heap allocator had already handed out to something
    // else, silently corrupting whichever owns them first.
    markRange(0, 1024 * 1024, PAGE_USED);
    markRange(@intFromPtr(&_kernel_start), kernel_end_addr - @intFromPtr(&_kernel_start), PAGE_USED);
    if (fb.real_fb_addr != 0) {
        markRange(@intCast(fb.real_fb_addr), vbe.MAX_FRAMEBUFFER_BYTES, PAGE_USED);
    }
}

pub fn allocPage() ?u32 {
    var p: u32 = 0;
    while (p < total_pages) : (p += 1) {
        const idx: usize = @intCast(p);
        if (page_state[idx] == PAGE_FREE) {
            markPage(p, PAGE_USED);
            return p * PAGE_SIZE;
        }
    }
    return null;
}

pub fn freePage(addr: u32) void {
    if ((addr & (PAGE_SIZE - 1)) != 0) return;
    markPage(pageOf(addr), PAGE_FREE);
}

pub fn kmalloc(size: usize, alignment: usize) ?[*]u8 {
    const a = if (alignment == 0) 1 else alignment;
    const aligned = (heap_offset + a - 1) & ~(a - 1);
    if (aligned + size > HEAP_SIZE) return null;
    heap_offset = aligned + size;
    return heap[aligned..].ptr;
}

pub fn stats() Stats {
    const free_kib = free_pages * (PAGE_SIZE / 1024);
    return .{
        .total_kib = total_kib,
        .usable_kib = usable_kib,
        .free_kib = free_kib,
        .used_kib = if (total_kib > free_kib) total_kib - free_kib else 0,
        .kernel_end = kernel_end_addr,
        .total_pages = total_pages,
        .free_pages = free_pages,
        .heap_used = @intCast(heap_offset),
        .heap_total = HEAP_SIZE,
        .mmap_entries = mmap_entries,
    };
}
