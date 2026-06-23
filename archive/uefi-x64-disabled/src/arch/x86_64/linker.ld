/* linker.ld - x86_64, for the Limine boot protocol.
 *
 * Limine loads ELF executables directly; it does not require PIE/dynamic
 * relocations (those are only needed to opt into KASLR). This is a plain
 * static higher-half image, loaded at the fixed address the Limine spec
 * mandates for non-relocatable executables.
 */

ENTRY(_start)

PHDRS
{
    text    PT_LOAD    FLAGS((1 << 0) | (1 << 2)) ; /* Execute + Read */
    rodata  PT_LOAD    FLAGS((1 << 2)) ;             /* Read only */
    data    PT_LOAD    FLAGS((1 << 1) | (1 << 2)) ;  /* Write + Read */
}

SECTIONS
{
    . = 0xffffffff80000000;

    .text : {
        *(.text .text.*)
    } :text

    . += CONSTANT(MAXPAGESIZE);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . += CONSTANT(MAXPAGESIZE);

    /* Limine requests must live in writable memory - the bootloader
     * fills in each request's `response` pointer field at boot time,
     * before our code ever runs. They go in :data, not :rodata. */
    .data : {
        *(.limine_requests_start)
        *(.limine_requests)
        *(.limine_requests_end)
        *(.data .data.*)
    } :data

    .bss : {
        *(COMMON)
        *(.bss .bss.*)
    } :data

    /DISCARD/ : {
        *(.eh_frame)
        *(.note .note.*)
    }
}
