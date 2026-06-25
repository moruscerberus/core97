// drivers/virtio_gpu.zig - virtio-gpu used ONLY as a resize sensor.
//
// vbe.zig (Bochs dispi) can already SET any resolution at runtime, with
// no reboot - but it has no way to know what size the HOST wants,
// because dispi is a one-way "set the mode" interface with no
// notification channel back from the host. That gap is exactly what
// virtio-gpu provides: VIRTIO_GPU_CMD_GET_DISPLAY_INFO reports what
// size scanout 0 (the primary display) should be, and the device's
// config_generation register increments whenever that changes - e.g.
// when the user resizes the QEMU window. Poll config_generation,
// re-query on change, feed the result into vbe.setMode().
//
// Deliberately NOT implemented: virtio-gpu's own resource/scanout
// rendering pipeline (RESOURCE_CREATE_2D, ATTACH_BACKING, SET_SCANOUT,
// TRANSFER_TO_HOST_2D, RESOURCE_FLUSH). That's a second, much larger
// protocol on top of the same device, and this kernel doesn't need it:
// `-vga virtio` (set in build.sh) runs the device in "VGA compatibility
// mode" until something actively uses virtio-gpu's native rendering
// path, which means the Bochs-dispi linear-framebuffer interface stays
// fully live and working the entire time - gui/framebuffer.zig keeps
// writing pixels exactly the way it already does, completely unaware
// any of this exists. This file only ever calls vbe.setMode(), never
// touches pixel data itself.
//
// IMPORTANT, stated plainly: this is the least-verifiable code in the
// whole kernel. Everything else this session (paging, the scheduler,
// the Bochs dispi driver) could be checked by compiling, linking, and
// reading the disassembled machine code against a known-correct
// instruction sequence. A virtio device handshake can't be confidence-
// checked that way - whether the capability offsets were parsed
// correctly, whether the feature negotiation actually completes,
// whether the device accepts the queue setup, and whether a real
// response ever comes back are all things that can only be confirmed
// by actually booting this against real QEMU. Written as carefully and
// literally against the VIRTIO 1.1 specification's described byte
// layouts as possible, but treat first boot as the real test, not this
// review.

const idt = @import("../arch/x86/idt.zig");
const pci = @import("../drivers/pci.zig");
const vbe = @import("vbe.zig");
const fb = @import("../gui/framebuffer.zig");

const VIRTIO_VENDOR_ID: u16 = 0x1AF4;
const VIRTIO_GPU_DEVICE_ID: u16 = 0x1050; // modern (virtio 1.0+) ID

const PCI_CAP_ID_VENDOR_SPECIFIC: u8 = 0x09;
const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;

// --- virtio_pci_common_cfg, mapped via the COMMON_CFG capability's
// BAR+offset. Field layout and sizes are exactly as specified in
// VIRTIO 1.1 4.1.4.3 - this struct's field order/types must not change
// without re-checking that section, since every offset here is implied
// by the preceding fields' sizes, not written out explicitly.
const CommonCfg = extern struct {
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    msix_config: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_avail: u64,
    queue_used: u64,
};

const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;
const STATUS_FEATURES_OK: u8 = 8;
const STATUS_FAILED: u8 = 0x80;

const VIRTIO_F_VERSION_1_BIT: u32 = 1 << 0; // bit 32 overall; bit 0 once feature_select=1 selects the upper word

const MAX_QUEUE_SIZE: u16 = 64; // GET_DISPLAY_INFO traffic is tiny - far more slots than ever needed

const VirtqDesc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
const VIRTQ_DESC_F_NEXT: u16 = 1;
const VIRTQ_DESC_F_WRITE: u16 = 2;

const VirtqAvail = extern struct {
    flags: u16 = 0,
    idx: u16 = 0,
    ring: [MAX_QUEUE_SIZE]u16 = [_]u16{0} ** MAX_QUEUE_SIZE,
    used_event: u16 = 0,
};
const VirtqUsedElem = extern struct {
    id: u32,
    len: u32,
};
const VirtqUsed = extern struct {
    flags: u16 = 0,
    idx: u16 = 0,
    ring: [MAX_QUEUE_SIZE]VirtqUsedElem = [_]VirtqUsedElem{.{ .id = 0, .len = 0 }} ** MAX_QUEUE_SIZE,
    avail_event: u16 = 0,
};

// All queue memory is static, page-aligned (far more alignment than
// VIRTIO 1.1 4.1.3 actually requires - 16/2/4 bytes respectively - but
// a whole page each is simple and there's no shortage of room for
// structures this small).
var desc_table: [MAX_QUEUE_SIZE]VirtqDesc align(4096) = undefined;
var avail_ring: VirtqAvail align(4096) = .{};
var used_ring: VirtqUsed align(4096) = .{};

// --- virtio_gpu protocol structures (VIRTIO 1.1 5.7) ---
const CMD_GET_DISPLAY_INFO: u32 = 0x0100;
const RESP_OK_DISPLAY_INFO: u32 = 0x1101;
const MAX_SCANOUTS: usize = 16;

