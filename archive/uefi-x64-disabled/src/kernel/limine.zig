// kernel/limine.zig - Limine boot protocol structures.
//
// There's no official Zig binding for limine.h, so these are hand
// transcribed from the C header (limine-bootloader/limine, v8.x) and
// PROTOCOL.md. Only what this kernel actually uses is included: the base
// revision tag, the requests start/end markers, the framebuffer request,
// and the memory map request. All magic numbers below were checked
// against the upstream source, not recalled from memory - if you add a
// new request, do the same rather than guessing IDs.
//
// Requesting base revision 1: it's the first non-default revision and
// has been supported by every Limine release since, which matters more
// here than access to newer features, since we can't pin down which
// exact Limine binary a given person building this will have installed.

const LIMINE_COMMON_MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
const LIMINE_COMMON_MAGIC_1: u64 = 0x0a82e883a194f07b;

// A request struct must be placed in writable memory (the bootloader
// writes the `response` pointer into it before jumping to our entry
// point) and inside the `.limine_requests` section so the linker script
// can group it between the start/end markers - see arch/x86_64/linker.ld.

pub export var limine_base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8,
    0x6a7b384944536bdc,
    1,
};

export var limine_requests_start_marker: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae,
    0x4c7bb68200000002,
    0,
    0,
};

export var limine_requests_end_marker: [2]u64 linksection(".limine_requests_end") = .{
    0x4ce8e4acec55c906,
    0x68a35fcdb2300004,
};

// --- Framebuffer ---

pub const VideoMode = extern struct {
    pitch: u64,
    width: u64,
    height: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const Framebuffer = extern struct {
    address: ?*anyopaque,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
    mode_count: u64,
    modes: ?[*]*VideoMode,
};

const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: ?[*]*Framebuffer,
};

const FramebufferRequest = extern struct {
    id: [4]u64 = .{ LIMINE_COMMON_MAGIC_0, LIMINE_COMMON_MAGIC_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};

export var framebuffer_request: FramebufferRequest linksection(".limine_requests") = .{};

/// Returns the first framebuffer Limine reports, or null if the request
/// failed or no framebuffer is available.
pub fn getFramebuffer() ?*Framebuffer {
    const resp = framebuffer_request.response orelse return null;
    if (resp.framebuffer_count < 1) return null;
    const list = resp.framebuffers orelse return null;
    return list[0];
}

// --- Memory map ---
// Captured for Phase 4 (physical memory manager) to consume later; this
// kernel doesn't build an allocator yet, so for now we just keep the
// pointer/count around and let kernel64.zig log a summary over serial.

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: u64,
};

pub const MEMMAP_USABLE: u64 = 0;
pub const MEMMAP_RESERVED: u64 = 1;
pub const MEMMAP_ACPI_RECLAIMABLE: u64 = 2;
pub const MEMMAP_ACPI_NVS: u64 = 3;
pub const MEMMAP_BAD_MEMORY: u64 = 4;
pub const MEMMAP_BOOTLOADER_RECLAIMABLE: u64 = 5;
pub const MEMMAP_EXECUTABLE_AND_MODULES: u64 = 6;
pub const MEMMAP_FRAMEBUFFER: u64 = 7;

const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: ?[*]*MemmapEntry,
};

const MemmapRequest = extern struct {
    id: [4]u64 = .{ LIMINE_COMMON_MAGIC_0, LIMINE_COMMON_MAGIC_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*MemmapResponse = null,
};

export var memmap_request: MemmapRequest linksection(".limine_requests") = .{};

pub const Memmap = struct {
    entries: [*]*MemmapEntry,
    count: u64,
};

pub fn getMemmap() ?Memmap {
    const resp = memmap_request.response orelse return null;
    const entries = resp.entries orelse return null;
    return Memmap{ .entries = entries, .count = resp.entry_count };
}
