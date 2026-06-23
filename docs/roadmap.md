# Core97 roadmap

Current focus: **legacy BIOS / 32-bit i386 / GRUB Multiboot**.

UEFI/x86_64 is intentionally parked until the 32-bit BIOS version has a clean kernel structure, VFS, basic GUI, and stable drivers.

## Phase 1 — Clean BIOS foundation

- Keep the working legacy BIOS boot path.
- Keep source split under `src/`.
- Avoid growing one giant `kernel.zig` again.
- Stabilize keyboard, mouse, Notepad, Start menu, and panic screens.

## Phase 2 — VFS and apps

- Node-based VFS tree.
- RAM files.
- Notepad open/save through VFS.
- Later: file manager.

## Phase 3 — Kernel basics

- Better panic screen.
- Cleaner exception screen.
- Timer heartbeat.
- Basic memory allocator.
- Driver/event separation.

## Phase 4 — Storage

- Block device abstraction.
- Read-only FAT32.
- Writable FAT32.
- Later: Core97FS or ext-style filesystem.

## Phase 5 — UEFI/x86_64 later

Parked in `archive/uefi-x64-disabled/` for now.

## Added: Memory Manager + Device Manager

- Early physical memory manager parses the Multiboot memory map.
- Tracks 4 KiB physical pages up to 256 MiB.
- Reserves low memory, kernel image, and framebuffer pages.
- Exposes `allocPage`, `freePage`, `kmalloc`, and memory stats.
- PCI scan now records up to 64 detected PCI functions, not just UHCI.
- Start > Programs now includes Device Manager.
- Device Manager shows memory totals, free pages, heap usage, mmap entries, and detected PCI devices with basic class/driver status.

Storage is still intentionally deferred.

## Driver / Guest Additions Pass 1

Added a first-pass driver registry used by Device Manager and Command Prompt.
Current built-ins:
- Core97 CPU Driver
- Basic Display Adapter for the multiboot linear framebuffer / QEMU VGA
- Native PS/2 keyboard and mouse status
- UHCI USB HID status
- PC Speaker Audio driver stub with BEEP/SILENCE shell commands
- Intel E1000 detection entry for the upcoming NIC driver
- Core97 Guest Additions stub with QEMU VGA/NIC detection, scale percentage, input grab flag, and time-sync status

Next driver work:
1. E1000 MMIO BAR mapping and command register enable.
2. RX/TX descriptor rings.
3. Ethernet frame send/receive.
4. ARP + ICMP ping.
5. Replace display scaling stub with real mode/resolution handling.
