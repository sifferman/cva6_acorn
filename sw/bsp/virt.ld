/* Linker script for baremetal RV64 on the QEMU `virt` machine (and the
 * FK33 card, which mirrors virt's map). RAM/DRAM is at 0x80000000; _start
 * must sit at exactly 0x80000000 because both QEMU's mask ROM (-bios none)
 * and the card's bootrom jump there with a0=hartid, a1=dtb.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x80000000, LENGTH = 128M
}

SECTIONS {
    . = ORIGIN(RAM);

    .text : {
        KEEP(*(.text.init))      /* _start lands at 0x80000000 */
        *(.text*)
    } > RAM

    .rodata : {
        *(.rodata*)
        *(.srodata*)
    } > RAM

    .data : {
        *(.data*)
        *(.sdata*)
    } > RAM

    /* 8-align the section START (the ALIGN(8) section attribute), so _bss_start
     * lands on an 8-byte boundary. crt0 clears bss with `sd` (8-byte stores);
     * CVA6 traps on a misaligned store (QEMU silently emulates it), so an
     * unaligned _bss_start hangs the CPU before main. _bss_end is ALIGN(8) too
     * so the clear loop covers a whole number of doublewords. */
    .bss (NOLOAD) : ALIGN(8) {
        _bss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(8);
        _bss_end = .;
    } > RAM

    . = ALIGN(16);
    _heap_start = .;             /* reserved for future use */
    . = . + 0x10000;             /* 64 KB stack */
    . = ALIGN(16);
    _stack_top = .;
    _end = .;
}
