// drivers/usb.zig - USB controller service layer.
// The real implemented controller path is UHCI. OHCI/EHCI/xHCI are detected
// and shown as bound-to-generic so real hardware is visible instead of hidden.

const pci = @import("pci.zig");
const uhci = @import("uhci.zig");
const usb_hid = @import("usb_hid.zig");

pub const ControllerKind = enum { uhci, ohci, ehci, xhci, other };
pub const ControllerState = enum { missing, detected, running, unsupported };

pub const UsbController = struct {
    dev: pci.PciDevice,
    kind: ControllerKind,
    state: ControllerState,
    name: []const u8,
};

pub const MAX_USB_CONTROLLERS: usize = 16;
pub var controllers: [MAX_USB_CONTROLLERS]UsbController = undefined;
pub var controller_count: usize = 0;
pub var hid_ready: bool = false;
pub var uhci_count: usize = 0;
pub var ehci_count: usize = 0;
pub var xhci_count: usize = 0;
pub var hid_rescan_count: u32 = 0;
pub var last_port_bitmap: u8 = 0;

pub fn kindFor(dev: pci.PciDevice) ControllerKind {
    if (dev.class_code != 0x0C or dev.subclass != 0x03) return .other;
    return switch (dev.prog_if) {
        0x00 => .uhci,
        0x10 => .ohci,
        0x20 => .ehci,
        0x30 => .xhci,
        else => .other,
    };
}

pub fn controllerName(dev: pci.PciDevice) []const u8 {
    return switch (kindFor(dev)) {
        .uhci => "USB Universal Host Controller (UHCI)",
        .ohci => "USB Open Host Controller (OHCI)",
        .ehci => "USB2 Enhanced Host Controller (EHCI)",
        .xhci => "USB3 eXtensible Host Controller (xHCI)",
        .other => "USB Serial Bus Controller",
    };
}

pub fn driverName(k: ControllerKind) []const u8 {
    return switch (k) {
        .uhci => "uhci.sys",
        .ohci => "ohci-generic.sys",
        .ehci => "ehci-generic.sys",
        .xhci => "xhci-generic.sys",
        .other => "usb-generic.sys",
    };
}

pub fn stateName(s: ControllerState) []const u8 {
    return switch (s) {
        .missing => "Missing",
        .detected => "Detected",
        .running => "Running",
        .unsupported => "Generic/Unsupported",
    };
}

pub fn scan() void {
    controller_count = 0;
    uhci_count = 0;
    ehci_count = 0;
    xhci_count = 0;
    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = pci.devices[i];
        if (d.class_code != 0x0C or d.subclass != 0x03) continue;
        if (controller_count >= MAX_USB_CONTROLLERS) break;
        const k = kindFor(d);
        if (k == .uhci) uhci_count += 1;
        if (k == .ehci) ehci_count += 1;
        if (k == .xhci) xhci_count += 1;
        const st: ControllerState = if (k == .uhci and uhci.initialized) .running else if (k == .uhci) .detected else .unsupported;
        controllers[controller_count] = .{ .dev = d, .kind = k, .state = st, .name = controllerName(d) };
        controller_count += 1;
    }
    hid_ready = usb_hid.device_count > 0;
}

pub fn connectedHidCount() usize {
    return usb_hid.device_count;
}


pub fn hidStatusText() []const u8 {
    if (usb_hid.device_count > 0) return "USB HID enumerated and active";
    if (uhci_count > 0) return "UHCI present; HID descriptor enumeration pending/failed";
    if (ehci_count > 0 or xhci_count > 0) return "modern controller present; EHCI/xHCI HID stack pending";
    return "no USB HID bus available";
}

pub fn portBitmap() u8 {
    if (!uhci.initialized) return 0;
    var bits: u8 = 0;
    var port: u8 = 0;
    while (port < 2) : (port += 1) {
        if (uhci.isDeviceConnected(port)) bits |= if (port == 0) @as(u8, 1) else @as(u8, 2);
    }
    return bits;
}

pub fn rescanHid() void {
    if (!uhci.initialized) {
        _ = uhci.init();
    }
    usb_hid.resetEnumeration();
    if (!uhci.initialized) {
        scan();
        return;
    }
    var port: u8 = 0;
    while (port < 2) : (port += 1) {
        if (uhci.isDeviceConnected(port)) {
            uhci.resetPort(port);
            var spin: u32 = 0;
            while (spin < 300000) : (spin += 1) asm volatile ("nop");
            _ = usb_hid.enumerateDeviceOnPort(port);
        }
    }
    last_port_bitmap = portBitmap();
    hid_rescan_count += 1;
    scan();
}

pub fn hotplugPoll() bool {
    const now = portBitmap();
    if (now != last_port_bitmap) {
        rescanHid();
        return true;
    }
    return false;
}
