// pci.zig - PCI bus enumeration
// The USB controller (UHCI) sits on the PCI bus, not on a fixed known
// port like PS/2. We have to "scan" all PCI devices and look for
// one with the right class/subclass/prog-if code for UHCI.
//
// The PCI configuration space is accessed via two I/O ports (0xCF8/0xCFC),
// an older but universally supported interface ("PCI configuration
// mechanism #1").

const idt = @import("../arch/x86/idt.zig");

const PCI_CONFIG_ADDRESS: u16 = 0xCF8;
const PCI_CONFIG_DATA: u16 = 0xCFC;

// Reads a 32-bit value from the PCI configuration space for a given
// bus/device/function/offset combination.
fn pciConfigReadU32(bus: u8, device: u8, function: u8, offset: u8) u32 {
    const address: u32 =
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8) |
        (@as(u32, offset) & 0xFC) |
        0x80000000; // enable-bit

    idt.outl(PCI_CONFIG_ADDRESS, address);
    return idt.inl(PCI_CONFIG_DATA);
}

fn pciConfigReadU16(bus: u8, device: u8, function: u8, offset: u8) u16 {
    const dword = pciConfigReadU32(bus, device, function, offset & 0xFC);
    const shift: u32 = @as(u32, offset & 2) * 8;
    return @truncate(dword >> @intCast(shift));
}

fn pciConfigReadU8(bus: u8, device: u8, function: u8, offset: u8) u8 {
    const dword = pciConfigReadU32(bus, device, function, offset & 0xFC);
    const shift: u32 = @as(u32, offset & 3) * 8;
    return @truncate(dword >> @intCast(shift));
}

fn pciConfigWriteU16(bus: u8, device: u8, function: u8, offset: u8, value: u16) void {
    const dword = pciConfigReadU32(bus, device, function, offset & 0xFC);
    const shift: u32 = @as(u32, offset & 2) * 8;
    const mask: u32 = @as(u32, 0xFFFF) << @intCast(shift);
    const new_dword = (dword & ~mask) | (@as(u32, value) << @intCast(shift));

    const address: u32 =
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8) |
        (@as(u32, offset) & 0xFC) |
        0x80000000;

    idt.outl(PCI_CONFIG_ADDRESS, address);
    idt.outl(PCI_CONFIG_DATA, new_dword);
}

pub const PciDevice = struct {
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    prog_if: u8,
    // Base Address Registers. BAR4 is used by UHCI; BAR0/BAR1 are useful for GPUs/NICs.
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,
    interrupt_line: u8,
    interrupt_pin: u8,
    command: u16,
    status: u16,
};

// Enables I/O space access (bit 0) and bus mastering (bit 2) in
// the PCI Command register. The UHCI controller needs both: I/O space
// so we can talk to its ports, bus mastering so it can DMA
// (read our frame list) from memory.
pub fn enableIoAndBusMaster(dev: PciDevice) void {
    const PCI_COMMAND_OFFSET: u8 = 0x04;
    var cmd = pciConfigReadU16(dev.bus, dev.device, dev.function, PCI_COMMAND_OFFSET);
    cmd |= 0x01; // I/O space enable
    cmd |= 0x04; // Bus master enable
    pciConfigWriteU16(dev.bus, dev.device, dev.function, PCI_COMMAND_OFFSET, cmd);
}


pub fn enableMemoryAndBusMaster(dev: PciDevice) void {
    const PCI_COMMAND_OFFSET: u8 = 0x04;
    var cmd = pciConfigReadU16(dev.bus, dev.device, dev.function, PCI_COMMAND_OFFSET);
    cmd |= 0x02; // memory space enable
    cmd |= 0x04; // bus master enable
    pciConfigWriteU16(dev.bus, dev.device, dev.function, PCI_COMMAND_OFFSET, cmd);
}

pub fn enableIoMemoryAndBusMaster(dev: PciDevice) void {
    const PCI_COMMAND_OFFSET: u8 = 0x04;
    var cmd = pciConfigReadU16(dev.bus, dev.device, dev.function, PCI_COMMAND_OFFSET);
    cmd |= 0x01; // I/O space enable
    cmd |= 0x02; // memory space enable
    cmd |= 0x04; // bus master enable
    pciConfigWriteU16(dev.bus, dev.device, dev.function, PCI_COMMAND_OFFSET, cmd);
}

