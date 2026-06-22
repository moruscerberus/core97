// apps/device_manager.zig - Core97-style scrollable/collapsible Device Manager.

const fb = @import("../gui/framebuffer.zig");
const window = @import("../gui/window.zig");
const ui = @import("../gui/ui.zig");
const pci = @import("../drivers/pci.zig");
const memory = @import("../kernel/memory.zig");
const driver_registry = @import("../drivers/driver_registry.zig");
const guest = @import("../drivers/guest.zig");
const audio = @import("../drivers/audio.zig");
const cpu = @import("../drivers/cpu.zig");
const network = @import("../drivers/network.zig");
const display = @import("../drivers/display.zig");
const usb_hid = @import("../drivers/usb_hid.zig");
const input = @import("../drivers/input.zig");

const ROW_H: u32 = 18;
const MENU_H: u32 = 22;
const TOOL_H: u32 = 34;
const STATUS_H: u32 = 20;
const SCROLL_W: u32 = 16;

const Cat = enum {
    root,
    computer,
    processors,
    disk,
    display,
    keyboard,
    mouse,
    network,
    sound,
    usb,
    system,
    pci_system,
    storage_raw,
    display_raw,
    network_raw,
    multimedia_raw,
    serial_raw,
    bridge_raw,
    hid,
    other_raw,
};

