// drivers/cpu.zig - basic x86 CPU identification.
// Full CPUID string decoding will come when paging/stack conventions are
// stable. For now this advertises the universal x86-compatible CPU driver.

pub var has_cpuid: bool = true;

pub fn detect() void {
    has_cpuid = true;
}

pub fn name() []const u8 {
    return "x86/AMD64 compatible processor";
}
