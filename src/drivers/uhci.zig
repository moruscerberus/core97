// uhci.zig - UHCI USB controller driver
// Fixed for low-speed HID devices and safer control/interrupt transfers.

const idt = @import("../arch/x86/idt.zig");
const pci = @import("pci.zig");

const REG_USBCMD: u16 = 0x00;
const REG_USBSTS: u16 = 0x02;
const REG_USBINTR: u16 = 0x04;
const REG_FRNUM: u16 = 0x06;
const REG_FRBASEADD: u16 = 0x08;
const REG_SOFMOD: u16 = 0x0C;
const REG_PORTSC1: u16 = 0x10;
const REG_PORTSC2: u16 = 0x12;

const USBCMD_RS: u16 = 0x0001;
const USBCMD_HCRESET: u16 = 0x0002;
const USBCMD_GRESET: u16 = 0x0004;

const PORT_CONNECT: u16 = 0x0001;
const PORT_ENABLE: u16 = 0x0004;
const PORT_RESET: u16 = 0x0200;
const PORT_LOW_SPEED: u16 = 0x0100;
const PORT_CHANGE_BITS: u16 = 0x000A; // CSC + PEC are write-1-to-clear

var io_base: u16 = 0;

fn reg16(offset: u16) u16 {
    return idt.inw(io_base + offset);
}

fn writeReg16(offset: u16, value: u16) void {
    idt.outw(io_base + offset, value);
}

fn writeReg32(offset: u16, value: u32) void {
    idt.outl(io_base + offset, value);
}

fn delay(loops: u32) void {
    var i: u32 = 0;
    while (i < loops) : (i += 1) asm volatile ("nop");
}

const TERMINATE: u32 = 0x1;

const QueueHead = extern struct {
    head_link: u32,
    element_link: u32,
};

const TransferDescriptor = extern struct {
    link_ptr: u32,
    ctrl_status: u32,
    token: u32,
    buffer_ptr: u32,
};

var frame_list: [1024]u32 align(4096) = undefined;
var qh: QueueHead align(16) = undefined;

// Static TDs. Do not put DMA descriptors on the stack.
var td_setup: TransferDescriptor align(16) = undefined;
var td_data: TransferDescriptor align(16) = undefined;
var td_status: TransferDescriptor align(16) = undefined;
var td_intr: TransferDescriptor align(16) = undefined;

const TD_STATUS_ACTIVE: u32 = 1 << 23;
const TD_STATUS_IOC: u32 = 1 << 24;
const TD_STATUS_LOW_SPEED: u32 = 1 << 26;
const TD_STATUS_ERROR_LIMIT_3: u32 = 3 << 27;
const TD_ERROR_MASK: u32 = 0x7E0000;

const PID_SETUP: u32 = 0x2D;
const PID_IN: u32 = 0x69;
const PID_OUT: u32 = 0xE1;

pub var initialized: bool = false;
pub var last_td_status: u32 = 0;
pub var last_usb_status: u16 = 0;

var device_low_speed: [128]bool = [_]bool{false} ** 128;
var endpoint_toggle: [128][16]bool = [_][16]bool{[_]bool{false} ** 16} ** 128;
var next_port_low_speed: bool = false;

fn tdFlags(device_addr: u8) u32 {
    var flags: u32 = TD_STATUS_ACTIVE | TD_STATUS_ERROR_LIMIT_3;
    if (device_addr < device_low_speed.len and device_low_speed[device_addr]) {
        flags |= TD_STATUS_LOW_SPEED;
    }
    return flags;
}

pub fn rememberAddressSpeed(device_addr: u8) void {
    if (device_addr < device_low_speed.len) {
        device_low_speed[device_addr] = next_port_low_speed;
    }
}

pub fn clearEndpointToggle(device_addr: u8, endpoint: u8) void {
    if (device_addr < endpoint_toggle.len and endpoint < 16) {
        endpoint_toggle[device_addr][endpoint] = false;
    }
}

pub fn init() bool {
    pci.scanForUhci();
    const dev = pci.uhci_device orelse return false;
    pci.enableIoAndBusMaster(dev);

    io_base = @truncate(dev.bar4 & 0xFFFC);

    writeReg16(REG_USBCMD, 0x0000);
    delay(10000);

    // Host-controller reset first, then global reset.
    writeReg16(REG_USBCMD, USBCMD_HCRESET);
    delay(50000);
    writeReg16(REG_USBCMD, 0x0000);
    delay(10000);

    writeReg16(REG_USBCMD, USBCMD_GRESET);
    delay(200000);
    writeReg16(REG_USBCMD, 0x0000);
    delay(50000);

    writeReg16(REG_USBSTS, 0xFFFF);

    qh.head_link = TERMINATE;
    qh.element_link = TERMINATE;

    const qh_addr: u32 = @as(u32, @truncate(@intFromPtr(&qh))) | 0x2;
    var i: usize = 0;
    while (i < 1024) : (i += 1) frame_list[i] = qh_addr;

    writeReg32(REG_FRBASEADD, @as(u32, @truncate(@intFromPtr(&frame_list))));
    writeReg16(REG_FRNUM, 0);
    writeReg16(REG_SOFMOD, 0x40);
    writeReg16(REG_USBINTR, 0x0000);
    writeReg16(REG_USBSTS, 0xFFFF);
    writeReg16(REG_USBCMD, USBCMD_RS);

    initialized = true;
    return true;
}

fn portReg(port: u8) u16 {
    return if (port == 0) REG_PORTSC1 else REG_PORTSC2;
}

fn cleanPortWriteValue(v: u16) u16 {
    // Never accidentally clear change bits while setting/clearing reset/enable.
    return v & ~PORT_CHANGE_BITS;
}

