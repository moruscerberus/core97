; attack_demo.asm - deliberate isolation-violation test.
;
; This is NOT a realistic attacker (a real one wouldn't know another
; process's address up front) - it's a controlled experiment. Process
; creation order in kernel.zig is A (slot 0), B (slot 1), this program
; (slot 2), so B's dedicated region is a known, fixed physical address:
; PROCESS_REGION_BASE + 1*FOUR_MIB = 0x0C800000 + 0x00400000 = 0x0CC00000
; (see process.zig's PROCESS_REGION_BASE/PROCESS_REGION_SIZE - if either
; constant changes, this address must be recomputed to match).
;
; Two possible outcomes, deliberately unambiguous:
;   - Isolation WORKS: the write below page-faults immediately. Execution
;     never reaches the loop. kernel/fault.zig's exception-14 handler
;     takes over and shows the crash screen - that crash IS the proof,
;     not a bug, since there's no per-process fault recovery yet.
;   - Isolation is BROKEN: the write silently succeeds, the loop runs,
;     and '!' characters start appearing via sys_write_char - an
;     unmistakable "isolation failed" signal, distinct from A/B's
;     output so it can't be confused with normal operation.
bits 32
org 0

start:
    mov byte [0x0CC00000], 0x58   ; attempt to write into process B's region

.loop:
    mov eax, 0           ; sys_write_char
    mov ebx, 0x21        ; '!' - only ever reached if the write above did NOT fault
    int 0x80

    mov eax, 1           ; sys_yield
    int 0x80

    jmp .loop
