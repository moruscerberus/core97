; boot.asm - x86_64 GDT/TSS/IDT load helpers.
;
; Limine hands off directly into a 64-bit Zig function with paging and a
; valid stack already set up (see PROTOCOL.md "Machine State at Entry"),
; so unlike the 32-bit Multiboot path, there's no entry stub needed here -
; _start is plain Zig. What Zig's inline asm *can't* do cleanly is the
; far-return trick needed to reload CS in long mode, so that (and its two
; siblings, ltr/lidt) live here instead, called with the standard SysV
; x86-64 calling convention (first arg in RDI, second in RSI).

bits 64

global gdt64_flush
global tss64_flush
global idt64_load

; gdt64_flush(gdt_ptr: *const GdtPointer) - RDI = pointer to the GDTR
; descriptor (limit:base, see idt.zig). Loads the GDT, reloads every data
; segment register, and reloads CS via a far return - you cannot just
; `mov cs, ax` in any x86 mode, and in long mode there's no far jump
; immediate either, so a push-and-retfq is the standard idiom.
gdt64_flush:
    lgdt [rdi]

    mov ax, 0x10        ; kernel data selector - see idt.zig Gdt64 layout
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    push qword 0x08      ; kernel code selector
    lea rax, [rel .reload_cs]
    push rax
    retfq
.reload_cs:
    ret

; tss64_flush(selector: u16) - RDI's low 16 bits hold the TSS selector.
tss64_flush:
    mov ax, di
    ltr ax
    ret

; idt64_load(idt_ptr: *const IdtPointer) - RDI = pointer to the IDTR
; descriptor.
idt64_load:
    lidt [rdi]
    ret
