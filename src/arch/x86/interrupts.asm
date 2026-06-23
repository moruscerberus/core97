; interrupts.asm - low-level interrupt stubs
; The CPU requires us to save registers before jumping into Zig code,
; and restore them before returning with iretd.

global idt_load
global gdt_load
global keyboard_isr
global mouse_isr
global timer_isr
global syscall_isr
global default_isr

extern keyboard_handler
extern mouse_handler
extern timer_handler
extern exception_handler
extern scheduler_tick
extern syscall_dispatch

; Loads the IDT. Receives a pointer to the IDT descriptor (limit+base) as
; the first (and only) argument on the stack, per the cdecl convention
; used by Zig for callconv(.C) functions.
idt_load:
    mov eax, [esp + 4]   ; [esp+0] = return address, [esp+4] = first argument
    lidt [eax]
    ret

; Loads the GDT. Same calling convention as idt_load above.
gdt_load:
    mov eax, [esp + 4]
    lgdt [eax]
    ret

; IRQ1 - keyboard
keyboard_isr:
    pusha
    call keyboard_handler
    popa
    iretd

; IRQ12 - PS/2 mouse
mouse_isr:
    pusha
    call mouse_handler
    popa
    iretd

; IRQ0 - PIT timer heartbeat AND the preemptive scheduler tick.
;
; timer_handler keeps doing exactly what it always did (tick counter,
; EOI) - that bookkeeping is unrelated to scheduling and shouldn't change
; just because a scheduler now also runs here.
;
; scheduler_tick(current_esp) -> new_esp is the actual context switch:
; it's handed a pointer to the just-pushed register block (which, taken
; together with the hardware interrupt frame above it, is a complete,
; resumable snapshot of whatever was running - see kernel/fault.zig's
; Registers struct for the exact layout this matches). It saves that
; into the current process's slot, picks the next ready process, and
; returns THAT process's previously-saved stack pointer. Once `esp` is
; repointed at a different process's saved frame, the same popa/iretd
; below resumes that *different* process instead of the one that was
; interrupted - that's the entire mechanism preemptive multitasking
; relies on. Before a scheduler exists (or with only one process ever
; created), scheduler_tick just hands back the same esp it was given,
; making this a no-op identical to the old plain timer_isr.
timer_isr:
    pusha
    call timer_handler
    push esp
    call scheduler_tick
    add esp, 4
    mov esp, eax
    popa
    iretd

; int 0x80 - syscall gate. IDT entry 0x80 is set up with DPL=3 (see
; idt.zig) specifically so ring-3 code is allowed to trigger this via
; the `int` instruction; hardware IRQs are unaffected by that DPL check.
;
; syscall_dispatch(regs_ptr) callconv(.C) void reads the syscall number
; and arguments out of the pushed register block (eax/ebx/ecx/edx, same
; Registers layout as everywhere else in this kernel) and writes a
; return value back into the eax slot of that same block - so once popa
; restores it, the ring-3 caller sees its result in EAX as expected.
syscall_isr:
    pusha
    push esp
    call syscall_dispatch
    add esp, 4
    popa
    iretd

; Catches ALL unexpected hardware IRQs (spurious interrupts etc).
default_isr:
    pusha
    mov al, 0x20
    out 0x20, al
    out 0xA0, al
    popa
    iretd

; --- CPU exception handlers (ISR 0-31) ---
; Each stub saves the GP registers (pusha), reads out EIP (and, for the
; exceptions that have one, the real error code the CPU already pushed
; onto the stack) and calls a shared Zig function with four arguments:
;   exception_handler(exception_num, error_code, eip, regs_ptr)
; regs_ptr points to the 32-byte pusha block, so the Zig side can
; print a full register dump instead of just the exception number.
;
; pusha order (lowest address = pushed last): EDI, ESI, EBP, ESP(orig),
; EBX, EDX, ECX, EAX - see kernel/fault.zig:Registers, which must match
; exactly.
%macro EXCEPTION_NOERR 1
global exception_isr_%1
exception_isr_%1:
    pusha                   ; esp is now = pointer to the regs block (E)
    mov eax, [esp+32]       ; EIP - no real error code for this exception,
                            ; so the hardware frame (EIP/CS/EFLAGS) starts
                            ; right after the regs block
    push esp                ; arg4: regs_ptr (= E)
    push eax                ; arg3: eip
    push dword 0            ; arg2: error_code (fake, this exception has none)
    push dword %1           ; arg1: exception_num
    call exception_handler
    add esp, 16             ; clean up our 4 explicit pushes -> esp = E
    popa                    ; restore the real registers; esp -> E+32 (EIP again)
    iretd
%endmacro

%macro EXCEPTION_ERR 1
global exception_isr_%1
exception_isr_%1:
    pusha                   ; esp is now = E
    mov ebx, [esp+32]       ; the error code is already on the stack from the CPU
    mov eax, [esp+36]       ; EIP sits right after the error code
    push esp                ; arg4: regs_ptr (= E)
    push eax                ; arg3: eip
    push ebx                ; arg2: error_code
    push dword %1           ; arg1: exception_num
    call exception_handler
    add esp, 16             ; clean up our 4 explicit pushes -> esp = E
    popa                    ; restore the real registers; esp -> E+32 (error code)
    add esp, 4               ; discard the CPU's error code - iretd only wants EIP/CS/EFLAGS
    iretd
%endmacro

EXCEPTION_NOERR 0   ; Division by zero
EXCEPTION_NOERR 1   ; Debug
EXCEPTION_NOERR 2   ; NMI
EXCEPTION_NOERR 3   ; Breakpoint
EXCEPTION_NOERR 4   ; Overflow
EXCEPTION_NOERR 5   ; Bound range exceeded
EXCEPTION_NOERR 6   ; Invalid opcode  <- this was our SSE bug
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
