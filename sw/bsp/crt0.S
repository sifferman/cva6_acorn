// Baremetal RV64 startup for the QEMU `virt` machine and the FK33 card.
//
// Entered in M-mode at 0x80000000 with a0=mhartid, a1=dtb (the contract QEMU's
// `-bios none` mask ROM and the card bootrom both honour). Sets up the stack,
// clears .bss, then calls main(hartid, dtb). main's return value becomes the
// process exit code, delivered to the SiFive test finisher by _exit().

.section .text.init, "ax", @progbits
.globl _start
_start:
    csrr  t0, mhartid
    bnez  t0, park           // single-hart for now: park any secondary harts

    la    sp, _stack_top

    // zero .bss (8-byte aligned by the linker script)
    la    t0, _bss_start
    la    t1, _bss_end
1:  bgeu  t0, t1, 2f
    sd    zero, 0(t0)
    addi  t0, t0, 8
    j     1b
2:
    // a0=hartid, a1=dtb still live -> main(int hartid, void *dtb)
    call  main
    // a0 = main() return value -> exit code
    call  _exit

park:
    wfi
    j     park
