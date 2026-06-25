// kernel/syscall.zig - syscall dispatch for int 0x80.
//
// ABI: eax = syscall number, ebx/ecx/edx = up to three arguments, return
// value written back into the eax slot of the same Registers block so
// the ring-3 caller sees it after popa restores their context. Reusing
// fault.Registers (rather than defining a parallel struct) is
// deliberate: it's already proven to match exactly what interrupts.asm
// pushes via `pusha`, and syscall_isr pushes the same way.

const fault = @import("fault.zig");
const fb = @import("../gui/framebuffer.zig");
const scheduler = @import("scheduler.zig");

const SYS_WRITE_CHAR: u32 = 0;
const SYS_YIELD: u32 = 1;
const SYS_EXIT: u32 = 2;

// Fixed debug strip near the bottom of the screen where ring-3 processes
// "print" via sys_write_char - this exists purely to make preemptive
// switching between processes visually verifiable (you should see
// different processes' characters interleaving over time), not as a
// real console. A proper one belongs to the windowing/app layer, once
// processes can own windows.
const OUTPUT_ROW: u32 = 20;
const OUTPUT_COL_START: u32 = 20;
const OUTPUT_WIDTH_CHARS: u32 = 60;
var output_col: u32 = 0;

fn sysWriteChar(char_code: u32) void {
    if (fb.real_fb_addr == 0) return;
    const c: u8 = @truncate(char_code);
    var buf = [1]u8{c};
    const x = OUTPUT_COL_START + output_col * 7;
    fb.drawString(x, OUTPUT_ROW, buf[0..1], 0x00FF00, 0x000000);
    // drawString only writes into the back buffer (see framebuffer.zig's
    // double-buffering comment) - without this, nothing reaches the
    // actual screen until something else unrelated happens to call
    // presentFrame() first. That's the entire reason this looked like
    // "nothing is running" rather than "wrong scheduling" the first time.
    fb.presentFrame();
    output_col += 1;
    if (output_col >= OUTPUT_WIDTH_CHARS) output_col = 0;
}

pub export fn syscall_dispatch(regs: *fault.Registers) callconv(.C) void {
    switch (regs.eax) {
        SYS_WRITE_CHAR => {
            sysWriteChar(regs.ebx);
            regs.eax = 0;
        },
        SYS_YIELD => {
            regs.eax = 0;
        },
        SYS_EXIT => {
            scheduler.exitCurrent();
            regs.eax = 0;
        },
        else => {
            regs.eax = @bitCast(@as(i32, -1)); // unknown syscall number
        },
    }
}