const CtrlHdr = extern struct {
    cmd_type: u32 = 0,
    flags: u32 = 0,
    fence_id: u64 = 0,
    ctx_id: u32 = 0,
    padding: u32 = 0,
};
const Rect = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};
const DisplayOne = extern struct {
    r: Rect,
    enabled: u32,
    flags: u32,
};
const DisplayInfoResponse = extern struct {
    hdr: CtrlHdr,
    pmodes: [MAX_SCANOUTS]DisplayOne,
};

var request_buf: CtrlHdr align(16) = undefined;
var response_buf: DisplayInfoResponse align(16) = undefined;

var present: bool = false;
var common: *volatile CommonCfg = undefined;
var notify_addr: usize = 0;
var last_config_generation: u8 = 0;

fn mmioAddr(dev: pci.PciDevice, bar: u8, offset: u32) ?usize {
    const base = pci.barAddress(dev, bar) orelse return null;
    return @intCast(base + offset);
}

/// Reads a 32-bit virtio_pci_cap header (cap_vndr/cap_next/cap_len/
/// cfg_type/bar/padding/offset/length - VIRTIO 1.1 4.1.4) starting at
/// PCI config offset `cap_off`, and returns the resolved MMIO address
/// for that capability's BAR+offset, or null if the BAR isn't a usable
/// memory BAR.
fn capMmioAddr(dev: pci.PciDevice, cap_off: u8) ?usize {
    const bar = pci.configReadU8(dev, cap_off + 4);
    const cap_offset = pci.configReadU32(dev, cap_off + 8);
    return mmioAddr(dev, bar, cap_offset);
}

fn findVirtioGpu() ?pci.PciDevice {
    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = pci.devices[i];
        if (d.vendor_id == VIRTIO_VENDOR_ID and d.device_id == VIRTIO_GPU_DEVICE_ID) return d;
    }
    return null;
}

/// Scans PCI (already enumerated by pci.scanAll(), called earlier in
/// boot), locates the COMMON_CFG/NOTIFY_CFG capabilities, and runs the
/// standard virtio device-initialization handshake (VIRTIO 1.1 3.1.1):
/// reset, ACKNOWLEDGE, DRIVER, negotiate VIRTIO_F_VERSION_1 only,
/// FEATURES_OK (+ re-check it stuck), set up queue 0 (controlq), then
/// DRIVER_OK. Leaves `present = false` (every poll() call becomes a
/// no-op) if anything along the way doesn't look right, rather than
/// risk hanging on a malformed/partial device.
pub fn init() void {
    const dev = findVirtioGpu() orelse return;

    const common_cap = pci.findCapability(dev, PCI_CAP_ID_VENDOR_SPECIFIC, 0) orelse return;
    var notify_cap: ?u8 = null;
    var search_from = common_cap;
    var common_off: ?u8 = null;
    var guard: u8 = 0;
    var cap = common_cap;
    while (guard < 16) : (guard += 1) {
        const cfg_type = pci.configReadU8(dev, cap + 3);
        if (cfg_type == VIRTIO_PCI_CAP_COMMON_CFG and common_off == null) common_off = cap;
        if (cfg_type == VIRTIO_PCI_CAP_NOTIFY_CFG and notify_cap == null) notify_cap = cap;
        const next = pci.findCapability(dev, PCI_CAP_ID_VENDOR_SPECIFIC, search_from) orelse break;
        search_from = next;
        cap = next;
    }
    const common_cfg_off = common_off orelse return;
    const notify_cfg_off = notify_cap orelse return;

    const common_addr = capMmioAddr(dev, common_cfg_off) orelse return;
    common = @ptrFromInt(common_addr);

    const notify_bar = pci.configReadU8(dev, notify_cfg_off + 4);
    const notify_offset = pci.configReadU32(dev, notify_cfg_off + 8);
    const notify_multiplier = pci.configReadU32(dev, notify_cfg_off + 16);
    const notify_base = mmioAddr(dev, notify_bar, notify_offset) orelse return;

    pci.enableMemoryAndBusMaster(dev);

    // --- Device initialization handshake (VIRTIO 1.1 3.1.1) ---
    common.device_status = 0; // reset
    while (common.device_status != 0) {} // spec requires waiting for reset to complete
    common.device_status |= STATUS_ACKNOWLEDGE;
    common.device_status |= STATUS_DRIVER;

    common.device_feature_select = 1; // upper 32 bits, where VERSION_1 (bit 32) lives
    const upper_features = common.device_feature;
    if ((upper_features & VIRTIO_F_VERSION_1_BIT) == 0) {
        // Device doesn't speak virtio 1.0+ at all - bail rather than
        // negotiate something this driver wasn't written against.
        common.device_status |= STATUS_FAILED;
        return;
    }
    common.driver_feature_select = 1;
    common.driver_feature = VIRTIO_F_VERSION_1_BIT;
    common.driver_feature_select = 0;
    common.driver_feature = 0; // no legacy-word features requested

    common.device_status |= STATUS_FEATURES_OK;
    if ((common.device_status & STATUS_FEATURES_OK) == 0) {
        // Device rejected our (minimal) feature set - shouldn't happen
        // for a single, mandatory, universally-supported bit, but
        // honor the spec's required check rather than assume.
        return;
    }

    // --- Queue 0 (controlq) setup ---
    common.queue_select = 0;
    var qsize = common.queue_size;
    if (qsize > MAX_QUEUE_SIZE) qsize = MAX_QUEUE_SIZE;
    if (qsize == 0) return;
    common.queue_size = qsize;
    common.queue_desc = @intFromPtr(&desc_table);
    common.queue_avail = @intFromPtr(&avail_ring);
    common.queue_used = @intFromPtr(&used_ring);
    common.queue_enable = 1;

    // Per-queue notify address (VIRTIO 1.1 4.1.4.4): the NOTIFY_CFG
    // capability's own BAR+offset is the base for queue 0's notify
    // region; queue_notify_off * notify_off_multiplier locates THIS
    // queue's specific doorbell within it.
    const queue_notify_off: usize = common.queue_notify_off;
    notify_addr = notify_base + queue_notify_off * notify_multiplier;

    common.device_status |= STATUS_DRIVER_OK;

    last_config_generation = common.config_generation;
    present = true;

    // Apply the initial scanout size immediately.  Without this, QEMU
    // fullscreen starts by stretching the boot framebuffer until the next
    // resize event, which makes every glyph and icon look fat/blurry.
    // Matching the real scanout at boot gives us more desktop area instead
    // of bigger pixels.
    if (queryDisplayInfo()) |res| {
        const chosen = sanitizeHostResolution(res);
        _ = vbe.setMode(chosen.w, chosen.h);
    }
}


