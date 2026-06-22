// kernel/fault.zig - fault and panic screen rendering ("blue screen").
//
// Pulled out of kernel.zig to keep the entry point focused on
// orchestration. By the time anything here runs, something has already
// gone wrong, so this is deliberately the simplest, most defensive code
// in the kernel: no allocator, no GUI state, just direct framebuffer
// writes. It must not be able to fault itself.

const fb = @import("../gui/framebuffer.zig");
const idt = @import("../arch/x86/idt.zig");

// Order matches the `pusha` instruction in interrupts.asm. `pusha` pushes
// EAX, ECX, EDX, EBX, ESP, EBP, ESI, EDI in that order, and since each
// push lowers the address, the LAST one pushed (EDI) ends up at the
// LOWEST address - i.e. first in this struct, reading up from the
// pointer the asm trampoline hands us. Keep this in sync with the
// EXCEPTION_NOERR/EXCEPTION_ERR macros if those ever change.
pub const Registers = extern struct {
    edi: u32,
    esi: u32,
    ebp: u32,
    esp_dummy: u32, // ESP as pusha saw it - informational only, not reliable past this point
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
};

const BSOD_BLUE: u32 = 0x0000AA;
const TEXT_WHITE: u32 = 0xFFFFFF;

fn exceptionName(num: u32) []const u8 {
    return switch (num) {
        0 => "DIVIDE BY ZERO",
        1 => "DEBUG",
        2 => "NON-MASKABLE INTERRUPT",
        3 => "BREAKPOINT",
        4 => "OVERFLOW",
        5 => "BOUND RANGE EXCEEDED",
        6 => "INVALID OPCODE",
        7 => "DEVICE NOT AVAILABLE",
        8 => "DOUBLE FAULT",
        9 => "COPROCESSOR SEGMENT OVERRUN",
        10 => "INVALID TSS",
        11 => "SEGMENT NOT PRESENT",
        12 => "STACK SEGMENT FAULT",
        13 => "GENERAL PROTECTION FAULT",
        14 => "PAGE FAULT",
        16 => "X87 FPU ERROR",
        17 => "ALIGNMENT CHECK",
        18 => "MACHINE CHECK",
        19 => "SIMD FP EXCEPTION",
        else => "UNKNOWN EXCEPTION",
    };
}

fn drawLine(y: u32, text: []const u8) void {
    fb.drawString(20, y, text, TEXT_WHITE, BSOD_BLUE);
}

// --- Tiny hex formatting (no std.fmt on this freestanding target) ---
fn hexDigit(nibble: u4) u8 {
    return if (nibble < 10) '0' + @as(u8, nibble) else 'A' + @as(u8, nibble - 10);
}

fn writeHex32(buf: *[10]u8, value: u32) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const shift: u5 = @intCast((7 - i) * 4);
        const nibble: u4 = @truncate(value >> shift);
        buf[2 + i] = hexDigit(nibble);
    }
    return buf[0..10];
}

fn drawLabeledHex(y: u32, label: []const u8, value: u32) void {
    var buf: [10]u8 = undefined;
    const hex = writeHex32(&buf, value);
    fb.drawString(20, y, label, TEXT_WHITE, BSOD_BLUE);
    fb.drawString(20 + @as(u32, @intCast(label.len)) * 6, y, hex, TEXT_WHITE, BSOD_BLUE);
}

fn writeDecimal(buf: *[10]u8, value: u32) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var tmp: [10]u8 = undefined;
    var n = value;
    var len: usize = 0;
    while (n > 0) {
        tmp[len] = @as(u8, @intCast(n % 10)) + '0';
        n /= 10;
        len += 1;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) buf[i] = tmp[len - 1 - i];
    return buf[0..len];
}

