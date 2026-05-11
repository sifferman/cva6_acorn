OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    dram (rwx) : ORIGIN = 0x80000000, LENGTH = 16M
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text*)
    } > dram

    .rodata : {
        *(.rodata*)
    } > dram

    .data : {
        *(.data*)
    } > dram

    .bss : {
        *(.bss*)
        *(COMMON)
    } > dram
}
