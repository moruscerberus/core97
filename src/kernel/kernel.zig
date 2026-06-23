// kernel/kernel.zig - entry point and main loop.
// Wires together arch/drivers/gui/apps. Owns nothing about pixels, text
// editing, or window position itself - just orchestration.

const idt = @import("../arch/x86/idt.zig");
const paging = @import("../arch/x86/paging.zig");
const gdt = @import("../arch/x86/gdt.zig");
const multiboot = @import("multiboot.zig");
const fault = @import("fault.zig");
const fb = @import("../gui/framebuffer.zig");
const desktop = @import("../gui/desktop.zig");
const notepad = @import("../apps/notepad.zig");
const keyboard = @import("../drivers/keyboard.zig");
const mouse = @import("../drivers/mouse.zig");
const pci = @import("../drivers/pci.zig");
const uhci = @import("../drivers/uhci.zig");
const usb_hid = @import("../drivers/usb_hid.zig");
const pit = @import("../drivers/pit.zig");
const fs = @import("../fs/vfs.zig");
const memory = @import("memory.zig");
const driver_registry = @import("../drivers/driver_registry.zig");
const network = @import("../drivers/network.zig");
const usb = @import("../drivers/usb.zig");
const guest = @import("../drivers/guest.zig");
const input = @import("../drivers/input.zig");
const process = @import("process.zig");
const scheduler = @import("scheduler.zig");
const user_demo = @import("../userland/user_demo.zig");
const attack_demo = @import("../userland/attack_demo.zig");

// --- CPU exception handling ---
// Called from interrupts.asm when a CPU exception (0-19) occurs.
// interrupts.asm has already saved all GP registers (pusha) and pulled
// out the real EIP/error code from the hardware frame - we receive them
// as plain arguments instead of digging through the stack here. Rendering
// the actual error screen is handled by kernel/fault.zig, which doesn't
// depend on any GUI state (windows, mouse, etc.) since that might be
// exactly what's broken.
pub export fn exception_handler(exception_num: u32, error_code: u32, eip: u32, regs: *const fault.Registers) callconv(.C) void {
    fault.renderExceptionScreen(exception_num, error_code, eip, regs);
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    fault.renderPanicScreen(msg);
    while (true) {
        asm volatile ("hlt");
    }
}

fn tinyDelay(loops: u32) void {
    var i: u32 = 0;
    while (i < loops) : (i += 1) {
        asm volatile ("nop");
    }
}

var previous_usb_keys: [6]u8 = [_]u8{0} ** 6;
var previous_usb_modifiers: u8 = 0;

fn pollUsbMouse(dev: usb_hid.UsbDevice) void {
    if (dev.device_type != .mouse) return;

    if (usb_hid.pollEndpoint(dev.address, dev.endpoint, dev.report_len)) |report_data| {
        if (usb_hid.parseMouseReport(report_data)) |report| {
            if (report.dx == 0 and report.dy == 0 and mouse.left_button == report.left and mouse.right_button == report.right) return;

            mouse.mouse_x += report.dx;
            mouse.mouse_y += report.dy;

            if (mouse.mouse_x < 0) mouse.mouse_x = 0;
            if (mouse.mouse_y < 0) mouse.mouse_y = 0;
            if (mouse.mouse_x >= mouse.screen_width) mouse.mouse_x = mouse.screen_width - 1;
            if (mouse.mouse_y >= mouse.screen_height) mouse.mouse_y = mouse.screen_height - 1;

            mouse.left_button = report.left;
            mouse.right_button = report.right;
            input.noteUsbMouse();
            desktop.onMouseUpdate();
        }
    }
}

