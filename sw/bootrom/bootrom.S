// Minimal CVA6 bootrom for cva6_xdma.
// Mapped at 0x00010000 (CVA6 reset vector). Jumps to 0x80000000 (DRAM) with:
//   a0 = mhartid
//   a1 = 0x8800_0000  (device tree blob address; the host XDMA-loads the DTB
//                      there before releasing reset, matching QEMU `virt`'s
//                      `-bios none` hand-off of a0=hartid / a1=dtb)
//
// CVA6 fetches from the boot address in machine mode at reset; satp == 0,
// so this is a flat-addressed jump.

.section .text.start, "ax", @progbits
.globl _start
_start:
    csrr  a0, mhartid
    li    a1, 0x88             // a1 = 0x8800_0000 (DTB pointer)
    slli  a1, a1, 24
    li    t0, 1
    slli  t0, t0, 31           // t0 = 0x8000_0000
    jr    t0
