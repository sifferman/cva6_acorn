// Atomics diagnostic v2 for CVA6 + axi_riscv_atomics (RV64IMAC/IMAFDC, WT cache).
//
// v1 showed every amo* returns a constant stale "old" (0xdec0dee3..) and the
// cell looks unchanged. Two theories: (A) the write-through store hasn't reached
// DRAM when the adapter's AMO read (which bypasses the cache) fires — a store->
// AMO ordering/visibility gap; or (B) the adapter's injected read isn't hitting
// the real address. This probe discriminates them.
//
// KEY TRICK: `amofetch_add(&cell, 0)` is a NON-DESTRUCTIVE read of *memory* via
// the AMO datapath (returns current value, writes it back unchanged). Comparing
// that to the cached view and repeating it tells us exactly what the AMO path
// sees vs what the core's cache holds.
#include "bsp.h"

static volatile uint64_t cell __attribute__((aligned(8)));

#define P(label, v) printf("  %s = %016lx\n", label, (uint64_t)(v))

int main(int hartid, void *dtb)
{
    (void)hartid; (void)dtb;
    printf("atomic probe v2 (amoadd+0 = non-destructive memory read via AMO)\n");

    const uint64_t INIT = 0x1111111122222222ULL;
    const uint64_t INC  = 0x0000000000001000ULL;

    cell = INIT;                                              // write-through store
    uint64_t cached_before = cell;                            // cache view (should be INIT)
    uint64_t peek0 = __atomic_fetch_add(&cell, 0, __ATOMIC_SEQ_CST); // AMO reads memory
    uint64_t peek1 = __atomic_fetch_add(&cell, 0, __ATOMIC_SEQ_CST); // AMO reads memory again

    printf("[store INIT, then read memory via amoadd+0 twice]\n");
    P("cached_before", cached_before);   // INIT if cache ok
    P("peek0(mem)",    peek0);           // INIT if AMO sees the store; stale if ordering bug
    P("peek1(mem)",    peek1);           // if peek0 stale but peek1==INIT -> store landed late

    // Now a REAL amoadd, then peek memory and cache to see if the add landed.
    uint64_t old = __atomic_fetch_add(&cell, INC, __ATOMIC_SEQ_CST);
    uint64_t peek2 = __atomic_fetch_add(&cell, 0, __ATOMIC_SEQ_CST);
    uint64_t cached_after = cell;
    printf("[amoadd INC, expect mem=INIT+INC=%016lx]\n", INIT + INC);
    P("old(returned)", old);             // should be INIT
    P("peek2(mem)",    peek2);           // should be INIT+INC
    P("cached_after",  cached_after);    // should be INIT+INC (cache coherent with AMO?)

    // Fence variant: does a full fence between store and AMO fix the read?
    cell = 0xAAAAAAAABBBBBBBBULL;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    uint64_t peek_fenced = __atomic_fetch_add(&cell, 0, __ATOMIC_SEQ_CST);
    printf("[store + fence + amoadd+0]\n");
    P("peek_fenced",   peek_fenced);     // 0xAAAA..BBBB if fence orders store->AMO

    printf("RESULT (interpret above; no pass/fail)\n");
    return 0;                                                 // PASS so the finisher fires
}
