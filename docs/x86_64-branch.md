# x86_64 / UEFI branch

Parked for now.

The active build is the legacy BIOS/i386 path using:

```text
src/arch/x86/boot.asm
src/arch/x86/grub.cfg
src/main.zig
src/kernel/kernel.zig
```

Use:

```bash
./build.sh
```

The old x86_64/Limine experiment has been moved to:

```text
archive/uefi-x64-disabled/
```
