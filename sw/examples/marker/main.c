// Progress-marker bisection: find exactly where CVA6 stalls on the new
// peripherals. Each MARK() writes ctrl STATUS (0x60000008) — a register CVA6
// is proven able to write on this bitstream. After running, the host reads
// 0x60000008 to see the last marker reached.
#include "bsp.h"
#define MARK(v) (*(volatile unsigned int *)0x60000008UL = (unsigned)(v))

int main(int hartid, void *dtb)
{
    volatile unsigned char *uart = (volatile unsigned char *)0x10000000UL;
    MARK(0x10);                              // reached main (crt0 ok)
    unsigned int lsr = uart[5];              // CVA6 READ of UART LSR
    MARK(0x2000u | (lsr & 0xff));            // read returned; record LSR value
    uart[0] = 'Z';                           // CVA6 WRITE to UART THR
    MARK(0x30);                              // THR write returned (no hang)
    *(volatile unsigned int *)0x100000UL = 0x5555u;  // CVA6 WRITE to finisher
    MARK(0x40);                              // finisher write returned
    for (;;) { }
}
