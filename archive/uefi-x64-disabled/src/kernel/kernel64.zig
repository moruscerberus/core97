// kernel/kernel64.zig - x86_64 entry point.
//
// Scope of this first x86_64 pass (see docs/roadmap.md Phase 3): boot,
// GDT/TSS/IDT, exceptions with a real double-fault stack, timer IRQ,
// keyboard IRQ. Deliberately NOT in scope yet: mouse, USB, the
// gui/desktop window manager, Notepad, the VFS - those all still only
// exist on the 32-bit side (src/main.zig). Porting them is follow-up
// work once this foundation is proven solid, not bundled into the same
// change as "does long mode boot at all."

const limine = @import("limine.zig");
const fault = @import("fault64.zig");
const fb = @import("../gui/framebuffer.zig");
const idt = @import("../arch/x86_64/idt.zig");
const serial = @import("../arch/x86_64/serial.zig");
const pit = @import("../drivers/pit64.zig");
const keyboard = @import("../drivers/keyboard64.zig");

pub export fn exception_handler(exception_num: u64, error_code: u64, rip: u64, regs: *const fault.Registers) callconv(.C) void {
    const cr2: u64 = if (exception_num == 14) idt.readCr2() else 0;
    fault.renderExceptionScreen(exception_num, error_code, rip, cr2, regs);
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

fn haltForever() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Draws a plain banner so there's a visible "we made it this far" signal
/// independent of serial output, for whoever's at the actual screen.
fn drawBootBanner() void {
    const CORE97_TEAL: u32 = 0x008080;
    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, CORE97_TEAL);
    fb.drawString(20, 20, "CORE97OS x86_64 - BOOT OK", 0xFFFFFF, CORE97_TEAL);
    fb.drawString(20, 35, "Limine + long mode + GDT/TSS/IDT + PIT + PS/2 IRQ1", 0xFFFFFF, CORE97_TEAL);
    fb.drawString(20, 50, "GUI/mouse/USB/VFS not ported to this arch yet.", 0xFFFFFF, CORE97_TEAL);
    fb.presentFrame();
}

pub export fn _start() callconv(.C) noreturn {
    serial.init();
    serial.writeLine("CORE97OS x86_64: _start reached");

    if (limine.limine_base_revision[2] != 0) {
        // Bootloader didn't ack our requested base revision - it wrote a
        // 0 into slot [2] on success. Nothing graceful to do without a
        // framebuffer; report over serial and stop.
        serial.writeLine("FATAL: Limine did not accept base revision 1");
        haltForever();
    }
    serial.writeLine("Limine base revision accepted");

    const framebuffer = limine.getFramebuffer() orelse {
        serial.writeLine("FATAL: no framebuffer from Limine");
        haltForever();
    };

    fb.fb_addr = @intFromPtr(framebuffer.address.?);
    fb.fb_pitch = @truncate(framebuffer.pitch);
    fb.fb_width = @truncate(framebuffer.width);
    fb.fb_height = @truncate(framebuffer.height);
    fb.fb_bpp = @truncate(framebuffer.bpp);

    serial.writeString("Framebuffer OK: ");
    serial.writeHex64(framebuffer.width);
    serial.writeString(" x ");
    serial.writeHex64(framebuffer.height);
    serial.writeString(" @ ");
    serial.writeHex64(framebuffer.bpp);
    serial.writeLine(" bpp");

    if (fb.fb_bpp != 32) {
        serial.writeLine("FATAL: framebuffer is not 32bpp, this kernel only handles 32bpp");
        haltForever();
    }

    drawBootBanner();

    if (limine.getMemmap()) |memmap| {
        serial.writeString("Memory map: ");
        serial.writeHex64(memmap.count);
        serial.writeLine(" entries (not consumed yet - see docs/roadmap.md Phase 4)");
    } else {
        serial.writeLine("Memory map request had no response (non-fatal, just unused for now)");
    }

    idt.init();
    serial.writeLine("GDT/TSS/IDT loaded");

    pit.init(100);
    serial.writeLine("PIT programmed for ~100Hz");

    asm volatile ("sti");
    serial.writeLine("Interrupts enabled - entering main loop");

    var last_logged_tick: u32 = 0;
    while (true) {
        asm volatile ("hlt");

        // Every ~5 seconds (at 100Hz), log a heartbeat plus the last
        // scancode seen, so a serial-connected reader can confirm both
        // IRQ0 and IRQ1 are actually firing, not just configured.
        if (pit.ticks -% last_logged_tick >= 500) {
            last_logged_tick = pit.ticks;
            serial.writeString("heartbeat: ticks=");
            serial.writeHex64(pit.ticks);
            serial.writeString(" last_scancode=");
            serial.writeHex64(keyboard.last_scancode);
            serial.writeString(" key_events=");
            serial.writeHex64(keyboard.key_event_count);
            serial.writeLine("");
        }
    }
}
