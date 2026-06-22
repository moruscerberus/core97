// drivers/driver_registry.zig - tiny built-in driver/guest-tools registry.
// This is not dynamic PnP yet; it is a truthful status table that Device
// Manager and Command Prompt can query while real drivers come online.

const fb = @import("../gui/framebuffer.zig");
const mouse = @import("mouse.zig");
const pci = @import("pci.zig");
const cpu = @import("cpu.zig");
const audio = @import("audio.zig");
const guest = @import("guest.zig");
const network = @import("network.zig");
const display = @import("display.zig");
const usb = @import("usb.zig");
const input = @import("input.zig");

pub const DriverState = enum { missing, detected, bound, loaded, running, failed, stub };
pub const DriverKind = enum { cpu, display, keyboard, mouse, audio, network, guest, storage, usb, bridge, system };

pub const DriverInfo = struct {
    name: []const u8,
    kind: DriverKind,
    state: DriverState,
    detail: []const u8,
};

pub const MAX_DRIVERS: usize = 96;
pub var drivers: [MAX_DRIVERS]DriverInfo = undefined;
pub var count: usize = 0;

fn add(name: []const u8, kind: DriverKind, state: DriverState, detail: []const u8) void {
    if (count >= MAX_DRIVERS) return;
    drivers[count] = .{ .name = name, .kind = kind, .state = state, .detail = detail };
    count += 1;
}

fn hasPci(class_code: u8, vendor: u16, device: u16) bool {
    var i: usize = 0;
    while (i < pci.device_count) : (i += 1) {
        const d = pci.devices[i];
        if (class_code != 0xFF and d.class_code == class_code) return true;
        if (vendor != 0 and d.vendor_id == vendor and d.device_id == device) return true;
    }
    return false;
}

fn hasAnyNetwork() bool { return hasPci(0x02, 0, 0); }
fn hasAnyDisplay() bool { return hasPci(0x03, 0, 0); }
fn hasAnyAudio() bool { return hasPci(0x04, 0, 0); }
fn hasAnyStorage() bool { return hasPci(0x01, 0, 0); }
fn hasAnyBridge() bool { return hasPci(0x06, 0, 0); }

pub fn refresh() void {
    count = 0;
    cpu.detect();
    audio.detect();
    guest.detect();
    network.initAll();
    usb.scan();

    add("Core97 Driver Manager", .system, .running, "PCI class binding + generic fallback active");
    add("Core97 CPU Driver", .cpu, .running, cpu.name());

    if (display.firstAdapter()) |gpu| {
        add(display.deviceName(gpu), .display, .running, display.modeText());
    } else {
        add("Basic Display Adapter", .display, .running, "boot framebuffer");
    }

    add("Keyboard Input Stack", .keyboard, if (input.keyboard_active == .usb_hid or input.keyboard_active == .mixed) .running else .loaded, input.keyboardStatus());
    add("Mouse Input Stack", .mouse, if (input.mouse_active == .usb_hid or input.mouse_active == .mixed) .running else .loaded, input.mouseStatus());
    add("Native PS/2 Keyboard", .keyboard, if (input.ps2_keyboard_seen) .running else .loaded, "fallback IRQ1 scancode input");
    add("Native PS/2 Mouse", .mouse, if (input.ps2_mouse_seen) .running else .loaded, "fallback IRQ12 relative pointer");

    if (usb.controller_count > 0) {
        var ui: usize = 0;
        while (ui < usb.controller_count) : (ui += 1) {
            const c = usb.controllers[ui];
            const st: DriverState = if (c.state == .running) .running else if (c.state == .unsupported) .bound else .detected;
            add(c.name, .usb, st, usb.driverName(c.kind));
        }
    } else {
        add("USB Controller Driver", .usb, .missing, "no USB controller");
    }

    if (audio.present) add("PC Speaker Audio", .audio, .loaded, "PIT channel 2 beep device") else add("PC Speaker Audio", .audio, .stub, "speaker not tested");
    if (hasAnyAudio()) add("PCI Audio Adapter", .audio, .detected, "HDA/AC97 detected; PCM driver pending");

    if (network.adapter_count > 0) {
        var ni: usize = 0;
        while (ni < network.adapter_count) : (ni += 1) {
            const nic = network.adapters[ni];
            const st: DriverState = if (nic.state == .initialized) .running else if (nic.state == .unsupported) .bound else .bound;
            add(nic.name, .network, st, network.driverName(nic.driver));
        }
    } else {
        add("Host Network Adapter", .network, .missing, "no NIC detected");
    }

    if (hasAnyStorage()) add("Storage Controller", .storage, .detected, "IDE/AHCI/NVMe detected; filesystem deferred") else add("Disk Controller", .storage, .missing, "not detected");
    if (hasAnyBridge()) add("PCI Bridge Enumerator", .bridge, .running, "host/ISA/PCI bridges detected");
    add("Generic PCI Class Driver", .system, .loaded, "fallback names and status for unclaimed PCI devices");
    add("Generic HID Enumerator", .usb, .loaded, "lists PS/2 and USB HID keyboard/mouse/tablet devices");
    if (guest.is_virtual) add("Core97 Guest Additions", .guest, .loaded, guest.status()) else add("Core97 Guest Additions", .guest, .stub, "generic PC mode");
}

pub fn stateName(s: DriverState) []const u8 {
    return switch (s) {
        .missing => "Missing",
        .detected => "Detected",
        .bound => "Bound",
        .loaded => "Loaded",
        .running => "Running",
        .failed => "Failed",
        .stub => "Stub",
    };
}

pub fn kindName(k: DriverKind) []const u8 {
    return switch (k) {
        .cpu => "CPU",
        .display => "Display",
        .keyboard => "Keyboard",
        .mouse => "Mouse",
        .audio => "Audio",
        .network => "Network",
        .guest => "Guest",
        .storage => "Storage",
        .usb => "USB",
        .bridge => "Bridge",
        .system => "System",
    };
}

pub fn displayScalePercent() u32 {
    if (fb.fb_width >= 1200 or fb.fb_height >= 900) return 150;
    if (fb.fb_width >= 900 or fb.fb_height >= 700) return 125;
    return 100;
}

pub fn inputMode() []const u8 {
    _ = mouse.screen_width;
    return input.driverName(input.keyboard_active);
}
