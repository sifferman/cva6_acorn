// Minimal CVA6 liveness probe: write 0xAB to ctrl STATUS (0x60000008) and spin.
// No crt0, no C — just proves the bootrom jumps here and CVA6 executes a store.
.section .text.init, "ax", @progbits
.globl _start
_start:
    li   t0, 0x60000008
    li   t1, 0xAB
    sw   t1, 0(t0)
1:  j    1b
