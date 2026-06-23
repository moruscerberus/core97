; user_demo.asm - tiny ring3 demo program.
; Position-independent (no fixed load address assumed): uses the classic
; "call/pop" trick to find its own runtime address in esi, then computes
; the address of `my_id` relative to that. process.zig patches `my_id`
; after copying this image into a fresh process's page, so multiple
; processes can run the exact same code and still be told apart on
; screen (proves preemptive switching is actually alternating between
; them, not just running one in a loop).
;
; Syscall ABI (kernel/syscall.zig):
;   eax = syscall number, ebx/ecx/edx = args, result returned in eax.
;   0 = sys_write_char(char in ebx)
;   1 = sys_yield()
;   2 = sys_exit()
bits 32
org 0

start:
    call here
here:
    pop esi
.loop:
    mov eax, 0
    movzx ebx, byte [esi + (my_id - here)]
    int 0x80

    mov eax, 1
    int 0x80

    jmp .loop

my_id: db 'A'
