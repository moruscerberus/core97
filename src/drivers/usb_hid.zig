// usb_hid.zig - USB device enumeration + HID boot report parsing
// Drop-in replacement: parses Configuration/Interface/Endpoint descriptors
// instead of assuming HID class is in the Device Descriptor and endpoint == 1.

const uhci = @import("uhci.zig");

fn smallDelay(loops: u32) void {
    var i: u32 = 0;
    while (i < loops) : (i += 1) {
        asm volatile ("nop");
    }
}

fn controlTransferRetry(
    device_addr: u8,
    setup_packet: *const [8]u8,
    data_buffer: ?[*]u8,
    data_len: u16,
    is_in: bool,
) bool {
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        if (uhci.controlTransfer(device_addr, setup_packet, data_buffer, data_len, is_in)) {
            return true;
        }
        smallDelay(20000);
    }
    return false;
}

fn buildSetupPacket(
    request_type: u8,
    request: u8,
    value: u16,
    index: u16,
    length: u16,
) [8]u8 {
    return [8]u8{
        request_type,
        request,
        @truncate(value),
        @truncate(value >> 8),
        @truncate(index),
        @truncate(index >> 8),
        @truncate(length),
        @truncate(length >> 8),
    };
}

const REQ_GET_DESCRIPTOR: u8 = 0x06;
const REQ_SET_ADDRESS: u8 = 0x05;
const REQ_SET_CONFIGURATION: u8 = 0x09;
const REQ_SET_PROTOCOL: u8 = 0x0B;

const DESC_TYPE_DEVICE: u16 = 0x0100;
const DESC_TYPE_CONFIG: u16 = 0x0200;

const DT_INTERFACE: u8 = 0x04;
const DT_ENDPOINT: u8 = 0x05;

const HID_CLASS: u8 = 0x03;
const HID_BOOT_SUBCLASS: u8 = 0x01;
const HID_PROTOCOL_KEYBOARD: u8 = 0x01;
const HID_PROTOCOL_MOUSE: u8 = 0x02;

const ENDPOINT_DIR_IN: u8 = 0x80;
const ENDPOINT_TYPE_MASK: u8 = 0x03;
const ENDPOINT_TYPE_INTERRUPT: u8 = 0x03;

const DeviceDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    usb_version: u16,
    device_class: u8,
    device_subclass: u8,
    device_protocol: u8,
    max_packet_size: u8,
    vendor_id: u16,
    product_id: u16,
    device_version: u16,
    manufacturer_idx: u8,
    product_idx: u8,
    serial_idx: u8,
    num_configurations: u8,
};

pub const UsbDeviceType = enum {
    unknown,
    mouse,
    keyboard,
    tablet,
};

pub const UsbDevice = struct {
    address: u8,
    port: u8,
    device_type: UsbDeviceType,
    endpoint: u8,
    max_packet_size: u8,
    report_len: u8,
    vendor_id: u16,
    product_id: u16,
    connected: bool,
};

var next_address: u8 = 1;
var device_buffer: [256]u8 align(16) = undefined;
pub var last_failed_step: u32 = 0;

pub const MAX_ENUMERATED_USB_DEVICES: usize = 8;
pub var devices: [MAX_ENUMERATED_USB_DEVICES]UsbDevice = undefined;
pub var device_count: usize = 0;

pub fn resetEnumeration() void {
    next_address = 1;
    device_count = 0;
    last_failed_step = 0;
}

fn rememberDevice(dev: UsbDevice) void {
    var i: usize = 0;
    while (i < device_count) : (i += 1) {
        if (devices[i].address == dev.address) {
            devices[i] = dev;
            return;
        }
    }
    if (device_count < MAX_ENUMERATED_USB_DEVICES) {
        devices[device_count] = dev;
        device_count += 1;
    }
}

pub fn deviceTypeName(t: UsbDeviceType) []const u8 {
    return switch (t) {
        .unknown => "USB HID Device",
        .mouse => "USB HID Mouse",
        .keyboard => "USB HID Keyboard",
        .tablet => "USB HID Tablet",
    };
}

