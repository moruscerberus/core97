// drivers/vbe.zig - Bochs VBE "dispi" interface: runtime video mode
// changes without rebooting, without real-mode/BIOS calls.
//
// GRUB negotiates a video mode exactly once, at boot, via the BIOS in
// real mode - this kernel only ever reads the RESULT of that (through
// Multiboot's framebuffer_* fields) and has no way to ask for a
// different mode once running in 32-bit protected mode, since BIOS
// int 0x10 calls require real mode (or a v86 monitor this kernel
// doesn't have). That's why "change resolution after boot" has been
// impossible so far - not a software limitation in this kernel's UI
// code, but a missing piece of hardware access entirely.
//
// The Bochs VBE extensions ("dispi" - DISPlay Interface) sidestep that
// completely: they're a small set of registers, accessed via two plain
// I/O ports, that let software set width/height/bpp directly, no BIOS
// or real mode involved. They were invented for the Bochs emulator,
// but every virtualizer relevant here implements the exact same
// registers for compatibility: QEMU's default "-vga std" device, and
// VirtualBox's default "VBoxVGA" adapter, both speak this protocol
// identically. One driver, written once against the documented
// register layout, works unmodified under both - this was confirmed
// against the OSDev wiki's Bochs VBE Extensions page and QEMU's own
// "Standard VGA" device specification before writing any of this.
//
// What this does NOT solve: there's no register here for "the host
// wants you to resize to match its window" - dispi is purely a
// "set the mode I ask for" interface, not a notification mechanism.
// Detecting an actual host window resize live would need a separate,
// hypervisor-specific channel (VirtualBox's VMMDev/HGSMI, or QEMU's
// virtio-gpu display-info queue) - genuinely different protocols per
// hypervisor, and a much bigger driver each. What IS solved: the user
// (or a future "auto-detect" layer built later) can request any
// supported resolution at any time, and it takes effect immediately,
// no reboot - the actual mechanical piece that was missing.

const idt = @import("../arch/x86/idt.zig");
const fb = @import("../gui/framebuffer.zig");
const mouse = @import("mouse.zig");

pub const Resolution = struct { w: u32, h: u32 };

const VBE_DISPI_IOPORT_INDEX: u16 = 0x01CE;
const VBE_DISPI_IOPORT_DATA: u16 = 0x01CF;

const VBE_DISPI_INDEX_ID: u16 = 0x0;
const VBE_DISPI_INDEX_XRES: u16 = 0x1;
const VBE_DISPI_INDEX_YRES: u16 = 0x2;
const VBE_DISPI_INDEX_BPP: u16 = 0x3;
const VBE_DISPI_INDEX_ENABLE: u16 = 0x4;
const VBE_DISPI_INDEX_BANK: u16 = 0x5;
const VBE_DISPI_INDEX_VIRT_WIDTH: u16 = 0x6;
const VBE_DISPI_INDEX_VIRT_HEIGHT: u16 = 0x7;
const VBE_DISPI_INDEX_X_OFFSET: u16 = 0x8;
const VBE_DISPI_INDEX_Y_OFFSET: u16 = 0x9;

const VBE_DISPI_ID5: u16 = 0xB0C5; // latest known dispi version - what we expect to read back

const VBE_DISPI_DISABLED: u16 = 0x00;
const VBE_DISPI_ENABLED: u16 = 0x01;
const VBE_DISPI_LFB_ENABLED: u16 = 0x40;
const VBE_DISPI_NOCLEARMEM: u16 = 0x80;

// Generous but bounded - large enough to cover any resolution a real
// desktop monitor would plausibly use, small enough that the upfront
// memory reservation (see kernel/memory.zig's use of this) stays
// reasonable. Bochs/QEMU/VirtualBox all support resolutions well past
// this in practice, but there's no reason to allow more than a sane
// desktop monitor would ever need.
pub const MAX_WIDTH: u32 = fb.MAX_WIDTH;
pub const MAX_HEIGHT: u32 = fb.MAX_HEIGHT;
pub const MAX_FRAMEBUFFER_BYTES: u32 = MAX_WIDTH * MAX_HEIGHT * 4;