pub fn resourceText(dev: PciDevice) []const u8 {
    if (dev.bar0 != 0) return "BAR0 memory/io resource present";
    if (dev.bar4 != 0) return "BAR4 io resource present";
    return "no BAR resource reported";
}

// UHCI USB controller: class=0x0C (Serial Bus Controller),
// subclass=0x03 (USB), prog_if=0x00 (UHCI specific)
const USB_CLASS: u8 = 0x0C;
const USB_SUBCLASS: u8 = 0x03;
const UHCI_PROG_IF: u8 = 0x00;

pub const MAX_PCI_DEVICES: usize = 256;
pub var devices: [MAX_PCI_DEVICES]PciDevice = undefined;
pub var device_count: usize = 0;
pub var uhci_device: ?PciDevice = null;
pub var total_devices_found: u32 = 0; // DEBUG: to verify basic PCI I/O works

pub fn className(class_code: u8, subclass: u8) []const u8 {
    return switch (class_code) {
        0x00 => "Legacy",
        0x01 => if (subclass == 0x06) "SATA" else if (subclass == 0x08) "NVMe" else if (subclass == 0x01) "IDE" else "Storage",
        0x02 => "Network",
        0x03 => if (subclass == 0x00) "VGA" else "Display",
        0x04 => if (subclass == 0x03) "Audio" else "Multimedia",
        0x05 => "Memory",
        0x06 => if (subclass == 0x00) "Host Bridge" else if (subclass == 0x01) "ISA Bridge" else if (subclass == 0x04) "PCI Bridge" else "Bridge",
        0x07 => "Comm",
        0x08 => "System",
        0x09 => "Input",
        0x0A => "Dock",
        0x0B => "CPU",
        0x0C => "Serial Bus",
        0x0D => "Wireless",
        else => "Unknown",
    };
}

fn addDevice(dev: PciDevice) void {
    if (device_count < MAX_PCI_DEVICES) {
        devices[device_count] = dev;
        device_count += 1;
    }
}

// Scans all 256 buses x 32 devices x 8 functions for a UHCI
// controller. That's 65536 iterations worst case, but the vast majority
// of slots are empty (vendor_id = 0xFFFF) and we bail out quickly for those.
pub fn scanAll() void {
    device_count = 0;
    total_devices_found = 0;
    uhci_device = null;

    var bus: u16 = 0;
    while (bus < 256) : (bus += 1) {
        var device: u8 = 0;
        while (device < 32) : (device += 1) {
            const vendor_id = pciConfigReadU16(@truncate(bus), device, 0, 0x00);
            if (vendor_id == 0xFFFF) continue;

            const header_type = pciConfigReadU8(@truncate(bus), device, 0, 0x0E);
            const function_count: u8 = if ((header_type & 0x80) != 0) 8 else 1;

            var function: u8 = 0;
            while (function < function_count) : (function += 1) {
                const vid = pciConfigReadU16(@truncate(bus), device, function, 0x00);
                if (vid == 0xFFFF) continue;

                const dev = PciDevice{
                    .bus = @truncate(bus),
                    .device = device,
                    .function = function,
                    .vendor_id = vid,
                    .device_id = pciConfigReadU16(@truncate(bus), device, function, 0x02),
                    .class_code = pciConfigReadU8(@truncate(bus), device, function, 0x0B),
                    .subclass = pciConfigReadU8(@truncate(bus), device, function, 0x0A),
                    .prog_if = pciConfigReadU8(@truncate(bus), device, function, 0x09),
                    .bar0 = pciConfigReadU32(@truncate(bus), device, function, 0x10),
                    .bar1 = pciConfigReadU32(@truncate(bus), device, function, 0x14),
                    .bar2 = pciConfigReadU32(@truncate(bus), device, function, 0x18),
                    .bar3 = pciConfigReadU32(@truncate(bus), device, function, 0x1C),
                    .bar4 = pciConfigReadU32(@truncate(bus), device, function, 0x20),
                    .bar5 = pciConfigReadU32(@truncate(bus), device, function, 0x24),
                    .interrupt_line = pciConfigReadU8(@truncate(bus), device, function, 0x3C),
                    .interrupt_pin = pciConfigReadU8(@truncate(bus), device, function, 0x3D),
                    .command = pciConfigReadU16(@truncate(bus), device, function, 0x04),
                    .status = pciConfigReadU16(@truncate(bus), device, function, 0x06),
                };
                total_devices_found += 1;
                addDevice(dev);

                if (dev.class_code == USB_CLASS and dev.subclass == USB_SUBCLASS and dev.prog_if == UHCI_PROG_IF and uhci_device == null) {
                    uhci_device = dev;
                }
            }
        }
    }
}

