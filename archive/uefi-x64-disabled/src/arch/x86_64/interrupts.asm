; interrupts.asm - x86_64 interrupt stubs.
;
; Long mode has no `pusha`/`popa` (they're invalid opcodes in 64-bit
; mode), so every GP register gets pushed/popped by hand. Push order is
; chosen so the LAST register pushed (rax) ends up at the LOWEST address,
; matching kernel/fault64.zig's Registers struct field order exactly -
; keep these in sync if either ever changes.
;
; Calling convention is SysV x86-64 (args in registers, not on the
; stack), which is simpler than the 32-bit cdecl version: no esp
; bookkeeping around the call, since the callee never looks at the stack
; for its arguments.

bits 64

global idt64_keyboard_isr
global idt64_timer_isr
global idt64_default_isr

extern keyboard_handler
extern timer_handler
extern exception_handler

%macro SAVE_REGS 0
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rdi
    push rsi
    push rdx
    push rcx
    push rbx
    push rax
%endmacro

%macro RESTORE_REGS 0
    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
%endmacro

; IRQ1 - PS/2 keyboard
idt64_keyboard_isr:
    SAVE_REGS
    call keyboard_handler
    RESTORE_REGS
    iretq

; IRQ0 - PIT timer heartbeat
idt64_timer_isr:
    SAVE_REGS
    call timer_handler
    RESTORE_REGS
    iretq

; Catches unexpected hardware IRQs (spurious interrupts etc).
idt64_default_isr:
    push rax
    mov al, 0x20
    out 0x20, al
    out 0xA0, al
    pop rax
    iretq

; --- CPU exception handlers (vectors 0-19) ---
; Each stub saves all GP registers, pulls the real RIP (and, for the
; exceptions that have one, the real error code the CPU already pushed)
; out of the hardware frame, and calls:
;   exception_handler(exception_num, error_code, rip, regs_ptr)
; via RDI, RSI, RDX, RCX respectively (SysV's first four integer args).
; regs_ptr points at the 120-byte SAVE_REGS block.
%macro EXCEPTION_NOERR 1
global idt64_exception_isr_%1
idt64_exception_isr_%1:
    SAVE_REGS                  ; rsp now = E (pointer to the regs block)
    mov rdx, [rsp+120]         ; RIP - no real error code for this vector,
                               ; so the hardware frame starts right after
                               ; the regs block
    mov rcx, rsp               ; regs_ptr (arg4)
    mov rsi, 0                 ; error_code (arg2, fake - this vector has none)
    mov rdi, %1                ; exception_num (arg1)
    call exception_handler
    RESTORE_REGS                ; rsp back to E+120 = RIP again
    iretq
%endmacro

%macro EXCEPTION_ERR 1
global idt64_exception_isr_%1
idt64_exception_isr_%1:
    SAVE_REGS                   ; rsp now = E
    mov rsi, [rsp+120]          ; the real error code, pushed by the CPU
    mov rdx, [rsp+128]          ; RIP, right after the error code
    mov rcx, rsp                ; regs_ptr (arg4)
    mov rdi, %1                 ; exception_num (arg1)
    call exception_handler
    RESTORE_REGS                ; rsp -> E+120 = the CPU's error code
    add rsp, 8                  ; discard it - iretq wants RIP/CS/RFLAGS only
    iretq
%endmacro

EXCEPTION_NOERR 0   ; Division by zero
EXCEPTION_NOERR 1   ; Debug
EXCEPTION_NOERR 2   ; NMI
EXCEPTION_NOERR 3   ; Breakpoint
EXCEPTION_NOERR 4   ; Overflow
EXCEPTION_NOERR 5   ; Bound range exceeded
EXCEPTION_NOERR 6   ; Invalid opcode
EXCEPTION_NOERR 7   ; Device not available
EXCEPTION_ERR   8   ; Double fault (runs on the IST1 stack - see idt.zig)
EXCEPTION_NOERR 9   ; Coprocessor segment overrun (reserved on x86_64)
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
