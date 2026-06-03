// Ground-truth test: does a CVA6 write-through store actually reach HBM?
// Stores a recognizable value to a known address, NO atomics (so nothing
// corrupts DRAM), then exits. The host then reads the physical address to see
// what landed. cell is at 0x80000620 (program loads at 0x80000000, no MMU).
#include "bsp.h"

static volatile uint64_t cell __attribute__((aligned(8)));

int main(int hartid, void *dtb)
{
    (void)hartid; (void)dtb;
    cell = 0xcafef00dd00dcafeULL;            // single write-through store
    printf("stored 0xcafef00dd00dcafe; cache reads %016lx\n", cell);
    printf("now host-read phys 0x%08lx\n", (unsigned long)&cell);
    return 0;
}
