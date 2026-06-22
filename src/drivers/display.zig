// drivers/display.zig - basic display adapter detection and framebuffer status.

const fb = @import("../gui/framebuffer.zig");
const pci = @import("pci.zig");

pub fn isDisplay(dev: pci.PciDevice) bool {
    return dev.class_code == 0x03;
}

pub fn deviceName(dev: pci.PciDevice) []const u8 {
    if (dev.vendor_id == 0x1234 and dev.device_id == 0x1111) return "QEMU/Bochs Standard VGA Graphics Adapter";
    if (dev.vendor_id == 0x80EE and dev.device_id == 0xBEEF) return "VirtualBox Graphics Adapter";
    if (dev.vendor_id == 0x15AD and dev.device_id == 0x0405) return "VMware SVGA II Adapter";
    if (dev.vendor_id == 0x1AF4) return "VirtIO GPU Adapter";
    if (dev.vendor_id == 0x1002) return "AMD Radeon Graphics Adapter";
    if (dev.vendor_id == 0x10DE) return "NVIDIA GeForce Graphics Adapter";
    if (dev.vendor_id == 0x8086) return "Intel Graphics Adapter";
    if (dev.class_code == 0x03 and dev.subclass == 0x00) return "Standard VGA Graphics Adapter";
    if (dev.class_code == 0x03 and dev.subclass == 0x02) return "3D Display Controller";
    return "PCI Display Controller";
}

pub fn firstAdapter() ?pci.PciDevice {
    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        if (isDisplay(pci.devices[i])) return pci.devices[i];
    }
    return null;
}

pub fn modeText() []const u8 {
    if (fb.fb_width >= 1280 or fb.fb_height >= 900) return "linear framebuffer, hi-res scaling";
    if (fb.fb_width >= 800 or fb.fb_height >= 600) return "linear framebuffer";
    return "linear framebuffer, compact mode";
}