fn pollUsbTablet(dev: usb_hid.UsbDevice) void {
    if (dev.device_type != .tablet) return;

    if (usb_hid.pollEndpoint(dev.address, dev.endpoint, dev.report_len)) |report_data| {
        if (usb_hid.parseTabletReport(report_data)) |report| {
            const new_x: i32 = @intCast((@as(u32, report.x) * @as(u32, @intCast(mouse.screen_width))) / 32767);
            const new_y: i32 = @intCast((@as(u32, report.y) * @as(u32, @intCast(mouse.screen_height))) / 32767);
            if (new_x == mouse.mouse_x and new_y == mouse.mouse_y and mouse.left_button == report.left and mouse.right_button == report.right) return;

            mouse.mouse_x = new_x;
            mouse.mouse_y = new_y;
            if (mouse.mouse_x < 0) mouse.mouse_x = 0;
            if (mouse.mouse_y < 0) mouse.mouse_y = 0;
            if (mouse.mouse_x >= mouse.screen_width) mouse.mouse_x = mouse.screen_width - 1;
            if (mouse.mouse_y >= mouse.screen_height) mouse.mouse_y = mouse.screen_height - 1;
            mouse.left_button = report.left;
            mouse.right_button = report.right;
            input.noteUsbTablet();
            desktop.onMouseUpdate();
        }
    }
}

fn pollUsbKeyboard(dev: usb_hid.UsbDevice) void {
    if (dev.device_type != .keyboard) return;
    desktop.usb_keyboard_present = true;
    input.noteUsbKeyboard();
    if (usb_hid.pollEndpoint(dev.address, dev.endpoint, dev.report_len)) |report_data| {
        if (usb_hid.parseKeyboardReport(report_data)) |report| {
            var changed = false;

            // Windows/Super key opens Start menu. Modifier bits 3 and 7.
            const gui_now = (report.modifiers & 0x88) != 0;
            const gui_before = (previous_usb_modifiers & 0x88) != 0;
            if (gui_now and !gui_before) {
                desktop.toggleStartMenu();
                changed = true;
            }

            for (report.keycodes) |code| {
                if (code != 0) {
                    var was_down = false;
                    for (previous_usb_keys) |old_code| {
                        if (old_code == code) was_down = true;
                    }
                    if (!was_down) {
                        if (desktop.onUsbKey(code, report.modifiers)) changed = true;
                    }
                }
            }
            previous_usb_keys = report.keycodes;
            previous_usb_modifiers = report.modifiers;
            if (changed) desktop.redrawScene();
        }
    }
}

