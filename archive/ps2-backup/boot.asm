; boot.asm - Multiboot-compatible entry point
; Sets up a stack, then jumps into our Zig kernel

bits 32

MBALIGN   equ 1<<0
MEMINFO   equ 1<<1
VIDINFO   equ 1<<2          ; be GRUB sätta upp grafikläge
FLAGS     equ MBALIGN | MEMINFO | VIDINFO
MAGIC     equ 0x1BADB002
CHECKSUM  equ -(MAGIC + FLAGS)

section .multiboot
align 4
    dd MAGIC
    dd FLAGS
    dd CHECKSUM
    dd 0, 0, 0, 0, 0         ; header_addr/load_addr/load_end/bss_end/entry (oanvänt här)
    dd 0                     ; mode_type: 0 = linear framebuffer (grafik, ej text)
    dd 1024                  ; width
    dd 768                   ; height
    dd 32                    ; depth (bits per pixel)

section .bss
align 16
stack_bottom:
    resb 16384 ; 16 KiB stack
stack_top:

; --- Egen GDT ---
; Vi kan inte lita på att GRUB:s GDT har kod-segment på selector 0x08.
; Genom att sätta upp vår egen, vet vi exakt vilka selectors IDT:n ska peka på.
section .data
align 8
gdt_start:
    dq 0x0000000000000000      ; null descriptor (krävs av CPU:n)

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
    mov ebp, ebx        ; spara multiboot info pointer (ebx skrivs över strax)
    mov esp, stack_top

    ; Ladda vår egen GDT så vi vet exakt vilka selectors som gäller
    lgdt [gdt_descriptor]

    ; Ladda om segmentregistren med våra nya selectors
    mov ax, 0x10          ; data-segment selector
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    ; Hoppa till en far jump för att tvinga CPU:n att ladda nytt CS (0x08)
    jmp 0x08:.reload_cs
.reload_cs:
    push ebp              ; multiboot info pointer, sparad ovan
    call kernel_main
    cli
.hang:
    hlt
    jmp .hang