fn readLe16(buf: []const u8, offset: usize) u16 {
    return @as(u16, buf[offset]) | (@as(u16, buf[offset + 1]) << 8);
}

const ParsedHid = struct {
    device_type: UsbDeviceType = .unknown,
    interface_number: u8 = 0,
    endpoint: u8 = 1,
    report_len: u8 = 4,
    found: bool = false,
};

fn parseConfiguration(total_len: usize) ParsedHid {
    var parsed = ParsedHid{};
    var current_hid_interface: bool = false;

    var i: usize = 0;
    while (i + 2 <= total_len) {
        const len = device_buffer[i];
        const dtype = device_buffer[i + 1];
        if (len < 2) break;
        if (i + len > total_len) break;

        if (dtype == DT_INTERFACE and len >= 9) {
            const iface_num = device_buffer[i + 2];
            const iface_class = device_buffer[i + 5];
            const iface_subclass = device_buffer[i + 6];
            const iface_protocol = device_buffer[i + 7];

            current_hid_interface = false;

            if (iface_class == HID_CLASS) {
                parsed.interface_number = iface_num;
                current_hid_interface = true;

                if (iface_subclass == HID_BOOT_SUBCLASS and iface_protocol == HID_PROTOCOL_MOUSE) {
                    parsed.device_type = .mouse;
                    parsed.report_len = 4;
                } else if (iface_subclass == HID_BOOT_SUBCLASS and iface_protocol == HID_PROTOCOL_KEYBOARD) {
                    parsed.device_type = .keyboard;
                    parsed.report_len = 8;
                } else {
                    // QEMU usb-tablet is a normal HID pointer, not boot mouse.
                    // We treat non-boot HID pointer-like devices as absolute tablets.
                    parsed.device_type = .tablet;
                    parsed.report_len = 8;
                }
            }
        } else if (dtype == DT_ENDPOINT and len >= 7 and current_hid_interface) {
            const ep_addr = device_buffer[i + 2];
            const attributes = device_buffer[i + 3];
            const max_packet = readLe16(device_buffer[0..total_len], i + 4);

            if ((ep_addr & ENDPOINT_DIR_IN) != 0 and
                (attributes & ENDPOINT_TYPE_MASK) == ENDPOINT_TYPE_INTERRUPT)
            {
                parsed.endpoint = ep_addr & 0x0F;
                if (max_packet > 0 and max_packet < 64) {
                    parsed.report_len = @truncate(max_packet);
                }
                parsed.found = true;
                return parsed;
            }
        }

        i += len;
    }

    return parsed;
}

