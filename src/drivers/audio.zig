// drivers/audio.zig - minimal PC speaker audio driver stub.

const idt = @import("../arch/x86/idt.zig");

pub var present: bool = true;
pub var enabled: bool = false;
/// Master on/off for the short UI feedback tones (clickSound/openSound)
/// - Control Panel's Sound page toggles this. Independent of
/// present/enabled, which track the PC speaker hardware itself.
pub var ui_sounds_enabled: bool = true;

pub fn detect() void { present = true; }

pub fn beep() void {
    // Short PC speaker chirp using PIT channel 2. This is deliberately tiny:
    // useful for proving the audio path exists, not a real mixer yet.
    const divisor: u16 = 1193180 / 880;
    idt.outb(0x43, 0xB6);
    idt.outb(0x42, @truncate(divisor & 0xFF));
    idt.outb(0x42, @truncate(divisor >> 8));
    const tmp = idt.inb(0x61);
    idt.outb(0x61, tmp | 0x03);
    enabled = true;
}

pub fn silence() void {
    const tmp = idt.inb(0x61) & 0xFC;
    idt.outb(0x61, tmp);
    enabled = false;
}

/// Remaining duration for the currently playing short tone, in PIT
/// ticks. This is decremented from the timer IRQ. It deliberately avoids
/// busy-waiting because clickSound()/openSound() may be called from the
/// PS/2 mouse IRQ; waiting there for `pit.ticks` would deadlock because
/// the timer IRQ cannot run until the mouse IRQ returns.
var tone_ticks_left: u32 = 0;

/// Plays a short PC-speaker tone asynchronously. The PIT timer interrupt
/// calls onTimerTick() to stop it after `duration_ticks`, so this function
/// is safe from interrupt handlers and GUI code alike.
pub fn playTone(freq_hz: u32, duration_ticks: u32) void {
    if (!present or freq_hz == 0 or duration_ticks == 0) return;
    const divisor: u16 = @intCast(1193180 / freq_hz);
    idt.outb(0x43, 0xB6);
    idt.outb(0x42, @truncate(divisor & 0xFF));
    idt.outb(0x42, @truncate(divisor >> 8));
    const tmp = idt.inb(0x61);
    idt.outb(0x61, tmp | 0x03);
    enabled = true;
    tone_ticks_left = duration_ticks;
}

/// Called once per PIT tick from drivers/pit.zig. Keep this tiny and
/// non-blocking: it runs in the timer interrupt path.
pub fn onTimerTick() void {
    if (!enabled or tone_ticks_left == 0) return;
    tone_ticks_left -= 1;
    if (tone_ticks_left == 0) silence();
}

/// Short, high click - for button presses, icon selection, that kind of
/// frequent, low-key feedback. Deliberately brief (~20ms) so a flurry
/// of clicks (e.g. dragging a rubber-band selection) doesn't feel like
/// it's stacking up delay.
pub fn clickSound() void {
    if (!ui_sounds_enabled) return;
    playTone(1200, 2);
}

/// Slightly lower and longer than clickSound - for less-frequent,
/// bigger events (opening a window) where a touch more presence reads
/// as "something happened" without becoming annoying on repeat.
pub fn openSound() void {
    if (!ui_sounds_enabled) return;
    playTone(700, 4);
}