// Backwards-compatible name used by the USB path. It now fills the full
// PCI device table as well as remembering the first UHCI controller.
pub fn scanForUhci() void {
    scanAll();
}

// --- Public config-space accessors + capability-list walking ---
// Needed by drivers/virtio_gpu.zig: the "modern" virtio-PCI transport
// locates its register blocks via the standard PCI capability list
// (PCI_STATUS bit 4 says one exists; PCI offset 0x34 points at the
// first entry), not via a fixed BAR offset the way UHCI's I/O space
// could just be used directly. This is standard PCI capability
// discovery, not virtio-specific, so it lives here in pci.zig rather
// than in the virtio driver itself.
pub fn configReadU8(dev: PciDevice, offset: u8) u8 {
    return pciConfigReadU8(dev.bus, dev.device, dev.function, offset);
}
pub fn configReadU16(dev: PciDevice, offset: u8) u16 {
    return pciConfigReadU16(dev.bus, dev.device, dev.function, offset);
}
pub fn configReadU32(dev: PciDevice, offset: u8) u32 {
    return pciConfigReadU32(dev.bus, dev.device, dev.function, offset);
}

const PCI_STATUS_OFFSET: u8 = 0x06;
const PCI_STATUS_CAPLIST: u16 = 0x10;
const PCI_CAPABILITIES_PTR_OFFSET: u8 = 0x34;

/// Finds the offset of the first capability with the given ID at or
/// after `start_after` in the capability list (0 to start from the
/// beginning). Returns null if the device has no capability list, or
/// no (further) capability with that ID exists. Pass the previous
/// result back in as `start_after` to enumerate multiple capabilities
/// sharing the same ID (virtio devices expose several
/// vendor-specific (0x09) capabilities - one per cfg_type).
pub fn findCapability(dev: PciDevice, cap_id: u8, start_after: u8) ?u8 {
    const status = configReadU16(dev, PCI_STATUS_OFFSET);
    if ((status & PCI_STATUS_CAPLIST) == 0) return null;

    var ptr = configReadU8(dev, PCI_CAPABILITIES_PTR_OFFSET);
    var guard: u8 = 0; // malformed/cyclic capability lists must not hang the scan
    while (ptr != 0 and guard < 64) : (guard += 1) {
        const this_id = configReadU8(dev, ptr);
        const next_ptr = configReadU8(dev, ptr + 1);
        if (this_id == cap_id and ptr > start_after) return ptr;
        ptr = next_ptr;
    }
    return null;
}

/// Resolves BAR `index` (0-5) to a usable physical address. Handles
/// both 32-bit and 64-bit memory BARs (a 64-bit BAR's high 32 bits live
/// in the NEXT BAR slot, per the PCI spec) - virtio's modern transport
/// commonly uses 64-bit BARs for its capability regions, unlike UHCI's
/// plain 32-bit I/O BAR this file was originally written against.
/// Returns null for I/O-space BARs (bit 0 set) - callers that need MMIO
/// should always get a real address here, not an I/O port number.
pub fn barAddress(dev: PciDevice, index: u8) ?u64 {
    const bars = [_]u32{ dev.bar0, dev.bar1, dev.bar2, dev.bar3, dev.bar4, dev.bar5 };
    if (index >= bars.len) return null;
    const bar = bars[index];
    if ((bar & 0x1) != 0) return null; // I/O space BAR, not memory

    const is_64bit = ((bar >> 1) & 0x3) == 0x2;
    const base_low: u64 = bar & 0xFFFFFFF0;
    if (!is_64bit) return base_low;

    if (index + 1 >= bars.len) return null; // malformed: 64-bit BAR with no upper half
    const base_high: u64 = bars[index + 1];
    return (base_high << 32) | base_low;
}