/// Halt screen for when the bootloader handed us a video mode bigger
/// than MAX_BACKBUFFER_PIXELS can hold. Should be rare now that
/// boot.asm's multiboot header asks for "no preference" rather than a
/// fixed 1024x768 - this exists so an unusually large mode fails loudly
/// instead of silently rendering a corrupted partial screen forever.
/// Like renderExceptionScreen, this can only safely draw into however
/// much of the backbuffer actually exists, so the message may only
/// cover the top portion of an oversized screen - still enough to read.
pub fn renderResolutionTooLargeScreen(width: u32, height: u32) void {
    if (fb.fb_addr == 0) return;

    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, BSOD_BLUE);
    drawLine(20, "CORE97OS - VIDEO MODE TOO LARGE");
    drawLine(40, "THE BOOTLOADER PICKED A RESOLUTION THIS BUILD");
    drawLine(55, "DOESN'T HAVE ENOUGH BACKBUFFER MEMORY FOR.");

    var wbuf: [10]u8 = undefined;
    var hbuf: [10]u8 = undefined;
    const wtext = writeDecimal(&wbuf, width);
    const htext = writeDecimal(&hbuf, height);
    fb.drawString(20, 85, "REQUESTED: ", TEXT_WHITE, BSOD_BLUE);
    fb.drawString(20 + 11 * 6, 85, wtext, TEXT_WHITE, BSOD_BLUE);
    fb.drawString(20 + 11 * 6 + @as(u32, @intCast(wtext.len)) * 6, 85, "X", TEXT_WHITE, BSOD_BLUE);
    fb.drawString(20 + 11 * 6 + @as(u32, @intCast(wtext.len)) * 6 + 6, 85, htext, TEXT_WHITE, BSOD_BLUE);

    drawLine(110, "TRY A SMALLER DISPLAY MODE, OR INCREASE");
    drawLine(125, "MAX_BACKBUFFER_PIXELS IN gui/framebuffer.zig.");

    fb.presentFrame();
}

/// Renders a full CPU-exception "blue screen": exception name, error
/// code, faulting EIP, CR2 (for page faults), and a GP-register dump.
/// Never returns on its own - the caller halts right after.
pub fn renderExceptionScreen(exception_num: u32, error_code: u32, eip: u32, regs: *const Registers) void {
    if (fb.fb_addr == 0) return; // no framebuffer yet - nothing we can draw

    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, BSOD_BLUE);

    drawLine(20, "CORE97OS - A FATAL EXCEPTION HAS OCCURRED");
    drawLine(40, exceptionName(exception_num));

    drawLabeledHex(70, "EXCEPTION:  ", exception_num);
    drawLabeledHex(85, "ERROR CODE: ", error_code);
    drawLabeledHex(100, "EIP:        ", eip);

    if (exception_num == 14) {
        drawLabeledHex(115, "CR2 (ADDR): ", idt.readCr2());
    }

    drawLabeledHex(140, "EAX: ", regs.eax);
    drawLabeledHex(155, "EBX: ", regs.ebx);
    drawLabeledHex(170, "ECX: ", regs.ecx);
    drawLabeledHex(185, "EDX: ", regs.edx);
    drawLabeledHex(200, "ESI: ", regs.esi);
    drawLabeledHex(215, "EDI: ", regs.edi);
    drawLabeledHex(230, "EBP: ", regs.ebp);

    drawLine(260, "THE SYSTEM HAS HALTED TO PREVENT DAMAGE.");
    drawLine(275, "RESTART YOUR COMPUTER. IF THIS SCREEN APPEARS AGAIN,");
    drawLine(290, "CONTACT THE CORE97OS DEVELOPERS.");

    fb.presentFrame();
}

/// Renders a simpler screen for software panics (Zig's `@panic`, failed
/// safety checks in ReleaseSafe builds, etc.) where we only have a
/// message string and no exception/register context.
pub fn renderPanicScreen(msg: []const u8) void {
    if (fb.fb_addr == 0) return;

    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, BSOD_BLUE);
    drawLine(20, "CORE97OS - KERNEL PANIC");
    drawLine(50, msg);
    drawLine(80, "THE SYSTEM HAS HALTED TO PREVENT DAMAGE.");
    fb.presentFrame();
}
