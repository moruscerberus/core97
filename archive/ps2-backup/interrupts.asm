; interrupts.asm - low-level interrupt stubs
; CPU:n kräver att vi sparar register innan vi hoppar in i Zig-kod,
; och återställer dem innan vi returnerar med iretd.

global idt_load
global keyboard_isr
global mouse_isr
global default_isr

extern keyboard_handler
extern mouse_handler
extern exception_handler

; Laddar IDT. Tar emot pekare till IDT-descriptorn (limit+base) som
; första (och enda) argument på stacken, enligt cdecl-konventionen
; som Zig använder för callconv(.C)-funktioner.
idt_load:
    mov eax, [esp + 4]   ; [esp+0] = return address, [esp+4] = första argumentet
    lidt [eax]
    ret

; IRQ1 - tangentbord
keyboard_isr:
    pusha
    call keyboard_handler
    popa
    iretd

; IRQ12 - PS/2-mus
mouse_isr:
    pusha
    call mouse_handler
    popa
    iretd

; Fångar ALLA oväntade hardware-IRQ:er (spurious interrupts etc).
default_isr:
    pusha
    mov al, 0x20
    out 0x20, al
    out 0xA0, al
    popa
    iretd

; --- CPU-exception-handlers (ISR 0-31) ---
; Varje makro skapar en liten stub som pushar exceptionens nummer och
; hoppar till en gemensam Zig-funktion som ritar felet på skärmen och
; stannar säkert, istället för att trippelfaulta tyst.
%macro EXCEPTION_NOERR 1
global exception_isr_%1
exception_isr_%1:
    push dword 0          ; falsk felkod för konsekvent stack-layout
    push dword %1
    call exception_handler
    add esp, 8
    iretd
%endmacro

%macro EXCEPTION_ERR 1
global exception_isr_%1
exception_isr_%1:
    push dword %1          ; felkoden ligger redan på stacken från CPU:n
    call exception_handler
    add esp, 8
    iretd
%endmacro

EXCEPTION_NOERR 0   ; Division by zero
EXCEPTION_NOERR 1   ; Debug
EXCEPTION_NOERR 2   ; NMI
EXCEPTION_NOERR 3   ; Breakpoint
EXCEPTION_NOERR 4   ; Overflow
EXCEPTION_NOERR 5   ; Bound range exceeded
EXCEPTION_NOERR 6   ; Invalid opcode  <- detta var vårt SSE-fel
EXCEPTION_NOERR 7   ; Device not available
EXCEPTION_ERR   8   ; Double fault
EXCEPTION_NOERR 9   ; Coprocessor segment overrun
EXCEPTION_ERR   10  ; Invalid TSS
EXCEPTION_ERR   11  ; Segment not present
EXCEPTION_ERR   12  ; Stack-segment fault
EXCEPTION_ERR   13  ; General protection fault
EXCEPTION_ERR   14  ; Page fault
EXCEPTION_NOERR 15  ; Reserved
EXCEPTION_NOERR 16  ; x87 FPU error
EXCEPTION_ERR   17  ; Alignment check
EXCEPTION_NOERR 18  ; Machine check
EXCEPTION_NOERR 19  ; SIMD FP exception
