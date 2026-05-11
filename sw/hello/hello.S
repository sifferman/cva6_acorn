// Hello world for cva6_xdma.
//
// Loaded into DRAM at 0x80000000 by the host via XDMA before CVA6 is released
// from reset. Bootrom at 0x10000 jumps here.
//
// Address map (must match BD):
//   0x40000000  console buffer   [length:32][bytes...]
//   0x60000008  STATUS reg       (write nonzero -> raises usr_irq to host)
//
// Behavior:
//   1. Write the message length to console+0
//   2. Write "Hello, FPGA!\n" starting at console+4
//   3. Write 1 to STATUS to wake the host
//   4. Park in WFI

.section .text.start, "ax", @progbits
.globl _start
_start:
    la      t0, msg
    la      t1, msg_end
    sub     t1, t1, t0          // t1 = length

    li      t2, 0x40000000      // console buffer base
    sw      t1, 0(t2)           // [console+0] = length

    addi    t3, t2, 4           // dst = console+4
1:
    beqz    t1, 2f
    lbu     t4, 0(t0)
    sb      t4, 0(t3)
    addi    t0, t0, 1
    addi    t3, t3, 1
    addi    t1, t1, -1
    j       1b
2:
    fence                       // ensure writes ordered before doorbell
    li      t0, 0x60000008      // STATUS register (raises XDMA usr_irq)
    li      t1, 1
    sw      t1, 0(t0)
3:
    wfi
    j       3b

.section .rodata, "a", @progbits
msg:
    .ascii "Hello, FPGA!\n"
msg_end:
