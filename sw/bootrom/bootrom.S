// Minimal CVA6 bootrom for cva6_xdma.
// Mapped at 0x00010000 (CVA6 reset vector). Jumps to 0x80000000 (DRAM) with:
//   a0 = mhartid
//   a1 = 0   (no DTB yet)
//
// CVA6 fetches from the boot address in machine mode at reset; satp == 0,
// so this is a flat-addressed jump.

.section .text.start, "ax", @progbits
.globl _start
_start:
    csrr  a0, mhartid
    li    a1, 0
    li    t0, 1
    slli  t0, t0, 31           // t0 = 0x8000_0000
    jr    t0
