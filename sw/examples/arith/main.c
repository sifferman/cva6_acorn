// Arithmetic-consistency validation kernel for CVA6 (RV64IMAC, no FPU).
//
// The SAME binary runs on `qemu-system-riscv64 -machine virt` (the golden
// reference) and on the FK33 card. It hammers the integer ALU, the hardware
// multiplier/divider (M), and the atomics unit (A) with runtime-generated
// operands, folds every result into a 64-bit FNV-1a hash per section, and
// compares each section's hash against a value captured from QEMU. A divergence
// means CVA6's RTL computed something QEMU (a spec-correct emulator) did not.
//
// Operands come from a runtime PRNG and pass through asm barriers so the
// compiler cannot constant-fold the work away at -Os: the silicon must actually
// execute the ops. Each section's verdict is printed AS IT COMPLETES, so a hang
// on the card pinpoints the offending unit (the last line printed is the last
// section that finished). Exit is PASS (0) / FAIL (#bad sections) via the
// SiFive finisher.
#include "bsp.h"

// Atomics (lr/sc, amo*) require the axi_riscv_atomics adapter in the RTL (in
// cva6_acorn_core.sv, with the FIXED->INCR burst remap). That adapter is now in
// the default bitstream and AMOs are verified working on HW, so the atomics
// section runs by DEFAULT. (QEMU virt supports atomics too, so the default build
// also passes there.) On a legacy bitstream WITHOUT the adapter CVA6's AMOs hang
// the core in this section — build with atomics off to validate just the integer
// ISA there:
//     make examples/arith/arith.bin EXTRA_CFLAGS=-DTEST_ATOMICS=0
#ifndef TEST_ATOMICS
#define TEST_ATOMICS 1
#endif

// --- opaque barrier: stop the compiler folding operands/results -------------
#define BARRIER_I(x) __asm__ volatile("" : "+r"(x))

// --- xorshift64* PRNG: runtime operand source -------------------------------
static uint64_t rng_state = 0x123456789abcdef0ULL;
static uint64_t rng(void)
{
    uint64_t x = rng_state;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    rng_state = x;
    return x * 0x2545f4914f6cdd1dULL;
}

// --- 64-bit FNV-1a accumulator (per-section: reset at each section start) ----
#define FNV_OFFSET 0xcbf29ce484222325ULL
#define FNV_PRIME  0x00000100000001b3ULL
static uint64_t h;
static void mix_u64(uint64_t v)
{
    for (int i = 0; i < 8; i++) {
        h ^= (v >> (i * 8)) & 0xff;
        h *= FNV_PRIME;
    }
}

#define ITERS 512

// A section runs under a fresh hash and returns its digest. PRNG state carries
// across sections, so each section's golden value is order-dependent (don't
// reorder the CHECK() calls in main without re-capturing the goldens).
#define SECTION(name, ...)                       \
    static uint64_t sec_##name(void)             \
    {                                            \
        h = FNV_OFFSET;                          \
        __VA_ARGS__                              \
        return h;                                \
    }

// --- 64-bit integer mul / div / rem (M extension) ---------------------------
SECTION(int64, {
    for (int i = 0; i < ITERS; i++) {
        uint64_t a = rng(), b = rng();
        BARRIER_I(a); BARRIER_I(b);
        if (b == 0) b = 1;                            // skip div-by-zero (defined, but uninteresting)
        int64_t sa = (int64_t)a, sb = (int64_t)b;
        mix_u64(a * b);                               // mul
        mix_u64((uint64_t)((__int128)a * b >> 64));   // mulhu
        mix_u64((uint64_t)((__int128)sa * sb >> 64)); // mulh
        mix_u64(a / b);                               // divu
        mix_u64(a % b);                               // remu
        mix_u64((uint64_t)(sa / sb));                 // div
        mix_u64((uint64_t)(sa % sb));                 // rem
    }
})

