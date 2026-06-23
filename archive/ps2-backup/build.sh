#!/bin/bash
set -e

echo "==> Assembling boot.asm..."
nasm -f elf32 boot.asm -o boot.o

echo "==> Assembling interrupts.asm..."
nasm -f elf32 interrupts.asm -o interrupts.o

echo "==> Compiling kernel.zig..."
zig build-obj kernel.zig -target x86-freestanding-none -mcpu=i386 -fno-strip -O ReleaseSafe -femit-bin=kernel.o

echo "==> Linking kernel..."
ld -m elf_i386 -T linker.ld -o kernel.bin boot.o interrupts.o kernel.o

echo "==> Building ISO..."
mkdir -p isodir/boot/grub
cp kernel.bin isodir/boot/kernel.bin
cp grub.cfg isodir/boot/grub/grub.cfg
grub-mkrescue -o core97.iso isodir 2>/dev/null

echo "==> Done! Built core97.iso"
echo "==> Run with: qemu-system-i386 -cdrom core97.iso"