pub export fn kernel_main(multiboot_info_ptr: u32) callconv(.C) void {
    const info: *multiboot.MultibootInfo = @ptrFromInt(multiboot_info_ptr);

    // Phase 1 virtual memory: identity-mapped 4 MiB pages covering the
    // full 4 GiB address space. This must run before anything else - if
    // the identity map is wrong, we want to find out immediately via a
    // triple fault here, not after the framebuffer/USB/network are
    // already half-initialized and harder to reason about. Because it's
    // a 1:1 map, every physical address used below (framebuffer, PCI
    // BARs, the heap) keeps working exactly as it did with paging off.
    paging.init();

    // Replaces boot.asm's minimal GDT with the richer one (adds ring-3
    // code/data segments and a TSS) that userspace needs. Selectors
    // 0x08/0x10 keep meaning exactly what they did before, so nothing
    // else has to change just because this ran.
    gdt.init();

    fb.fb_addr = @intCast(info.framebuffer_addr);
    fb.fb_pitch = info.framebuffer_pitch;
    fb.fb_width = info.framebuffer_width;
    fb.fb_height = info.framebuffer_height;
    fb.fb_bpp = info.framebuffer_bpp;

    if (fb.fb_addr == 0 or fb.fb_bpp != 32) {
        while (true) {
            asm volatile ("hlt");
        }
    }

    const requested_pixels: usize = @as(usize, fb.fb_width) * @as(usize, fb.fb_height);
    if (requested_pixels > fb.MAX_BACKBUFFER_PIXELS) {
        fault.renderResolutionTooLargeScreen(fb.fb_width, fb.fb_height);
        while (true) {
            asm volatile ("hlt");
        }
    }

    memory.init(info);

    mouse.screen_width = @intCast(fb.fb_width);
    mouse.screen_height = @intCast(fb.fb_height);
    mouse.mouse_x = @intCast(fb.fb_width / 2);
    mouse.mouse_y = @intCast(fb.fb_height / 2);

    // --- Minimal VFS (Phase 2: "basic VFS node tree") ---
    // No real storage backing yet (Phase 8) and no allocator yet (Phase
    // 4) - this is an in-memory node tree from a fixed-size pool. Notepad
    // reads its startup text from it below, which is as much a smoke
    // test as it is a feature: if the VFS is broken, the welcome banner
    // simply won't show up.
    fs.init();
    fs.seedCore97Files();

    notepad.init();
    desktop.init();

    idt.init();

    // Heartbeat timer (IRQ0), ~100Hz. Must be programmed before
    // interrupts are enabled - mouse.init() below does the `sti`.
    pit.init(100);

    // Reserves the dedicated, exclusive per-process memory regions (see
    // process.zig's header comment on why each process needs its own
    // never-shared 4 MiB region for isolation to actually hold) before
    // anything can be allocated from them.
    process.init();

    // Two copies of the same tiny demo program (userland/user_demo.zig),
    // each patched with a different visible ID, running in ring 3.
    // Scheduling is priority-weighted (see scheduler.zig) specifically
    // because plain round-robin starved USB HID polling the first time
    // this was tried - the kernel loop now keeps ~90% of ticks. Each
    // process also gets its own page directory (process.zig + paging.zig)
    // so they're truly isolated from each other and from the kernel, not
    // just privilege-separated.
    _ = process.create(&user_demo.image, user_demo.id_patch_offset, 'A');
    _ = process.create(&user_demo.image, user_demo.id_patch_offset, 'B');

    // OFF BY DEFAULT - deliberately set to `true` only when you want to
    // prove per-process isolation actually blocks cross-process memory
    // access (see userland/attack_demo.asm). Process creation order
    // matters: this MUST be created third, after A and B, because it
    // targets B's region by its known fixed address. Expected result if
    // isolation works: an immediate page fault / crash screen the
    // moment this process runs - that crash IS success, not a bug. If
    // you instead see '!' characters appearing, isolation is broken.
    const ENABLE_ISOLATION_TEST = false;
    if (ENABLE_ISOLATION_TEST) {
        _ = process.create(&attack_demo.image, attack_demo.image.len, 0);
    }

    scheduler.start();

    keyboard.setKeyHandler(desktop.onKeyPress);
    keyboard.setEventHandler(desktop.onKeyEvent);
    mouse.setMouseHandler(desktop.onMouseUpdate);
    mouse.init(null);

    desktop.redrawScene();

    // USB: controller detection, initial HID enumeration and later hotplug polling.
    // PS/2 stays enabled as the safe fallback input path; USB HID augments it.
    pci.scanForUhci();
    guest.detect();
    network.initAll();
    usb.scan();
    driver_registry.refresh();
    usb.rescanHid();

    var idx0: usize = 0;
    while (idx0 < usb_hid.device_count) : (idx0 += 1) {
        if (usb_hid.devices[idx0].device_type == .keyboard) {
            desktop.usb_keyboard_present = true;
            input.noteUsbKeyboard();
        } else if (usb_hid.devices[idx0].device_type == .mouse) {
            input.noteUsbMouse();
        } else if (usb_hid.devices[idx0].device_type == .tablet) {
            input.noteUsbTablet();
        }
    }

    input.chooseAfterEnumeration();
    network.initAll();
    driver_registry.refresh();
    desktop.redrawScene();

    // IMPORTANT: no `hlt` here. USB HID polling is manual/software-driven
    // (uhci.zig has no interrupt path), so the CPU must keep spinning
    // regardless of the timer IRQ - hlt would just sleep through polls
    // and make the USB mouse/keyboard appear dead.
    var hotplug_tick: u32 = 0;
    while (true) {
        var i: usize = 0;
        while (i < usb_hid.device_count) : (i += 1) {
            const dev = usb_hid.devices[i];
            if (!dev.connected) continue;
            pollUsbMouse(dev);
            pollUsbTablet(dev);
            pollUsbKeyboard(dev);
        }
        hotplug_tick += 1;
        if (hotplug_tick >= 400) {
            hotplug_tick = 0;
            if (usb.hotplugPoll()) {
                desktop.redrawScene();
            }
        }
        tinyDelay(10000);
    }
}