pub fn isDeviceConnected(port: u8) bool {
    return (reg16(portReg(port)) & PORT_CONNECT) != 0;
}

pub fn resetPort(port: u8) void {
    const r = portReg(port);

    // Clear change bits.
    writeReg16(r, reg16(r) | PORT_CHANGE_BITS);
    delay(50000);

    var s = cleanPortWriteValue(reg16(r));
    s |= PORT_RESET;
    writeReg16(r, s);
    delay(800000);

    s = cleanPortWriteValue(reg16(r));
    s &= ~PORT_RESET;
    writeReg16(r, s);
    delay(300000);

    s = cleanPortWriteValue(reg16(r));
    next_port_low_speed = (s & PORT_LOW_SPEED) != 0;

    s |= PORT_ENABLE;
    writeReg16(r, s);
    delay(200000);

    // Clear enable/connect change after reset.
    writeReg16(r, reg16(r) | PORT_CHANGE_BITS);
    delay(50000);
}

pub fn getPortStatus(port: u8) u16 {
    return reg16(portReg(port));
}

pub fn getUsbStatus() u16 {
    return reg16(REG_USBSTS);
}

fn buildToken(pid: u32, device_addr: u8, endpoint: u8, length: u16, data_toggle: bool) u32 {
    const len_field: u32 = if (length == 0) 0x7FF else @as(u32, length) - 1;
    const toggle_bit: u32 = if (data_toggle) (1 << 19) else 0;
    return pid |
        (@as(u32, device_addr) << 8) |
        (@as(u32, endpoint) << 15) |
        toggle_bit |
        (len_field << 21);
}

fn waitForTd(td: *volatile TransferDescriptor, timeout_start: u32) bool {
    var timeout = timeout_start;
    while (timeout > 0) : (timeout -= 1) {
        if ((td.ctrl_status & TD_STATUS_ACTIVE) == 0) return true;
    }
    return false;
}

pub fn controlTransfer(
    device_addr: u8,
    setup_packet: *const [8]u8,
    data_buffer: ?[*]u8,
    data_len: u16,
    is_in: bool,
) bool {
    writeReg16(REG_USBSTS, 0xFFFF);
    last_td_status = 0;

    const has_data = data_buffer != null and data_len > 0;

    td_status = TransferDescriptor{
        .link_ptr = TERMINATE,
        .ctrl_status = tdFlags(device_addr) | TD_STATUS_IOC,
        .token = buildToken(if (has_data and is_in) PID_OUT else PID_IN, device_addr, 0, 0, true),
        .buffer_ptr = 0,
    };

    if (has_data) {
        td_data = TransferDescriptor{
            .link_ptr = @as(u32, @truncate(@intFromPtr(&td_status))) | 0x4,
            .ctrl_status = tdFlags(device_addr),
            .token = buildToken(if (is_in) PID_IN else PID_OUT, device_addr, 0, data_len, true),
            .buffer_ptr = @as(u32, @truncate(@intFromPtr(data_buffer.?))),
        };
    }

    td_setup = TransferDescriptor{
        .link_ptr = if (has_data)
            (@as(u32, @truncate(@intFromPtr(&td_data))) | 0x4)
        else
            (@as(u32, @truncate(@intFromPtr(&td_status))) | 0x4),
        .ctrl_status = tdFlags(device_addr),
        .token = buildToken(PID_SETUP, device_addr, 0, 8, false),
        .buffer_ptr = @as(u32, @truncate(@intFromPtr(setup_packet))),
    };

    qh.element_link = @as(u32, @truncate(@intFromPtr(&td_setup)));

    const done = waitForTd(@as(*volatile TransferDescriptor, @ptrCast(&td_status)), 2_000_000);
    qh.element_link = TERMINATE;
    last_usb_status = reg16(REG_USBSTS);

    if (!done) return false;

    var errors: u32 = td_setup.ctrl_status & TD_ERROR_MASK;
    if (has_data) errors |= td_data.ctrl_status & TD_ERROR_MASK;
    errors |= td_status.ctrl_status & TD_ERROR_MASK;
    last_td_status = errors | td_setup.ctrl_status | td_status.ctrl_status;
    if (errors != 0) return false;

    return true;
}

pub fn interruptTransferIn(device_addr: u8, endpoint: u8, buffer: [*]u8, length: u16) ?u16 {
    if (endpoint >= 16) return null;

    writeReg16(REG_USBSTS, 0xFFFF);

    const toggle = if (device_addr < endpoint_toggle.len) endpoint_toggle[device_addr][endpoint] else false;

    td_intr = TransferDescriptor{
        .link_ptr = TERMINATE,
        .ctrl_status = tdFlags(device_addr) | TD_STATUS_IOC,
        .token = buildToken(PID_IN, device_addr, endpoint, length, toggle),
        .buffer_ptr = @as(u32, @truncate(@intFromPtr(buffer))),
    };

    qh.element_link = @as(u32, @truncate(@intFromPtr(&td_intr)));
    const done = waitForTd(@as(*volatile TransferDescriptor, @ptrCast(&td_intr)), 300_000);
    qh.element_link = TERMINATE;
    last_usb_status = reg16(REG_USBSTS);

    if (!done) return null;

    const errors = td_intr.ctrl_status & TD_ERROR_MASK;
    last_td_status = td_intr.ctrl_status;
    if (errors != 0) return null;

    if (device_addr < endpoint_toggle.len) endpoint_toggle[device_addr][endpoint] = !toggle;

    const actual_field = td_intr.ctrl_status & 0x7FF;
    if (actual_field == 0x7FF) return 0;
    return @truncate(actual_field + 1);
}
