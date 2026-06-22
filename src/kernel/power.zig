// kernel/power.zig - shut down and restart the machine.
//
// Real ACPI power-off needs parsing the FADT for the PM1a control block
// and SLP_TYP values - too much for this project's current phase. Instead
// this targets the fixed "soft off" I/O ports that QEMU, Bochs, and
// VirtualBox all wire up specifically so simple OS-dev kernels like this
// one can power off without a full ACPI stack. On real hardware (or an
// emulator that doesn't support any of these), none of the writes do
// anything observable, so shutdown() falls back to the classic retro-desktop
// 9x "It's now safe to turn off your computer" screen and halts forever.

const idt = @import("../arch/x86/idt.zig");
const fb = @import("../gui/framebuffer.zig");

fn haltForever() noreturn {
    while (true) {
        asm volatile ("hlt");
    }
}

/// Resets the CPU by pulsing the reset line through the 8042 keyboard
/// controller (port 0x64, command 0xFE) - the standard real-mode-era
/// trick for a software reboot, and the one most bootloaders/BIOSes
/// still wire up correctly. Falls back to a triple fault (load a bogus,
/// zero-length IDT and trigger an interrupt) if the controller doesn't
/// respond, which forces the CPU to reset itself.
pub fn reboot() noreturn {
    // Wait for the controller's input buffer to be clear (bit 1 of the
    // status port) before sending the pulse-reset command, same as the
    // PS/2 driver already does elsewhere in this codebase.
    var spins: u32 = 0;
    while ((idt.inb(0x64) & 0x02) != 0 and spins < 100000) : (spins += 1) {}
    idt.outb(0x64, 0xFE);

    // If we're still here, the 8042 path didn't take - force a triple
    // fault instead, which the CPU treats as unrecoverable and resets
    // itself from.
    idt.forceTripleFault();
}

/// Attempts ACPI soft-off through the fixed ports several emulators
/// special-case, then shows the classic "safe to power off" screen
/// and halts. Under QEMU/Bochs/VirtualBox this actually powers the
/// virtual machine off; on hardware without ACPI support it's the
/// fallback screen that's actually seen.
pub fn shutdown() noreturn {
    idt.outw(0x604, 0x2000); // QEMU's old "isa-debug-exit"-style ACPI shim
    idt.outw(0xB004, 0x2000); // Bochs / older QEMU
    idt.outb(0x4004, 0x34); // VirtualBox (Acpi PM)
    idt.outw(0x4004, 0x3400);

    showSafeToTurnOffScreen();
    haltForever();
}

fn showSafeToTurnOffScreen() void {
    const BLUE: u32 = 0x000080;
    const WHITE: u32 = 0xFFFFFF;
    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, BLUE);
    const cx = if (fb.fb_width > 400) (fb.fb_width - 400) / 2 else 20;
    const cy = if (fb.fb_height > 80) (fb.fb_height - 80) / 2 else 20;
    fb.drawString(cx, cy, "CORE97", WHITE, BLUE);
    fb.drawString(cx, cy + 24, "IT IS NOW SAFE TO TURN OFF", WHITE, BLUE);
    fb.drawString(cx, cy + 36, "YOUR COMPUTER.", WHITE, BLUE);
    fb.presentFrame();
}
