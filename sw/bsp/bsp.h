// Minimal baremetal BSP for the QEMU `virt` platform (and the FK33 card, which
// mirrors virt's device map). The same binary built against this header runs on
// `qemu-system-riscv64 -machine virt -bios none -kernel <elf>` and on the card.
#ifndef BSP_H
#define BSP_H

#include <stdint.h>
#include <stddef.h>
#include <stdarg.h>

// --- QEMU virt device addresses (identical on the FK33 card) ----------------
#define VIRT_TEST_BASE  0x00100000UL   // SiFive test finisher (exit)
#define VIRT_UART0_BASE 0x10000000UL   // NS16550 UART, reg-shift 0
#define VIRT_DRAM_BASE  0x80000000UL

// SiFive test finisher commands.
#define FINISH_FAIL     0x3333
#define FINISH_PASS     0x5555
#define FINISH_RESET    0x7777

// --- Console (16550 UART0) --------------------------------------------------
void uart_putc(char c);
void uart_puts(const char *s);          // raw: no trailing newline added
int  uart_getc(void);                   // -1 if no byte available

// Tiny printf: %c %s %d %i %u %x %p %% (no width/precision/flags).
int  printf(const char *fmt, ...);
int  vprintf(const char *fmt, va_list ap);

// --- Exit -------------------------------------------------------------------
// code 0 -> finisher PASS; nonzero -> finisher FAIL with code in the high bits.
void _exit(int code) __attribute__((noreturn));

#endif // BSP_H
