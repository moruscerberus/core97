// drivers/guest.zig - VM guest additions detection hooks.
// Real guest services are staged: detection + scale/input/time status now,
// mode-setting/shared features later.

const fb = @import("../gui/framebuffer.zig");
const pci = @import("pci.zig");

pub var is_virtual: bool = false;
pub var is_qemu: bool = false;
pub var is_virtualbox: bool = false;
pub var is_vmware: bool = false;
pub var has_qemu_vga: bool = false;
pub var has_virtio: bool = false;
pub var has_e1000_host_nic: bool = false;
pub var scale_percent: u32 = 100;
pub var input_grabbed: bool = false;

pub fn detect() void {
    has_qemu_vga = false;
    has_virtio = false;
    has_e1000_host_nic = false;
    is_virtualbox = false;
    is_vmware = false;

    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = pci.devices[i];
        if (d.vendor_id == 0x1234 and d.device_id == 0x1111) has_qemu_vga = true;
        if (d.vendor_id == 0x1AF4) has_virtio = true;
        if (d.vendor_id == 0x8086 and d.device_id == 0x100E) has_e1000_host_nic = true;
        if (d.vendor_id == 0x80EE) is_virtualbox = true;
        if (d.vendor_id == 0x15AD) is_vmware = true;
    }

    is_qemu = has_qemu_vga or has_virtio;
    is_virtual = is_qemu or is_virtualbox or is_vmware;

    scale_percent = 100; // 1:1 crisp pixels; layout follows fb.fb_width/fb.fb_height instead of stretching
}

pub fn status() []const u8 {
    if (is_qemu and has_virtio) return "QEMU/KVM + VirtIO detected";
    if (is_qemu and has_e1000_host_nic) return "QEMU VGA + emulated E1000 detected";
    if (is_qemu) return "QEMU/Bochs display detected";
    if (is_virtualbox) return "VirtualBox detected";
    if (is_vmware) return "VMware detected";
    return "generic PC";
}

pub fn grabInput() void { input_grabbed = true; }
pub fn releaseInput() void { input_grabbed = false; }

pub fn timeStatus() []const u8 {
    if (is_virtual) return "RTC/CMOS time available; host time sync service pending";
    return "RTC/CMOS time planned; PIT ticks active";
}