const DeviceManager = struct {
    scroll: u32 = 0,
    selected: u32 = 0,
    exp_root: bool = true,
    exp_computer: bool = true,
    exp_processors: bool = true,
    exp_disk: bool = true,
    exp_display: bool = true,
    exp_keyboard: bool = true,
    exp_mouse: bool = true,
    exp_network: bool = true,
    exp_sound: bool = true,
    exp_usb: bool = true,
    exp_system: bool = true,
    exp_pci_system: bool = true,
    exp_storage_raw: bool = false,
    exp_display_raw: bool = false,
    exp_network_raw: bool = false,
    exp_multimedia_raw: bool = false,
    exp_serial_raw: bool = false,
    exp_bridge_raw: bool = true,
    exp_hid: bool = true,
    exp_other_raw: bool = false,

    fn hexDigit(n: u4) u8 {
        return if (n < 10) '0' + @as(u8, n) else 'A' + @as(u8, n - 10);
    }

    fn writeDec(buf: *[16]u8, value: u32) []const u8 {
        if (value == 0) {
            buf[0] = '0';
            return buf[0..1];
        }
        var tmp: [16]u8 = undefined;
        var n = value;
        var len: usize = 0;
        while (n > 0 and len < tmp.len) : (len += 1) {
            tmp[len] = '0' + @as(u8, @intCast(n % 10));
            n /= 10;
        }
        var i: usize = 0;
        while (i < len) : (i += 1) buf[i] = tmp[len - 1 - i];
        return buf[0..len];
    }

    fn appendText(buf: *[96]u8, p: *usize, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len and p.* < buf.len) : (i += 1) {
            buf[p.*] = s[i];
            p.* += 1;
        }
    }

    fn appendHex16(buf: *[96]u8, p: *usize, value: u16) void {
        appendText(buf, p, "0x");
        var i: u32 = 0;
        while (i < 4 and p.* < buf.len) : (i += 1) {
            const shift: u4 = @intCast((3 - i) * 4);
            buf[p.*] = hexDigit(@intCast((value >> shift) & 0xF));
            p.* += 1;
        }
    }

    fn makePciLabel(dev: pci.PciDevice, buf: *[96]u8) []const u8 {
        var p: usize = 0;
        appendText(buf, &p, deviceName(dev));
        appendText(buf, &p, "  (");
        appendHex16(buf, &p, dev.vendor_id);
        appendText(buf, &p, ":");
        appendHex16(buf, &p, dev.device_id);
        appendText(buf, &p, ", ");
        appendText(buf, &p, pci.className(dev.class_code, dev.subclass));
        appendText(buf, &p, ", bus ");
        var nbuf: [16]u8 = undefined;
        appendText(buf, &p, writeDec(&nbuf, @as(u32, dev.bus)));
        appendText(buf, &p, ")");
        return buf[0..p];
    }

    fn makeUsbLabel(dev: usb_hid.UsbDevice, buf: *[96]u8) []const u8 {
        var p: usize = 0;
        appendText(buf, &p, usb_hid.deviceTypeName(dev.device_type));
        appendText(buf, &p, "  (port ");
        var nbuf: [16]u8 = undefined;
        appendText(buf, &p, writeDec(&nbuf, @as(u32, dev.port)));
        appendText(buf, &p, ", addr ");
        appendText(buf, &p, writeDec(&nbuf, @as(u32, dev.address)));
        appendText(buf, &p, ", ep ");
        appendText(buf, &p, writeDec(&nbuf, @as(u32, dev.endpoint)));
        appendText(buf, &p, ")");
        return buf[0..p];
    }

    fn drawMenuBar(x: u32, y: u32, w: u32) void {
        fb.fillRect(x, y, w, MENU_H, fb.CORE97_GREY);
        fb.drawString(x + 8, y + 7, "File", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + 54, y + 7, "Action", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + 116, y + 7, "View", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.drawString(x + 166, y + 7, "Help", fb.CORE97_BLACK, fb.CORE97_GREY);
        fb.fillRect(x, y + MENU_H - 1, w, 1, fb.CORE97_DARK_GREY);
        fb.fillRect(x, y + MENU_H, w, 1, fb.CORE97_WHITE);
    }

    fn drawToolbarButton(x: u32, y: u32, kind: u8, enabled: bool) void {
        const ink = if (enabled) fb.CORE97_BLACK else fb.CORE97_DARK_GREY;
        const hovered = enabled and ui.hit(x, y, 22, 22);
        fb.fillRect(x, y, 22, 22, if (hovered) 0xD8E8FF else fb.CORE97_GREY);
        fb.draw3DBorder(x, y, 22, 22, true);
        switch (kind) {
            0 => { fb.fillRect(x + 6, y + 10, 10, 2, ink); fb.fillRect(x + 5, y + 9, 2, 4, ink); fb.putPixel(x + 4, y + 10, ink); fb.putPixel(x + 4, y + 11, ink); },
            1 => { fb.fillRect(x + 5, y + 10, 10, 2, ink); fb.fillRect(x + 15, y + 9, 2, 4, ink); fb.putPixel(x + 17, y + 10, ink); fb.putPixel(x + 17, y + 11, ink); },
            2 => { fb.fillRect(x + 6, y + 4, 10, 8, fb.CORE97_BLUE); fb.draw3DBorder(x + 5, y + 3, 12, 10, true); fb.fillRect(x + 9, y + 14, 4, 3, ink); fb.fillRect(x + 6, y + 17, 10, 2, ink); },
            3 => { fb.fillRect(x + 7, y + 4, 10, 14, fb.CORE97_WHITE); fb.draw3DBorder(x + 6, y + 3, 12, 16, false); fb.fillRect(x + 9, y + 7, 6, 1, fb.CORE97_BLUE); fb.fillRect(x + 9, y + 10, 6, 1, ink); fb.fillRect(x + 9, y + 13, 5, 1, ink); },
            else => { fb.fillRect(x + 5, y + 5, 12, 10, fb.CORE97_WHITE); fb.draw3DBorder(x + 4, y + 4, 14, 12, false); fb.fillRect(x + 9, y + 8, 5, 5, fb.CORE97_BLUE); },
        }
    }

    fn drawToolbar(x: u32, y: u32, w: u32) void {
        fb.fillRect(x, y, w, TOOL_H, fb.CORE97_GREY);
        fb.fillRect(x, y + TOOL_H - 1, w, 1, fb.CORE97_DARK_GREY);
        fb.fillRect(x, y + TOOL_H, w, 1, fb.CORE97_WHITE);
        drawToolbarButton(x + 10, y + 6, 0, false);
        drawToolbarButton(x + 38, y + 6, 1, false);
        fb.fillRect(x + 70, y + 5, 1, 24, fb.CORE97_DARK_GREY);
        fb.fillRect(x + 72, y + 5, 1, 24, fb.CORE97_WHITE);
        drawToolbarButton(x + 82, y + 6, 2, true);
        drawToolbarButton(x + 112, y + 6, 3, true);
        fb.fillRect(x + 144, y + 5, 1, 24, fb.CORE97_DARK_GREY);
        fb.fillRect(x + 146, y + 5, 1, 24, fb.CORE97_WHITE);
        drawToolbarButton(x + 156, y + 6, 4, true);
    }

    fn drawExpander(x: u32, y: u32, expanded: bool) void {
        fb.fillRect(x, y, 9, 9, fb.CORE97_WHITE);
        fb.draw3DBorder(x, y, 9, 9, false);
        fb.fillRect(x + 2, y + 4, 5, 1, fb.CORE97_BLACK);
        if (!expanded) fb.fillRect(x + 4, y + 2, 1, 5, fb.CORE97_BLACK);
    }

    fn drawIcon(x: u32, y: u32, kind: u8) void {
        switch (kind) {
            0 => { fb.fillRect(x + 2, y + 1, 12, 9, fb.CORE97_BLUE); fb.draw3DBorder(x + 1, y, 14, 11, true); fb.fillRect(x + 6, y + 12, 4, 2, fb.CORE97_DARK_GREY); fb.fillRect(x + 3, y + 14, 10, 2, fb.CORE97_DARK_GREY); },
            1 => { fb.fillRect(x + 3, y + 3, 10, 10, fb.CORE97_BLUE); fb.draw3DBorder(x + 2, y + 2, 12, 12, true); fb.fillRect(x + 5, y + 5, 6, 6, fb.CORE97_WHITE); },
            2 => { fb.fillRect(x + 1, y + 5, 15, 8, fb.CORE97_GREY); fb.draw3DBorder(x + 1, y + 5, 15, 8, true); fb.fillRect(x + 11, y + 9, 3, 2, fb.CORE97_DARK_GREY); },
            3 => { fb.fillRect(x + 2, y + 1, 12, 10, fb.CORE97_BLUE); fb.draw3DBorder(x + 1, y, 14, 12, true); fb.fillRect(x + 6, y + 13, 4, 2, fb.CORE97_DARK_GREY); },
            4 => { fb.fillRect(x + 1, y + 6, 15, 8, fb.CORE97_GREY); fb.draw3DBorder(x + 1, y + 6, 15, 8, true); fb.fillRect(x + 3, y + 8, 2, 1, fb.CORE97_BLACK); fb.fillRect(x + 6, y + 8, 2, 1, fb.CORE97_BLACK); fb.fillRect(x + 9, y + 8, 2, 1, fb.CORE97_BLACK); },
            5 => { fb.fillRect(x + 5, y + 1, 7, 12, fb.CORE97_WHITE); fb.draw3DBorder(x + 4, y, 9, 14, true); fb.fillRect(x + 8, y + 2, 1, 4, fb.CORE97_BLACK); },
            6 => { fb.fillRect(x + 1, y + 5, 15, 8, 0x00AA00); fb.draw3DBorder(x + 1, y + 5, 15, 8, true); fb.fillRect(x + 4, y + 8, 2, 2, fb.CORE97_BLACK); fb.fillRect(x + 8, y + 8, 2, 2, fb.CORE97_BLACK); fb.fillRect(x + 12, y + 8, 2, 2, fb.CORE97_BLACK); },
            7 => { fb.fillRect(x + 2, y + 4, 13, 8, 0x00AA00); fb.draw3DBorder(x + 1, y + 3, 15, 10, true); fb.fillRect(x + 4, y + 6, 2, 3, fb.CORE97_BLACK); fb.fillRect(x + 8, y + 6, 2, 3, fb.CORE97_BLACK); fb.fillRect(x + 12, y + 6, 2, 3, fb.CORE97_BLACK); },
            8 => { fb.fillRect(x + 3, y + 5, 8, 8, fb.CORE97_GREY); fb.draw3DBorder(x + 2, y + 4, 10, 10, true); fb.fillRect(x + 12, y + 7, 3, 4, fb.CORE97_DARK_GREY); },
            9 => { fb.fillRect(x + 2, y + 2, 12, 12, fb.CORE97_GREY); fb.draw3DBorder(x + 1, y + 1, 14, 14, true); fb.fillRect(x + 5, y + 5, 6, 6, 0xFFFF00); },
            else => { fb.fillRect(x + 3, y + 2, 10, 12, fb.CORE97_GREY); fb.draw3DBorder(x + 2, y + 1, 12, 14, true); },
        }
    }

    fn drawTreeLineH(left: u32, y: u32, right: u32) void {
        var xx = left;
        while (xx < right) : (xx += 2) fb.putPixel(xx, y, fb.CORE97_DARK_GREY);
    }

    fn drawRow(self: *DeviceManager, base_x: u32, base_y: u32, indent: u32, screen_row: u32, logical_row: u32, text: []const u8, icon: u8, expanded: bool, has_children: bool) void {
        const yy = base_y + screen_row * ROW_H;
        const tx = base_x + indent * 22;
        const selected = logical_row == self.selected;
        var tw = @as(u32, @intCast(text.len)) * 8 + 4;
        if (tw > 360) tw = 360;
        const hovered = ui.hit(tx + 42, yy + 2, tw, 14);
        const bg = if (selected) fb.CORE97_BLUE else if (hovered) 0xD8E8FF else fb.CORE97_WHITE;
        const fg = if (selected) fb.CORE97_WHITE else fb.CORE97_BLACK;
        if (selected or hovered) fb.fillRect(tx + 42, yy + 2, tw, 14, bg);
        if (has_children) drawExpander(tx, yy + 4, expanded);
        if (indent > 0) drawTreeLineH(tx + 9, yy + 8, tx + 20);
        drawIcon(tx + 22, yy + 1, icon);
        fb.drawString(tx + 44, yy + 5, text, fg, bg);
    }

    fn vendorName(vendor_id: u16) []const u8 {
        return switch (vendor_id) {
            0x8086 => "Intel",
            0x10EC => "Realtek",
            0x1022 => "AMD",
            0x1002 => "AMD/ATI",
            0x10DE => "NVIDIA",
            0x1234 => "QEMU/Bochs",
            0x1AF4 => "VirtIO",
            0x80EE => "VirtualBox",
            0x15AD => "VMware",
            0x1B36 => "QEMU",
            else => "PCI",
        };
    }

    fn deviceName(dev: pci.PciDevice) []const u8 {
        if (network.isNetwork(dev)) return network.deviceName(dev);
        if (display.isDisplay(dev)) return display.deviceName(dev);
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x1237) return "Intel 440FX PCI Host Bridge";
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x7000) return "Intel PIIX3 ISA Bridge";
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x7010) return "Intel PIIX3 IDE Controller";
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x7113) return "Intel PIIX4 Power Management Controller";
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x2922) return "Intel ICH9 SATA AHCI Controller";
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x2668) return "Intel HD Audio Controller";
        if (dev.vendor_id == 0x8086 and dev.device_id == 0x293E) return "Intel ICH9 HD Audio Controller";
        if (dev.vendor_id == 0x1022 and dev.class_code == 0x06) return "AMD Host/PCI Bridge";
        if (dev.vendor_id == 0x1022 and dev.class_code == 0x13) return "AMD Starship/Matisse System Device";
        if (dev.vendor_id == 0x1022 and dev.class_code == 0x0C) return "AMD USB Controller";
        if (dev.vendor_id == 0x1022 and dev.class_code == 0x04) return "AMD HD Audio Controller";
        if (dev.vendor_id == 0x1AF4 and dev.device_id >= 0x1000 and dev.device_id <= 0x107F) return "VirtIO PCI Device";
        if (dev.class_code == 0x01 and dev.subclass == 0x06) return "Standard SATA AHCI Controller";
        if (dev.class_code == 0x01 and dev.subclass == 0x08) return "Standard NVMe Controller";
        if (dev.class_code == 0x04) return "PCI Multimedia Device";
        if (dev.class_code == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x30) return "USB xHCI Controller";
        if (dev.class_code == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x20) return "USB EHCI Controller";
        if (dev.class_code == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x10) return "USB OHCI Controller";
        if (dev.class_code == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x00) return "USB UHCI Controller";
        if (dev.class_code == 0x06) return "PCI Bridge Device";
        return switch (dev.class_code) {
            0x00 => "Generic Legacy PCI Device",
            0x01 => "Generic Storage Controller",
            0x02 => "Generic Network Adapter",
            0x03 => "Generic Display Adapter",
            0x04 => "Generic Multimedia Controller",
            0x05 => "Generic Memory Controller",
            0x06 => "Generic PCI Bridge",
            0x07 => "Generic Communication Controller",
            0x08 => "Generic System Peripheral",
            0x09 => "Generic Input Controller",
            0x0B => "Generic CPU Device",
            0x0C => "Generic Serial Bus Controller",
            0x0D => "Generic Wireless Controller",
            else => "Unknown PCI Device",
        };
    }

    fn findDevice(class_code: u8, subclass: u8, vendor_id: u16, device_id: u16) ?pci.PciDevice {
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            const dev = pci.devices[i];
            if (vendor_id != 0 and dev.vendor_id == vendor_id and dev.device_id == device_id) return dev;
            if (dev.class_code == class_code and dev.subclass == subclass) return dev;
        }
        return null;
    }

    fn hasClass(class_code: u8) bool {
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            if (pci.devices[i].class_code == class_code) return true;
        }
        return false;
    }

    fn categoryExpanded(self: *DeviceManager, cat: Cat) bool {
        return switch (cat) {
            .root => self.exp_root,
            .computer => self.exp_computer,
            .processors => self.exp_processors,
            .disk => self.exp_disk,
            .display => self.exp_display,
            .keyboard => self.exp_keyboard,
            .mouse => self.exp_mouse,
            .network => self.exp_network,
            .sound => self.exp_sound,
            .usb => self.exp_usb,
            .system => self.exp_system,
            .pci_system => self.exp_pci_system,
            .storage_raw => self.exp_storage_raw,
            .display_raw => self.exp_display_raw,
            .network_raw => self.exp_network_raw,
            .multimedia_raw => self.exp_multimedia_raw,
            .serial_raw => self.exp_serial_raw,
            .bridge_raw => self.exp_bridge_raw,
            .hid => self.exp_hid,
            .other_raw => self.exp_other_raw,
        };
    }

    fn toggleCategory(self: *DeviceManager, cat: Cat) void {
        switch (cat) {
            .root => self.exp_root = !self.exp_root,
            .computer => self.exp_computer = !self.exp_computer,
            .processors => self.exp_processors = !self.exp_processors,
            .disk => self.exp_disk = !self.exp_disk,
            .display => self.exp_display = !self.exp_display,
            .keyboard => self.exp_keyboard = !self.exp_keyboard,
            .mouse => self.exp_mouse = !self.exp_mouse,
            .network => self.exp_network = !self.exp_network,
            .sound => self.exp_sound = !self.exp_sound,
            .usb => self.exp_usb = !self.exp_usb,
            .system => self.exp_system = !self.exp_system,
            .pci_system => self.exp_pci_system = !self.exp_pci_system,
            .storage_raw => self.exp_storage_raw = !self.exp_storage_raw,
            .display_raw => self.exp_display_raw = !self.exp_display_raw,
            .network_raw => self.exp_network_raw = !self.exp_network_raw,
            .multimedia_raw => self.exp_multimedia_raw = !self.exp_multimedia_raw,
            .serial_raw => self.exp_serial_raw = !self.exp_serial_raw,
            .bridge_raw => self.exp_bridge_raw = !self.exp_bridge_raw,
            .hid => self.exp_hid = !self.exp_hid,
            .other_raw => self.exp_other_raw = !self.exp_other_raw,
        }
    }

    fn maybeDrawRow(self: *DeviceManager, logical: *u32, visible: *u32, max_visible: u32, base_x: u32, base_y: u32, indent: u32, text: []const u8, icon: u8, cat: Cat, has_children: bool) void {
        if (logical.* >= self.scroll and visible.* < max_visible) {
            self.drawRow(base_x, base_y, indent, visible.*, logical.*, text, icon, self.categoryExpanded(cat), has_children);
            visible.* += 1;
        }
        logical.* += 1;
    }

    fn maybeDrawLeaf(self: *DeviceManager, logical: *u32, visible: *u32, max_visible: u32, base_x: u32, base_y: u32, indent: u32, text: []const u8, icon: u8) void {
        if (logical.* >= self.scroll and visible.* < max_visible) {
            self.drawRow(base_x, base_y, indent, visible.*, logical.*, text, icon, false, false);
            visible.* += 1;
        }
        logical.* += 1;
    }

    fn emitPciClass(self: *DeviceManager, logical: *u32, visible: *u32, max_visible: u32, base_x: u32, base_y: u32, class_code: u8, indent: u32, icon: u8) void {
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            const dev = pci.devices[i];
            if (dev.class_code != class_code) continue;
            var label: [96]u8 = undefined;
            self.maybeDrawLeaf(logical, visible, max_visible, base_x, base_y, indent, makePciLabel(dev, &label), icon);
        }
    }

    fn emitOtherPci(self: *DeviceManager, logical: *u32, visible: *u32, max_visible: u32, base_x: u32, base_y: u32, indent: u32) void {
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            const dev = pci.devices[i];
            var label: [96]u8 = undefined;
            self.maybeDrawLeaf(logical, visible, max_visible, base_x, base_y, indent, makePciLabel(dev, &label), 1);
        }
    }

    fn emitUsbHid(self: *DeviceManager, logical: *u32, visible: *u32, max_visible: u32, base_x: u32, base_y: u32, indent: u32, filter: usb_hid.UsbDeviceType, icon: u8) u32 {
        var n: u32 = 0;
        var idx: usize = 0;
        while (idx < usb_hid.device_count) : (idx += 1) {
            const dev = usb_hid.devices[idx];
            if (filter != .unknown and dev.device_type != filter) continue;
            var label: [96]u8 = undefined;
            self.maybeDrawLeaf(logical, visible, max_visible, base_x, base_y, indent, makeUsbLabel(dev, &label), icon);
            n += 1;
        }
        return n;
    }

    fn renderTree(self: *DeviceManager, base_x: u32, base_y: u32, max_visible: u32) u32 {
        var logical: u32 = 0;
        var visible: u32 = 0;
        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 0, "CORE97OS", 0, .root, true);
        if (!self.exp_root) return logical;

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Computer", 1, .computer, true);
        if (self.exp_computer) {
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "ACPI Computer", 1);
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "Core97 Memory Manager", 7);
        }

        cpu.detect();
        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Processors", 1, .processors, true);
        if (self.exp_processors) self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, cpu.name(), 1);

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Disk drives", 2, .disk, true);
        if (self.exp_disk) {
            if (hasClass(0x01)) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x01, 2, 2) else self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "No disk controller loaded", 2);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Display adapters", 3, .display, true);
        if (self.exp_display) {
            if (hasClass(0x03)) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x03, 2, 3) else self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "Basic Display Adapter", 3);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Keyboards", 4, .keyboard, true);
        if (self.exp_keyboard) {
            if (usb_hid.device_count > 0) _ = self.emitUsbHid(&logical, &visible, max_visible, base_x, base_y, 2, .keyboard, 4);
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, if (input.keyboard_active == .usb_hid or input.keyboard_active == .mixed) "Standard PS/2 Keyboard (fallback)" else "Standard PS/2 Keyboard (active fallback)", 4);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Mice and other pointing devices", 5, .mouse, true);
        if (self.exp_mouse) {
            if (usb_hid.device_count > 0) {
                _ = self.emitUsbHid(&logical, &visible, max_visible, base_x, base_y, 2, .mouse, 5);
                _ = self.emitUsbHid(&logical, &visible, max_visible, base_x, base_y, 2, .tablet, 5);
            }
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, if (input.mouse_active == .usb_hid or input.mouse_active == .mixed) "PS/2 Compatible Mouse (fallback)" else "PS/2 Compatible Mouse (active fallback)", 5);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Human Interface Devices", 5, .hid, true);
        if (self.exp_hid) {
            if (usb_hid.device_count == 0) {
                self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "No USB HID devices enumerated", 5);
            } else {
                _ = self.emitUsbHid(&logical, &visible, max_visible, base_x, base_y, 2, .unknown, 5);
            }
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Network adapters", 6, .network, true);
        if (self.exp_network) {
            var found_net = false;
            var i: usize = 0;
            while (i < pci.device_count) : (i += 1) {
                const d = pci.devices[i];
                if (d.class_code == 0x02) {
                    found_net = true;
                    self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, deviceName(d), 6);
                }
            }
            if (!found_net) self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "No network adapter detected", 6);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Sound, video and game controllers", 8, .sound, true);
        if (self.exp_sound) {
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "PC Speaker Audio Device", 8);
            self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x04, 2, 8);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "Universal Serial Bus controllers", 9, .usb, true);
        if (self.exp_usb) {
            if (hasClass(0x0C)) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x0C, 2, 9) else self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "No USB controller detected", 9);
            if (usb_hid.device_count > 0) _ = self.emitUsbHid(&logical, &visible, max_visible, base_x, base_y, 2, .unknown, 5);
        }

        guest.detect();
        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "System devices", 1, .system, true);
        if (self.exp_system) {
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, if (guest.is_qemu) "Core97 Guest Additions for QEMU" else "Core97 Guest Additions Stub", 1);
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "System timer", 1);
            self.maybeDrawLeaf(&logical, &visible, max_visible, base_x, base_y, 2, "Programmable interrupt controller", 1);
        }

        self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 1, "PCI system devices", 1, .pci_system, true);
        if (self.exp_pci_system) {
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "Storage controllers", 2, .storage_raw, true);
            if (self.exp_storage_raw) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x01, 3, 2);
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "Display controllers", 3, .display_raw, true);
            if (self.exp_display_raw) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x03, 3, 3);
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "Network controllers", 6, .network_raw, true);
            if (self.exp_network_raw) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x02, 3, 6);
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "Multimedia controllers", 8, .multimedia_raw, true);
            if (self.exp_multimedia_raw) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x04, 3, 8);
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "Serial bus controllers", 9, .serial_raw, true);
            if (self.exp_serial_raw) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x0C, 3, 9);
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "Bridge devices", 1, .bridge_raw, true);
            if (self.exp_bridge_raw) self.emitPciClass(&logical, &visible, max_visible, base_x, base_y, 0x06, 3, 1);
            self.maybeDrawRow(&logical, &visible, max_visible, base_x, base_y, 2, "All detected PCI devices", 1, .other_raw, true);
            if (self.exp_other_raw) self.emitOtherPci(&logical, &visible, max_visible, base_x, base_y, 3);
        }

        return logical;
    }

    fn hitRowCategory(self: *DeviceManager, target: u32, row: *u32) ?Cat {
        if (row.* == target) return .root;
        row.* += 1;
        if (!self.exp_root) return null;
        if (row.* == target) return .computer;
        row.* += 1;
        if (self.exp_computer) row.* += 2;
        if (row.* == target) return .processors;
        row.* += 1;
        if (self.exp_processors) row.* += 1;
        if (row.* == target) return .disk;
        row.* += 1;
        if (self.exp_disk) {
            var disk_count: u32 = 0;
            var i: usize = 0;
            while (i < pci.device_count) : (i += 1) { if (pci.devices[i].class_code == 0x01) disk_count += 1; }
            if (disk_count == 0) disk_count = 1;
            row.* += disk_count;
        }
        if (row.* == target) return .display;
        row.* += 1;
        if (self.exp_display) { const dc = countClass(0x03); if (dc == 0) { row.* += 1; } else { row.* += dc; } }
        if (row.* == target) return .keyboard;
        row.* += 1;
        if (self.exp_keyboard) row.* += 1 + countUsbType(.keyboard);
        if (row.* == target) return .mouse;
        row.* += 1;
        if (self.exp_mouse) row.* += 1 + countUsbType(.mouse) + countUsbType(.tablet);
        if (row.* == target) return .hid;
        row.* += 1;
        if (self.exp_hid) { if (usb_hid.device_count == 0) { row.* += 1; } else { row.* += @intCast(usb_hid.device_count); } }
        if (row.* == target) return .network;
        row.* += 1;
        if (self.exp_network) {
            var net_count: u32 = 0;
            var idx2: usize = 0;
            while (idx2 < pci.device_count) : (idx2 += 1) { if (pci.devices[idx2].class_code == 0x02) net_count += 1; }
            if (net_count == 0) net_count = 1;
            row.* += net_count;
        }
        if (row.* == target) return .sound;
        row.* += 1;
        if (self.exp_sound) {
            row.* += 1;
            var mc: u32 = 0; var im: usize = 0;
            while (im < pci.device_count) : (im += 1) { if (pci.devices[im].class_code == 0x04) mc += 1; }
            row.* += mc;
        }
        if (row.* == target) return .usb;
        row.* += 1;
        if (self.exp_usb) {
            var uc: u32 = 0; var iu: usize = 0;
            while (iu < pci.device_count) : (iu += 1) { if (pci.devices[iu].class_code == 0x0C) uc += 1; }
            if (uc == 0) uc = 1;
            row.* += uc + @as(u32, @intCast(usb_hid.device_count));
        }
        if (row.* == target) return .system;
        row.* += 1;
        if (self.exp_system) row.* += 3;
        if (row.* == target) return .pci_system;
        row.* += 1;
        if (!self.exp_pci_system) return null;
        if (row.* == target) return .storage_raw; row.* += 1; if (self.exp_storage_raw) row.* += countClass(0x01);
        if (row.* == target) return .display_raw; row.* += 1; if (self.exp_display_raw) row.* += countClass(0x03);
        if (row.* == target) return .network_raw; row.* += 1; if (self.exp_network_raw) row.* += countClass(0x02);
        if (row.* == target) return .multimedia_raw; row.* += 1; if (self.exp_multimedia_raw) row.* += countClass(0x04);
        if (row.* == target) return .serial_raw; row.* += 1; if (self.exp_serial_raw) row.* += countClass(0x0C);
        if (row.* == target) return .bridge_raw; row.* += 1; if (self.exp_bridge_raw) row.* += countClass(0x06);
        if (row.* == target) return .other_raw; row.* += 1; if (self.exp_other_raw) row.* += @intCast(pci.device_count);
        return null;
    }

    fn countUsbType(t: usb_hid.UsbDeviceType) u32 {
        var n: u32 = 0;
        var idx: usize = 0;
        while (idx < usb_hid.device_count) : (idx += 1) {
            if (usb_hid.devices[idx].device_type == t) n += 1;
        }
        return n;
    }

    fn countClass(class_code: u8) u32 {
        var n: u32 = 0;
        var i: usize = 0;
        while (i < pci.device_count) : (i += 1) {
            if (pci.devices[i].class_code == class_code) n += 1;
        }
        return n;
    }

    fn totalRows(self: *DeviceManager) u32 {
        const old_scroll = self.scroll;
        self.scroll = 0xFFFFFFFF;
        const total = self.renderTree(0, 0, 0);
        self.scroll = old_scroll;
        return total;
    }

    fn drawScrollbar(self: *DeviceManager, x: u32, y: u32, h: u32, total: u32, visible: u32) void {
        fb.fillRect(x, y, SCROLL_W, h, fb.CORE97_GREY);
        fb.draw3DBorder(x, y, SCROLL_W, h, false);
        fb.draw3DBorder(x + 1, y + 1, SCROLL_W - 2, 14, true);
        fb.fillRect(x + 5, y + 6, 6, 2, fb.CORE97_BLACK);
        fb.putPixel(x + 4, y + 7, fb.CORE97_BLACK);
        fb.putPixel(x + 11, y + 7, fb.CORE97_BLACK);
        fb.draw3DBorder(x + 1, y + h - 15, SCROLL_W - 2, 14, true);
        fb.fillRect(x + 5, y + h - 8, 6, 2, fb.CORE97_BLACK);
        fb.putPixel(x + 4, y + h - 9, fb.CORE97_BLACK);
        fb.putPixel(x + 11, y + h - 9, fb.CORE97_BLACK);
        if (total <= visible or h < 44) return;
        const track_y = y + 16;
        const track_h = h - 32;
        var thumb_h = (track_h * visible) / total;
        if (thumb_h < 12) thumb_h = 12;
        const max_scroll = total - visible;
        const thumb_y = track_y + ((track_h - thumb_h) * self.scroll) / max_scroll;
        fb.fillRect(x + 2, thumb_y, SCROLL_W - 4, thumb_h, fb.CORE97_GREY);
        fb.draw3DBorder(x + 2, thumb_y, SCROLL_W - 4, thumb_h, true);
    }

    pub fn title(_: *DeviceManager) []const u8 { return "Device Manager"; }
    pub fn titleDetail(_: *DeviceManager) []const u8 { return ""; }

    pub fn draw(self: *DeviceManager, x: u32, y: u32, w: u32, h: u32) void {
        driver_registry.refresh();
        audio.detect();
        guest.detect();
        fb.fillRect(x, y, w, h, fb.CORE97_GREY);
        drawMenuBar(x, y, w);
        drawToolbar(x, y + MENU_H + 2, w);

        const tree_x = x + 6;
        const tree_y = y + MENU_H + TOOL_H + 8;
        const status_y = if (h > STATUS_H + 6) y + h - STATUS_H - 4 else y + h - 4;
        const tree_h = if (status_y > tree_y + 4) status_y - tree_y - 4 else 1;
        const tree_w = if (w > 12) w - 12 else 1;
        const list_w = if (tree_w > SCROLL_W) tree_w - SCROLL_W else tree_w;
        fb.fillRect(tree_x, tree_y, tree_w, tree_h, fb.CORE97_WHITE);
        fb.draw3DBorder(tree_x, tree_y, tree_w, tree_h, false);

        const base_x = tree_x + 10;
        const base_y = tree_y + 4;
        const visible_rows = if (tree_h > 8) (tree_h - 8) / ROW_H else 0;
        var total = self.renderTree(base_x, base_y, visible_rows);
        if (total == 0) total = 1;
        if (visible_rows > 0 and self.scroll + visible_rows > total) {
            if (total > visible_rows) self.scroll = total - visible_rows else self.scroll = 0;
        }
        drawScrollbar(self, tree_x + list_w, tree_y, tree_h, total, visible_rows);

        if (h > 92) {
            fb.fillRect(x + 6, status_y, w - 12, STATUS_H, fb.CORE97_GREY);
            fb.draw3DBorder(x + 6, status_y, w - 12, STATUS_H, false);
            const st = memory.stats();
            var nbuf: [16]u8 = undefined;
            fb.drawString(x + 12, status_y + 6, "Devices:", fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 78, status_y + 6, writeDec(&nbuf, @intCast(pci.device_count)), fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 130, status_y + 6, "Free KB:", fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 194, status_y + 6, writeDec(&nbuf, st.free_kib), fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 282, status_y + 6, "Scale:", fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 332, status_y + 6, writeDec(&nbuf, guest.scale_percent), fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 360, status_y + 6, "%", fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 390, status_y + 6, "NIC:", fb.CORE97_BLACK, fb.CORE97_GREY);
            fb.drawString(x + 426, status_y + 6, if (hasClass(0x02)) "detected" else "missing", fb.CORE97_BLACK, fb.CORE97_GREY);
        }
    }

    pub fn onMouseDown(self: *DeviceManager, mx: i32, my: i32, button: window.MouseButton, x: u32, y: u32, w: u32, h: u32) window.AppAction {
        _ = button;
        const ux: u32 = if (mx < 0) 0 else @intCast(mx);
        const uy: u32 = if (my < 0) 0 else @intCast(my);
        const tree_x = x + 6;
        const tree_y = y + MENU_H + TOOL_H + 8;
        const status_y = if (h > STATUS_H + 6) y + h - STATUS_H - 4 else y + h - 4;
        const tree_h = if (status_y > tree_y + 4) status_y - tree_y - 4 else 1;
        const tree_w = if (w > 12) w - 12 else 1;
        const list_w = if (tree_w > SCROLL_W) tree_w - SCROLL_W else tree_w;
        const visible_rows = if (tree_h > 8) (tree_h - 8) / ROW_H else 0;
        const total = self.totalRows();

        if (ux >= tree_x + list_w and ux < tree_x + tree_w and uy >= tree_y and uy < tree_y + tree_h) {
            if (uy < tree_y + 18) {
                if (self.scroll > 0) self.scroll -= 1;
            } else if (uy >= tree_y + tree_h - 18) {
                if (self.scroll + visible_rows < total) self.scroll += 1;
            } else {
                const mid = tree_y + tree_h / 2;
                if (uy < mid) {
                    if (self.scroll > visible_rows) self.scroll -= visible_rows else self.scroll = 0;
                } else {
                    if (self.scroll + visible_rows < total) self.scroll += visible_rows;
                }
            }
            return .none;
        }

        if (ux >= tree_x and ux < tree_x + list_w and uy >= tree_y + 4 and uy < tree_y + tree_h) {
            const clicked = self.scroll + ((uy - (tree_y + 4)) / ROW_H);
            self.selected = clicked;
            var row: u32 = 0;
            if (self.hitRowCategory(clicked, &row)) |cat| self.toggleCategory(cat);
        }
        return .none;
    }

    pub fn onMouseDrag(_: *DeviceManager, _: i32, _: i32, _: u32, _: u32, _: u32, _: u32) void {}
    pub fn onMouseUp(_: *DeviceManager) void {}
    pub fn onKeyAscii(self: *DeviceManager, ascii: u8) void {
        if (ascii == '+') {
            var row: u32 = 0;
            if (self.hitRowCategory(self.selected, &row)) |cat| { if (!self.categoryExpanded(cat)) self.toggleCategory(cat); }
        } else if (ascii == '-') {
            var row2: u32 = 0;
            if (self.hitRowCategory(self.selected, &row2)) |cat| { if (self.categoryExpanded(cat)) self.toggleCategory(cat); }
        }
    }
    pub fn onKeyUsb(self: *DeviceManager, code: u8, _: u8, _: u32) bool {
        const total = self.totalRows();
        if (code == 0x51) { // Down
            if (self.selected + 1 < total) self.selected += 1;
            if (self.selected >= self.scroll + 8) self.scroll += 1;
            return true;
        }
        if (code == 0x52) { // Up
            if (self.selected > 0) self.selected -= 1;
            if (self.selected < self.scroll and self.scroll > 0) self.scroll -= 1;
            return true;
        }
        if (code == 0x4E) { // PageDown
            self.scroll += 8;
            if (self.selected + 8 < total) self.selected += 8;
            return true;
        }
        if (code == 0x4B) { // PageUp
            if (self.scroll > 8) self.scroll -= 8 else self.scroll = 0;
            if (self.selected > 8) self.selected -= 8 else self.selected = 0;
            return true;
        }
        if (code == 0x28) { // Enter toggles selected category
            var row: u32 = 0;
            if (self.hitRowCategory(self.selected, &row)) |cat| self.toggleCategory(cat);
            return true;
        }
        return false;
    }
    pub fn hasModalCapture(_: *DeviceManager) bool { return false; }
};

var instance = DeviceManager{};
pub fn asApp() window.App {
    return window.appFrom(DeviceManager, &instance);
}
