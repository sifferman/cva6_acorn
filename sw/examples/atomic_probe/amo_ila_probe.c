// ILA capture aid: hammer amoadd.d at a distinctive HBM address in a tight loop
// so the System ILA on cva6_0/m_axi can trigger on it easily. The address
// 0x90000000 is far from instruction fetches (0x8000_xxxx) and the stack, so
// triggering the ILA on AWADDR/ARADDR == 0x90000000 isolates the AMO cleanly.
//
// Recognizable values in the waveform:
//   memory init = 0xAAAAAAAAAAAAAAAA   (the normal write-through store)
//   amo operand = 0x1111111111111111
//   correct RMW result (mst WDATA) = 0xBBBBBBBBBBBBBBBB, and the AMO's R/old
//   beat should return 0xAAAA... If RDATA is 0xdec0dee3.. or RRESP != OKAY,
//   the read is the culprit; if WDATA/BRESP are wrong, the writeback is.
//
// Loops forever (never hits the finisher) so CVA6 keeps issuing AMOs while you
// arm/trigger the ILA. run_baremetal will "time out" — that's expected here.
#include "bsp.h"

int main(int hartid, void *dtb)
{
    (void)hartid; (void)dtb;
    volatile uint64_t *p = (volatile uint64_t *)0x90000000UL;

    uart_puts("amo_ila_probe: hammering amoadd.d @ 0x90000000\n");
    *p = 0xaaaaaaaaaaaaaaaaULL;                 // write-through store (reaches HBM)

    for (;;) {
        __atomic_fetch_add(p, 0x1111111111111111ULL, __ATOMIC_SEQ_CST);
        *p = 0xaaaaaaaaaaaaaaaaULL;             // reset so every AMO sees the same old value
    }
}
