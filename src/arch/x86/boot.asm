; boot.asm - Multiboot-compatible entry point
; Sets up a stack, then jumps into our Zig kernel

bits 32

MBALIGN   equ 1<<0
MEMINFO   equ 1<<1
VIDINFO   equ 1<<2          ; ask GRUB to set up graphics mode
FLAGS     equ MBALIGN | MEMINFO | VIDINFO
MAGIC     equ 0x1BADB002
CHECKSUM  equ -(MAGIC + FLAGS)

section .multiboot
align 4
    dd MAGIC
    dd FLAGS
    dd CHECKSUM
    dd 0, 0, 0, 0, 0         ; header_addr/load_addr/load_end/bss_end/entry (unused here)
    dd 0                     ; mode_type: 0 = linear framebuffer (grafik, ej text)
    dd 0                     ; width: 0 = no preference, let the bootloader/firmware pick
    dd 0                     ; height: 0 = no preference
    dd 32                    ; depth (bits per pixel) - the one thing we actually require

section .bss
align 16
stack_bottom:
    resb 16384 ; 16 KiB stack
stack_top:

; --- Custom GDT ---
; We can't rely on GRUB's GDT having a code segment at selector 0x08.
; By setting up our own, we know exactly which selectors the IDT should point at.
section .data
align 8
gdt_start:
    dq 0x0000000000000000      ; null descriptor (required by the CPU)

gdt_code:                       ; selector 0x08
    dw 0xFFFF                   ; limit low
    dw 0x0000                   ; base low
    db 0x00                     ; base middle
    db 10011010b                ; access: present, ring0, code, exec/read
    db 11001111b                ; flags + limit high (4K-granularity, 32-bit)
    db 0x00                     ; base high

gdt_data:                       ; selector 0x10
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 10010010b                ; access: present, ring0, data, read/write
    db 11001111b
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1   ; limit
    dd gdt_start                 ; base

section .text
global _start
extern kernel_main

_start:
    mov ebp, ebx        ; save multiboot info pointer (ebx is overwritten shortly)
    mov esp, stack_top

    ; Load our own GDT so we know exactly which selectors apply
    lgdt [gdt_descriptor]

    ; Reload the segment registers with our new selectors
    mov ax, 0x10          ; data-segment selector
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Jump via a far jump to force the CPU to load the new CS (0x08)
    jmp 0x08:.reload_cs
.reload_cs:
    push ebp              ; multiboot info pointer, saved above
    call kernel_main
    cli
.hang:
    hlt
    jmp .hang