pub fn enumerateDeviceOnPort(port: u8) ?UsbDevice {
    last_failed_step = 0;

    // 1. Read first 8 bytes of device descriptor from address 0.
    const setup1 = buildSetupPacket(0x80, REQ_GET_DESCRIPTOR, DESC_TYPE_DEVICE, 0, 8);
    if (!controlTransferRetry(0, &setup1, &device_buffer, 8, true)) {
        last_failed_step = 1;
        return null;
    }

    const addr = next_address;
    next_address += 1;

    // 2. Assign address.
    const setup2 = buildSetupPacket(0x00, REQ_SET_ADDRESS, addr, 0, 0);
    if (!controlTransferRetry(0, &setup2, null, 0, false)) {
        last_failed_step = 2;
        return null;
    }

    smallDelay(100000);

    // 3. Read full device descriptor from new address.
    const setup3 = buildSetupPacket(0x80, REQ_GET_DESCRIPTOR, DESC_TYPE_DEVICE, 0, 18);
    if (!controlTransferRetry(addr, &setup3, &device_buffer, 18, true)) {
        last_failed_step = 3;
        return null;
    }

    const desc: *DeviceDescriptor = @ptrCast(&device_buffer);

    // 4. Read first 9 bytes of configuration descriptor to get total length.
    const setup4 = buildSetupPacket(0x80, REQ_GET_DESCRIPTOR, DESC_TYPE_CONFIG, 0, 9);
    if (!controlTransferRetry(addr, &setup4, &device_buffer, 9, true)) {
        last_failed_step = 4;
        return null;
    }

    var total_len: u16 = readLe16(device_buffer[0..9], 2);
    if (total_len > device_buffer.len) total_len = device_buffer.len;
    if (total_len < 9) {
        last_failed_step = 5;
        return null;
    }

    // 5. Read full configuration descriptor.
    const setup5 = buildSetupPacket(0x80, REQ_GET_DESCRIPTOR, DESC_TYPE_CONFIG, 0, total_len);
    if (!controlTransferRetry(addr, &setup5, &device_buffer, total_len, true)) {
        last_failed_step = 6;
        return null;
    }

    const parsed = parseConfiguration(total_len);
    if (!parsed.found) {
        last_failed_step = 7;
        return null;
    }

    // 6. Set configuration 1.
    const setup6 = buildSetupPacket(0x00, REQ_SET_CONFIGURATION, 1, 0, 0);
    if (!controlTransferRetry(addr, &setup6, null, 0, false)) {
        last_failed_step = 8;
        return null;
    }

    smallDelay(50000);

    // 7. Force HID boot protocol on the HID interface.
    // bmRequestType = 0x21: Host-to-device, Class, Interface
    // wValue = 0 means boot protocol, wIndex = interface number.
    const setup7 = buildSetupPacket(0x21, REQ_SET_PROTOCOL, 0, parsed.interface_number, 0);
    _ = controlTransferRetry(addr, &setup7, null, 0, false);

    const dev = UsbDevice{
        .address = addr,
        .port = port,
        .device_type = parsed.device_type,
        .endpoint = parsed.endpoint,
        .max_packet_size = desc.max_packet_size,
        .report_len = parsed.report_len,
        .vendor_id = desc.vendor_id,
        .product_id = desc.product_id,
        .connected = true,
    };
    rememberDevice(dev);
    return dev;
}

pub fn enumerateDevice() ?UsbDevice {
    return enumerateDeviceOnPort(0);
}

pub const MouseReport = struct {
    left: bool,
    right: bool,
    middle: bool,
    dx: i8,
    dy: i8,
};

pub fn parseMouseReport(data: []const u8) ?MouseReport {
    if (data.len < 3) return null;
    return MouseReport{
        .left = (data[0] & 0x01) != 0,
        .right = (data[0] & 0x02) != 0,
        .middle = (data[0] & 0x04) != 0,
        .dx = @bitCast(data[1]),
        .dy = @bitCast(data[2]),
    };
}

pub const TabletReport = struct {
    left: bool,
    right: bool,
    middle: bool,
    x: u16,
    y: u16,
};

pub fn parseTabletReport(data: []const u8) ?TabletReport {
    if (data.len < 5) return null;
    // QEMU usb-tablet commonly reports: buttons, X lo, X hi, Y lo, Y hi, ...
    return TabletReport{
        .left = (data[0] & 0x01) != 0,
        .right = (data[0] & 0x02) != 0,
        .middle = (data[0] & 0x04) != 0,
        .x = @as(u16, data[1]) | (@as(u16, data[2]) << 8),
        .y = @as(u16, data[3]) | (@as(u16, data[4]) << 8),
    };
}

pub const KeyboardReport = struct {
    modifiers: u8,
    keycodes: [6]u8,
};

pub fn parseKeyboardReport(data: []const u8) ?KeyboardReport {
    if (data.len < 8) return null;
    var report = KeyboardReport{
        .modifiers = data[0],
        .keycodes = undefined,
    };
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        report.keycodes[i] = data[2 + i];
    }
    return report;
}

var poll_buffer: [16]u8 align(16) = undefined;

pub fn pollEndpoint(device_addr: u8, endpoint: u8, expected_len: u8) ?[]u8 {
    const wanted: u8 = if (expected_len > poll_buffer.len) poll_buffer.len else expected_len;
    const actual_len = uhci.interruptTransferIn(device_addr, endpoint, &poll_buffer, wanted) orelse return null;
    if (actual_len == 0) return null;
    const len: usize = @min(actual_len, poll_buffer.len);
    return poll_buffer[0..len];
}