/// Returns a sane, crisp desktop mode for the shell.  This is intentionally
/// NOT DPI scaling.  We choose a real video mode and then render the UI 1:1
/// into that mode.  This prevents QEMU/VirtualBox fullscreen from stretching
/// a tiny framebuffer into a huge, blurry host window.
pub fn chooseCrispMode(width: u32, height: u32) Resolution {
    var w = width;
    var h = height;
    if (w > MAX_WIDTH) w = MAX_WIDTH;
    if (h > MAX_HEIGHT) h = MAX_HEIGHT;

    // Tiny/old boot modes should be upgraded immediately when Bochs VBE is
    // available.  1280x720 keeps Win95-era proportions readable while giving
    // much more desktop area than 640x480.
    if (w < 800 or h < 600) return .{ .w = 1280, .h = 720 };

    // Host fullscreen can sometimes report a very wide temporary surface
    // (for example 2048x576).  Rendering a desktop directly at that shape
    // makes everything feel horizontally stretched and wrong.  Pick the
    // closest normal mode instead; QEMU/VirtualBox can letterbox it, but the
    // OS framebuffer itself stays pixel-perfect.
    if (w * 10 > h * 24) {
        if (h >= 900) return .{ .w = 1600, .h = 900 };
        if (h >= 768) return .{ .w = 1366, .h = 768 };
        return .{ .w = 1280, .h = 720 };
    }

    // Also reject very tall/narrow transient modes.
    if (h * 10 > w * 18) {
        if (w >= 1280) return .{ .w = 1280, .h = 720 };
        return .{ .w = 1024, .h = 768 };
    }

    return .{ .w = w, .h = h };
}

fn writeReg(index: u16, value: u16) void {
    idt.outw(VBE_DISPI_IOPORT_INDEX, index);
    idt.outw(VBE_DISPI_IOPORT_DATA, value);
}

fn readReg(index: u16) u16 {
    idt.outw(VBE_DISPI_IOPORT_INDEX, index);
    return idt.inw(VBE_DISPI_IOPORT_DATA);
}

/// True if a Bochs-dispi-compatible adapter is present (the ID register
/// reads back one of the known dispi version IDs). Both QEMU's default
/// "-vga std" and VirtualBox's default "VBoxVGA" pass this - if it
/// fails, this is some other adapter (or dispi genuinely isn't there)
/// and setMode() should not be trusted to do anything sensible.
pub fn isAvailable() bool {
    const id = readReg(VBE_DISPI_INDEX_ID);
    // Accept B0C0 through B0C5 (every dispi version that has existed) -
    // not just the latest, since older virtualizer builds may report
    // an earlier ID while still supporting the basic mode-set registers
    // this driver actually uses.
    return id >= 0xB0C0 and id <= VBE_DISPI_ID5;
}

/// Sets a new mode (always 32bpp, linear framebuffer) and updates
/// fb.real_fb_width/height/pitch/bpp to whatever was ACTUALLY applied -
/// hardware may clamp the requested size, so the values read back after
/// enabling are authoritative, never the requested ones. Returns false
/// (leaving the previous mode and fb.real_fb_* untouched) if the
/// request is out of bounds or no dispi-compatible adapter is present.
///
/// Deliberately does not touch fb.real_fb_addr: the dispi registers
/// change how much of the SAME fixed-size video memory region is
/// active as the visible framebuffer, not where that memory region
/// starts - the base address obtained from Multiboot at boot stays
/// valid across mode changes.
pub fn setMode(width: u32, height: u32) bool {
    if (!isAvailable()) return false;
    if (width == 0 or height == 0 or width > MAX_WIDTH or height > MAX_HEIGHT) return false;

    writeReg(VBE_DISPI_INDEX_ENABLE, VBE_DISPI_DISABLED);
    writeReg(VBE_DISPI_INDEX_XRES, @truncate(width));
    writeReg(VBE_DISPI_INDEX_YRES, @truncate(height));
    writeReg(VBE_DISPI_INDEX_BPP, 32);
    writeReg(VBE_DISPI_INDEX_BANK, 0);
    writeReg(VBE_DISPI_INDEX_ENABLE, VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED | VBE_DISPI_NOCLEARMEM);

    const applied_width: u32 = readReg(VBE_DISPI_INDEX_XRES);
    const applied_height: u32 = readReg(VBE_DISPI_INDEX_YRES);
    if (applied_width == 0 or applied_height == 0) return false;

    fb.real_fb_width = applied_width;
    fb.real_fb_height = applied_height;
    fb.real_fb_bpp = 32;
    fb.real_fb_pitch = applied_width * 4; // dispi LFB mode is unpadded at 32bpp
    fb.configureCanvas(applied_width, applied_height);

    mouse.screen_width = @intCast(fb.fb_width);
    mouse.screen_height = @intCast(fb.fb_height);
    if (mouse.mouse_x >= mouse.screen_width) mouse.mouse_x = mouse.screen_width - 1;
    if (mouse.mouse_y >= mouse.screen_height) mouse.mouse_y = mouse.screen_height - 1;

    return true;
}
