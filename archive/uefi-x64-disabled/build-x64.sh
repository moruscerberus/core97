#!/bin/bash
# build-x64.sh - assembles, compiles, links, and ISO-packs the x86_64
# Core97 branch (docs/roadmap.md Phase 3), then boots it in QEMU under
# OVMF (UEFI firmware) with serial output on stdio.
#
# One-time external dependencies this script does NOT install for you:
#   - nasm, zig, ld, xorriso, qemu-system-x86_64  (apt/your package manager)
#   - OVMF UEFI firmware (Ubuntu/Debian: `apt install ovmf`, providing
#     /usr/share/OVMF/OVMF_CODE.fd - adjust OVMF_PATH below if yours
#     lives somewhere else)
#   - Limine itself: this script clones the prebuilt binary release from
#     GitHub the first time it runs and reuses it after that.
set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
BUILD="$ROOT/build64"
ISO_ROOT="$BUILD/iso_root"
LIMINE_DIR="$ROOT/limine"
# OVMF ships in two incompatible shapes depending on distro/package
# version: an old-style single combined image (works with QEMU's simple
# `-bios` flag) or a newer split CODE/VARS pair meant for `-drive
# if=pflash` instead - `-bios` flatly rejects the split CODE-only file
# ("could not load PC BIOS"). Prefer a combined image when one exists
# since it's simpler; fall back to pflash with a writable per-build copy
# of VARS (QEMU writes UEFI NVRAM into it, so it shouldn't point at the
# read-only system file).
OVMF_MODE=""
if [ -z "$OVMF_PATH" ]; then
  for candidate in \
    /usr/share/ovmf/OVMF.fd \
    /usr/share/qemu/OVMF.fd \
    /usr/share/OVMF/OVMF_CODE.fd
  do
    if [ -f "$candidate" ]; then
      OVMF_PATH="$candidate"
      OVMF_MODE="bios"
      break
    fi
  done
fi
if [ -z "$OVMF_PATH" ]; then
  for codecandidate in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd
  do
    varscandidate="${codecandidate/CODE/VARS}"
    if [ -f "$codecandidate" ] && [ -f "$varscandidate" ]; then
      OVMF_PATH="$codecandidate"
      OVMF_VARS_PATH="$varscandidate"
      OVMF_MODE="pflash"
      break
    fi
  done
fi
OVMF_PATH="${OVMF_PATH:-/usr/share/OVMF/OVMF_CODE.fd}"
OVMF_MODE="${OVMF_MODE:-bios}"

echo "==> Cleaning old build files..."
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "==> Assembling boot.asm..."
nasm -f elf64 "$SRC/arch/x86_64/boot.asm" -o "$BUILD/boot.o"

echo "==> Assembling interrupts.asm..."
nasm -f elf64 "$SRC/arch/x86_64/interrupts.asm" -o "$BUILD/interrupts.o"

echo "==> Compiling kernel..."
zig build-obj "$SRC/main64.zig" \
  -target x86_64-freestanding-none \
  -mcpu=x86_64 \
  -mcmodel=kernel \
  -fno-strip \
  -O ReleaseSafe \
  -femit-bin="$BUILD/kernel_zig.o"

echo "==> Linking kernel..."
ld -m elf_x86_64 -T "$SRC/arch/x86_64/linker.ld" -o "$BUILD/kernel.elf" \
  "$BUILD/boot.o" "$BUILD/interrupts.o" "$BUILD/kernel_zig.o"

echo "==> Fetching Limine binary release (first run only)..."
if [ ! -d "$LIMINE_DIR" ]; then
  git clone https://github.com/limine-bootloader/limine.git --branch=v8.x-binary --depth=1 "$LIMINE_DIR"
fi
make -C "$LIMINE_DIR" >/dev/null 2>&1 || true

echo "==> Building UEFI-bootable ISO..."
mkdir -p "$ISO_ROOT/EFI/BOOT"
cp "$BUILD/kernel.elf" "$ISO_ROOT/kernel.elf"
cp "$SRC/arch/x86_64/limine.conf" "$ISO_ROOT/limine.conf"
cp "$LIMINE_DIR/BOOTX64.EFI" "$ISO_ROOT/EFI/BOOT/BOOTX64.EFI"
cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_ROOT/limine-uefi-cd.bin"
xorriso -as mkisofs \
  --efi-boot limine-uefi-cd.bin \
  -efi-boot-part --efi-boot-image --protective-msdos-label \
  "$ISO_ROOT" -o "$BUILD/core97-x86_64.iso"

echo "==> Done! Built build64/core97-x86_64.iso"

if [ ! -f "$OVMF_PATH" ]; then
  echo "==> WARNING: OVMF firmware not found at $OVMF_PATH"
  echo "    Install it (e.g. 'apt install ovmf') or set OVMF_PATH=/path/to/firmware.fd"
  exit 1
fi

echo "==> Starting Core97 x86_64 (watch this terminal for serial output)..."
if [ "$OVMF_MODE" = "pflash" ]; then
  # Copy VARS to a writable per-build location - QEMU writes NVRAM
  # variables into it, and the system-installed copy is normally
  # read-only (and shouldn't be mutated by every test run anyway).
  cp "$OVMF_VARS_PATH" "$BUILD/OVMF_VARS.fd"
  qemu-system-x86_64 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_PATH" \
    -drive if=pflash,format=raw,unit=1,file="$BUILD/OVMF_VARS.fd" \
    -cdrom "$BUILD/core97-x86_64.iso" \
    -serial stdio \
    -m 256M
else
  qemu-system-x86_64 \
    -bios "$OVMF_PATH" \
    -cdrom "$BUILD/core97-x86_64.iso" \
    -serial stdio \
    -m 256M
fi