// --- 32-bit word ops (sign-extension behavior: *w insns) --------------------
SECTION(word32, {
    for (int i = 0; i < ITERS; i++) {
        uint32_t a = (uint32_t)rng(), b = (uint32_t)rng();
        BARRIER_I(a); BARRIER_I(b);
        if (b == 0) b = 1;
        int32_t sa = (int32_t)a, sb = (int32_t)b;
        mix_u64((uint64_t)(int64_t)(sa + sb));        // addw (sign-extended to 64)
        mix_u64((uint64_t)(int64_t)(sa - sb));        // subw
        mix_u64((uint64_t)(int64_t)(sa * sb));        // mulw
        mix_u64((uint64_t)(int64_t)(sa / sb));        // divw
        mix_u64((uint64_t)(int64_t)(sa % sb));        // remw
        mix_u64((uint64_t)(int64_t)(int32_t)(a / b)); // divuw
    }
})

// --- shifts & logic (sll/srl/sra, and/or/xor) plus set-less-than ------------
SECTION(shift, {
    for (int i = 0; i < ITERS; i++) {
        uint64_t a = rng();
        unsigned s = (unsigned)(rng() & 63);
        BARRIER_I(a);
        mix_u64(a << s);
        mix_u64(a >> s);
        mix_u64((uint64_t)((int64_t)a >> s));         // arithmetic shift
        mix_u64(a & 0x0f0f0f0f0f0f0f0fULL);
        mix_u64(a | 0xa5a5a5a5a5a5a5a5ULL);
        mix_u64(a ^ 0x5555555555555555ULL);
        mix_u64((uint64_t)((int64_t)a < (int64_t)s)); // slt
        mix_u64((uint64_t)(a < s));                   // sltu
    }
})

// --- atomics (A extension): lr/sc + the amo* family -------------------------
// Single-hart functional check: no contention, just confirm each AMO computes
// the right new value and returns the right old value. GCC lowers the __atomic
// builtins to lr/sc (compare-exchange) and amoadd/swap/and/or/xor.
static uint64_t amo_cell;
SECTION(atomic, {
    amo_cell = 0;
    for (int i = 0; i < ITERS; i++) {
        uint64_t a = rng();
        BARRIER_I(a);
        mix_u64(__atomic_fetch_add(&amo_cell, a, __ATOMIC_SEQ_CST));
        mix_u64(__atomic_fetch_xor(&amo_cell, a, __ATOMIC_SEQ_CST));
        mix_u64(__atomic_fetch_and(&amo_cell, a, __ATOMIC_SEQ_CST));
        mix_u64(__atomic_fetch_or (&amo_cell, a, __ATOMIC_SEQ_CST));
        mix_u64(__atomic_exchange_n(&amo_cell, a, __ATOMIC_SEQ_CST)); // amoswap
        uint64_t expect = (i & 1) ? amo_cell : ~amo_cell;            // cmpxchg -> lr/sc
        uint64_t desired = a ^ 0x5a5a5a5a5a5a5a5aULL;
        mix_u64(__atomic_compare_exchange_n(&amo_cell, &expect, desired, 0,
                                            __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST));
        mix_u64(amo_cell);
    }
})

// Golden per-section hashes captured from qemu-system-riscv64 -machine virt
// (RV64IMAC, ITERS=512). CVA6 on the FPGA must reproduce each bit-for-bit; a
// mismatch is an RTL arithmetic bug in that unit. Re-capture (run under QEMU)
// if ITERS, the section bodies, or their order change.
#define CHECK(name, golden) do {                                  \
    uint64_t got = sec_##name();                                  \
    int ok = (got == (golden));                                   \
    printf("  %s = %016lx  %s\n", #name, got, ok ? "PASS" : "FAIL"); \
    if (!ok) fails++;                                             \
} while (0)

int main(int hartid, void *dtb)
{
    (void)hartid; (void)dtb;
    int fails = 0;

    printf("arith validation (RV64IMAC), %d iters/section\n", ITERS);
    CHECK(int64,  0xfc56cfb14048950bULL);
    CHECK(word32, 0x8e8ef845d7bd4debULL);
    CHECK(shift,  0xf6fd89aec278104bULL);
#if TEST_ATOMICS
    CHECK(atomic, 0x0eb8c7a4c2d8144aULL);
#else
    printf("  atomic = SKIPPED (TEST_ATOMICS=0)\n");
#endif

    if (fails == 0) {
        printf("RESULT PASS\n");
        return 0;
    }
    printf("RESULT FAIL (%d section(s))\n", fails);
    return fails;
}
