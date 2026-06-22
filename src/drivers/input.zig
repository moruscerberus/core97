// input.zig - central input driver status.
// USB HID is the preferred path; PS/2 remains enabled as fallback.

pub const InputDriver = enum { none, ps2, usb_hid, mixed };

pub var keyboard_active: InputDriver = .none;
pub var mouse_active: InputDriver = .none;
pub var keyboard_preferred_usb: bool = true;
pub var mouse_preferred_usb: bool = true;
pub var ps2_keyboard_seen: bool = false;
pub var ps2_mouse_seen: bool = false;
pub var usb_keyboard_seen: bool = false;
pub var usb_mouse_seen: bool = false;
pub var usb_tablet_seen: bool = false;

pub fn notePs2Keyboard() void {
    ps2_keyboard_seen = true;
    if (keyboard_active == .none) keyboard_active = .ps2;
}

pub fn notePs2Mouse() void {
    ps2_mouse_seen = true;
    if (mouse_active == .none) mouse_active = .ps2;
}

pub fn noteUsbKeyboard() void {
    usb_keyboard_seen = true;
    keyboard_active = if (ps2_keyboard_seen) .mixed else .usb_hid;
}

pub fn noteUsbMouse() void {
    usb_mouse_seen = true;
    mouse_active = if (ps2_mouse_seen) .mixed else .usb_hid;
}

pub fn noteUsbTablet() void {
    usb_tablet_seen = true;
    mouse_active = if (ps2_mouse_seen) .mixed else .usb_hid;
}

pub fn chooseAfterEnumeration() void {
    if (usb_keyboard_seen) {
        keyboard_active = if (ps2_keyboard_seen) .mixed else .usb_hid;
    } else if (ps2_keyboard_seen) {
        keyboard_active = .ps2;
    }

    if (usb_mouse_seen or usb_tablet_seen) {
        mouse_active = if (ps2_mouse_seen) .mixed else .usb_hid;
    } else if (ps2_mouse_seen) {
        mouse_active = .ps2;
    }
}

pub fn driverName(d: InputDriver) []const u8 {
    return switch (d) {
        .none => "None",
        .ps2 => "Native PS/2",
        .usb_hid => "USB HID",
        .mixed => "USB HID preferred, PS/2 fallback",
    };
}

pub fn keyboardStatus() []const u8 {
    if (usb_keyboard_seen and ps2_keyboard_seen) return "USB HID keyboard active; PS/2 keyboard available as fallback";
    if (usb_keyboard_seen) return "USB HID keyboard active";
    if (ps2_keyboard_seen) return "PS/2 keyboard fallback active";
    return "no keyboard events received yet";
}

pub fn mouseStatus() []const u8 {
    if ((usb_mouse_seen or usb_tablet_seen) and ps2_mouse_seen) return "USB pointer active; PS/2 mouse available as fallback";
    if (usb_tablet_seen) return "USB tablet absolute pointer active";
    if (usb_mouse_seen) return "USB HID mouse active";
    if (ps2_mouse_seen) return "PS/2 mouse fallback active";
    return "no mouse events received yet";
}