fn sanitizeHostResolution(res: vbe.Resolution) vbe.Resolution {
    return vbe.chooseCrispMode(res.w, res.h);
}

/// Submits a single GET_DISPLAY_INFO request and polls (briefly) for
/// the response. Returns the requested width/height for scanout 0 if
/// it's enabled, or null if the device didn't respond in time or
/// scanout 0 is disabled. Polling rather than interrupt-driven, same
/// pragmatic choice this kernel already makes for USB HID (see
/// kernel.zig's comment on why) - virtio-gpu has no interrupt wired up
/// at all here, and a short bounded poll is simpler and safer than
/// adding one for a request that's expected to complete in microseconds.
fn queryDisplayInfo() ?vbe.Resolution {
    request_buf = CtrlHdr{ .cmd_type = CMD_GET_DISPLAY_INFO };
    response_buf = .{ .hdr = .{}, .pmodes = [_]DisplayOne{.{ .r = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .enabled = 0, .flags = 0 }} ** MAX_SCANOUTS };

    desc_table[0] = .{
        .addr = @intFromPtr(&request_buf),
        .len = @sizeOf(CtrlHdr),
        .flags = VIRTQ_DESC_F_NEXT,
        .next = 1,
    };
    desc_table[1] = .{
        .addr = @intFromPtr(&response_buf),
        .len = @sizeOf(DisplayInfoResponse),
        .flags = VIRTQ_DESC_F_WRITE,
        .next = 0,
    };

    const slot = avail_ring.idx % common.queue_size;
    avail_ring.ring[slot] = 0; // head descriptor index of our chain
    asm volatile ("" ::: "memory"); // compiler barrier: ring entry must be visible before idx advances
    avail_ring.idx += 1;
    asm volatile ("" ::: "memory"); // ...and idx must be visible before the doorbell write

    const notify_ptr: *volatile u16 = @ptrFromInt(notify_addr);
    notify_ptr.* = 0; // queue index 0 (controlq)

    const target_used_idx = avail_ring.idx;
    var spins: u32 = 0;
    const used_idx_ptr: *volatile u16 = @ptrCast(&used_ring.idx);
    while (used_idx_ptr.* != target_used_idx) {
        spins += 1;
        if (spins > 5_000_000) return null; // device never responded - don't hang forever
    }

    if (response_buf.hdr.cmd_type != RESP_OK_DISPLAY_INFO) return null;
    const mode0 = response_buf.pmodes[0];
    if (mode0.enabled == 0 or mode0.r.width == 0 or mode0.r.height == 0) return null;
    return .{ .w = mode0.r.width, .h = mode0.r.height };
}

/// Call periodically from the kernel main loop (alongside the existing
/// USB HID poll - see kernel.zig). Cheap when nothing has changed: just
/// one MMIO byte read (config_generation) per call, with the actual
/// GET_DISPLAY_INFO round trip only happening on an actual change.
/// Returns true if the resolution actually changed (vbe.setMode()
/// succeeded), so the caller knows to redraw the whole screen at the
/// new size rather than waiting for the next unrelated redraw trigger.
pub fn poll() bool {
    if (!present) return false;
    const gen = common.config_generation;
    if (gen == last_config_generation) return false;
    last_config_generation = gen;

    if (queryDisplayInfo()) |res| {
        const chosen = sanitizeHostResolution(res);
        if (chosen.w == fb.fb_width and chosen.h == fb.fb_height) return false;
        return vbe.setMode(chosen.w, chosen.h);
    }
    return false;
}
