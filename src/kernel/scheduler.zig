// kernel/scheduler.zig - priority-weighted preemptive scheduler.
//
// Slot 0 is special: it isn't created by process.create() like the
// others, it's the kernel's own original boot context (the `while
// (true)` loop at the bottom of kernel_main, plus everything that runs
// from PS/2/USB interrupts on top of it). The very first timer tick
// after start() runs simply records whatever esp it's handed as slot
// 0's saved state - "capturing" the already-running kernel loop as a
// schedulable task without it ever having to be specially constructed
// like a fresh process's fake frame.
//
// IMPORTANT, learned the hard way: this is NOT plain round-robin. The
// first version split CPU time evenly across kernel-loop + every demo
// process, and that immediately broke USB mouse input - the kernel's
// main loop drives USB HID polling in a tight spin (see kernel.zig's
// own comment on why: it's software-driven, no interrupt path), and
// giving it only 1/3 of total ticks made polling too sparse to keep up.
// The fix is priority weighting: the kernel loop runs on every tick
// EXCEPT every PROCESS_SLICE_EVERY-th one, where exactly one demo
// process gets a single tick's turn before control reverts to the
// kernel loop on the very next tick. At 100 Hz (pit.init(100)) with
// PROCESS_SLICE_EVERY=10, that's a ~10 ms process slice roughly once
// every 100 ms - enough to visibly prove preemptive switching is
// happening, without starving the polling loop the way equal time-
// slicing did.

const process = @import("process.zig");
const gdt = @import("../arch/x86/gdt.zig");
const paging = @import("../arch/x86/paging.zig");

var kernel_slot: process.Process = .{};
var current: usize = 0; // 0 = kernel_slot, 1..MAX_PROCESSES = process.table[current-1]
var started: bool = false;
var bootstrapped: bool = false;
var tick_count: u32 = 0;

// Tracks rotation position among DEMO PROCESSES SPECIFICALLY, separate
// from `current`. This exists because of a real bug found by testing:
// `current` resets to 0 (the kernel loop) on every tick that doesn't
// hand a process a turn, so by the time the *next* process-slice tick
// rolls around, `current` is always back to 0 - meaning a search that
// started "after current" would always start "after 0" and therefore
// always find the SAME first ready process (slot 1) again, forever.
// Two processes were created to prove alternation, but only the first
// one ever actually got picked. Tracking the last process slot that ran
// (independent of whatever the kernel loop did in between) is what
// makes the rotation actually advance.
var last_process_slot: usize = 0;

// Higher = kernel loop gets a larger share of CPU time. 10 means the
// kernel runs ~90% of ticks; only every 10th tick gives a demo process
// a turn at all.
const PROCESS_SLICE_EVERY: u32 = 10;

/// Call once, after process.create() has set up whichever demo
/// processes should run, and before interrupts are enabled. Does NOT
/// switch anything itself - it just arms scheduler_tick to start doing
/// real scheduling from the next timer interrupt onward.
pub fn start() void {
    started = true;
}

fn savedEsp(slot: usize) u32 {
    if (slot == 0) return kernel_slot.esp;
    return process.table[slot - 1].esp;
}

fn setSavedEsp(slot: usize, esp: u32) void {
    if (slot == 0) {
        kernel_slot.esp = esp;
    } else {
        process.table[slot - 1].esp = esp;
    }
}

fn kernelStackTopOf(slot: usize) u32 {
    if (slot == 0) return kernel_slot.kernel_stack_top;
    return process.table[slot - 1].kernel_stack_top;
}

// Slot 0 (the kernel loop) always uses the kernel's own supervisor-only
// directory - it never runs ring-3 code, so it never needs any
// user-accessible pages. Every other slot uses ITS OWN page directory
// (built once, in process.create()), where only that one process's
// dedicated 4 MiB region is marked user-accessible - see paging.zig's
// "Per-process page directories" section for why that's what actually
// makes processes unable to reach each other's memory.
fn pageDirectoryOf(slot: usize) u32 {
    if (slot == 0) return paging.kernelDirectoryPhysAddr();
    return process.table[slot - 1].pdir_phys;
}

// Finds the next .ready demo process slot (1..MAX_PROCESSES) after
// `after`, wrapping around. Returns 0 (meaning "stay on the kernel
// loop") if none are ready - e.g. before any process.create() call, or
// once all demo processes have sys_exit'd.
fn nextReadyProcessSlot(after: usize) usize {
    var checked: usize = 0;
    var candidate = after;
    while (checked < process.MAX_PROCESSES) : (checked += 1) {
        candidate = if (candidate == 0) 1 else (candidate % process.MAX_PROCESSES) + 1;
        if (process.table[candidate - 1].state == .ready) return candidate;
    }
    return 0;
}

/// Called from timer_isr (interrupts.asm) on every PIT tick, with a
/// pointer to the just-pushed register block of whatever was
/// interrupted. Returns the stack pointer to resume - which, after this
/// function returns, timer_isr blindly pops into ESP before its own
/// popa+iretd. That single `mov esp, eax` in the asm is the entire
/// context switch; everything here is just bookkeeping to decide *which*
/// saved esp to hand back.
pub export fn scheduler_tick(current_esp: u32) callconv(.C) u32 {
    if (!started) return current_esp;

    if (!bootstrapped) {
        // First tick ever: just capture the interrupted kernel loop as
        // slot 0's state. Don't switch anywhere yet.
        bootstrapped = true;
        kernel_slot.esp = current_esp;
        kernel_slot.kernel_stack_top = current_esp; // informational only for slot 0
        return current_esp;
    }

    setSavedEsp(current, current_esp);
    tick_count +%= 1;

    var target: usize = 0; // default every tick: back to (or stay on) the kernel loop
    if (tick_count % PROCESS_SLICE_EVERY == 0) {
        target = nextReadyProcessSlot(last_process_slot);
        if (target != 0) last_process_slot = target;
    }

    current = target;
    gdt.setKernelStack(kernelStackTopOf(current));
    paging.switchDirectory(pageDirectoryOf(current));
    return savedEsp(current);
}

/// Used by syscall.zig's sys_exit: marks the currently running process
/// terminated so the scheduler stops picking it. Has no effect if the
/// current slot is the kernel loop (slot 0), which can't exit.
pub fn exitCurrent() void {
    if (current == 0) return;
    process.terminate(current - 1);
}
