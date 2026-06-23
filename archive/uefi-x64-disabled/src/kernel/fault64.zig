// kernel/fault64.zig - x86_64 fault and panic screen rendering.
//
// x86_64 analog of kernel/fault.zig. Two differences from the 32-bit
// version: the register set is twice as wide (no pusha-based Registers
// struct - SAVE_REGS in interrupts.asm pushes all 15 GP registers by
// hand), and CR2 is passed in by the caller rather than read here, since
// reading it requires the x86_64 idt module and this file intentionally
// has no arch-specific imports - kernel64.zig already has CR2 by the
// time it calls renderExceptionScreen, from idt.readCr2().
//
// Also logs everything over serial first. If the framebuffer request
// failed or the GUI is what's broken, serial is the only way any of
// this is visible at all.

const fb = @import("../gui/framebuffer.zig");
const serial = @import("../arch/x86_64/serial.zig");

// Field order matches interrupts.asm's SAVE_REGS macro: the LAST register
// pushed (rax) ends up at the LOWEST address, i.e. first in this struct.
// Keep these in sync if either ever changes.
pub const Registers = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
};

const BSOD_BLUE: u32 = 0x0000AA;
const TEXT_WHITE: u32 = 0xFFFFFF;

fn exceptionName(num: u64) []const u8 {
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

fn hexDigit(nibble: u4) u8 {
    return if (nibble < 10) '0' + @as(u8, nibble) else 'A' + @as(u8, nibble - 10);
}

fn writeHex64Buf(buf: *[18]u8, value: u64) []const u8 {
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        const nibble: u4 = @truncate(value >> shift);
        buf[2 + i] = hexDigit(nibble);
    }
    return buf[0..18];
}

fn drawLabeledHex(y: u32, label: []const u8, value: u64) void {
    var buf: [18]u8 = undefined;
    const hex = writeHex64Buf(&buf, value);
    fb.drawString(20, y, label, TEXT_WHITE, BSOD_BLUE);
    fb.drawString(20 + @as(u32, @intCast(label.len)) * 6, y, hex, TEXT_WHITE, BSOD_BLUE);
    serial.writeString(label);
    serial.writeHex64(value);
    serial.writeLine("");
}

/// Renders a full CPU-exception screen: name, error code, faulting RIP,
/// CR2 (for page faults; pass 0 for anything else), and a GP-register
/// dump - to both the framebuffer (if up) and serial (always). Never
/// returns on its own - the caller halts right after.
pub fn renderExceptionScreen(exception_num: u64, error_code: u64, rip: u64, cr2: u64, regs: *const Registers) void {
    serial.writeLine("");
    serial.writeLine("=== CORE97OS x86_64 - FATAL EXCEPTION ===");
    serial.writeLine(exceptionName(exception_num));

    if (fb.fb_addr != 0) {
        fb.fillRect(0, 0, fb.fb_width, fb.fb_height, BSOD_BLUE);
        drawLine(20, "CORE97OS x86_64 - A FATAL EXCEPTION HAS OCCURRED");
        drawLine(40, exceptionName(exception_num));
    }

    drawLabeledHex(70, "EXCEPTION:  ", exception_num);
    drawLabeledHex(85, "ERROR CODE: ", error_code);
    drawLabeledHex(100, "RIP:        ", rip);
    if (exception_num == 14) drawLabeledHex(115, "CR2 (ADDR): ", cr2);

    drawLabeledHex(140, "RAX: ", regs.rax);
    drawLabeledHex(155, "RBX: ", regs.rbx);
    drawLabeledHex(170, "RCX: ", regs.rcx);
    drawLabeledHex(185, "RDX: ", regs.rdx);
    drawLabeledHex(200, "RSI: ", regs.rsi);
    drawLabeledHex(215, "RDI: ", regs.rdi);
    drawLabeledHex(230, "RBP: ", regs.rbp);
    drawLabeledHex(245, "R8:  ", regs.r8);
    drawLabeledHex(260, "R9:  ", regs.r9);
    drawLabeledHex(275, "R10: ", regs.r10);
    drawLabeledHex(290, "R11: ", regs.r11);
    drawLabeledHex(305, "R12: ", regs.r12);
    drawLabeledHex(320, "R13: ", regs.r13);
    drawLabeledHex(335, "R14: ", regs.r14);
    drawLabeledHex(350, "R15: ", regs.r15);

    if (fb.fb_addr != 0) {
        drawLine(380, "THE SYSTEM HAS HALTED TO PREVENT DAMAGE.");
        fb.presentFrame();
    }
}

/// Simpler screen for software panics (Zig's `@panic`, ReleaseSafe
/// checks) - only a message string, no exception/register context.
pub fn renderPanicScreen(msg: []const u8) void {
    serial.writeLine("");
    serial.writeLine("=== CORE97OS x86_64 - KERNEL PANIC ===");
    serial.writeLine(msg);

    if (fb.fb_addr == 0) return;
    fb.fillRect(0, 0, fb.fb_width, fb.fb_height, BSOD_BLUE);
    drawLine(20, "CORE97OS x86_64 - KERNEL PANIC");
    drawLine(50, msg);
    drawLine(80, "THE SYSTEM HAS HALTED TO PREVENT DAMAGE.");
    fb.presentFrame();
}
