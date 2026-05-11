OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    rom (rx) : ORIGIN = 0x00010000, LENGTH = 4K
}

SECTIONS {
    .text : {
        *(.text.start)
        *(.text*)
    } > rom
}
