// 16550 UART0 console + SiFive test finisher exit. Pure MMIO, no libc.
#include "bsp.h"

// NS16550 register offsets (reg-shift 0, byte registers — QEMU virt UART0).
#define UART_RBR 0   // R: receive buffer (DLAB=0)
#define UART_THR 0   // W: transmit holding (DLAB=0)
#define UART_LSR 5   // R: line status
#define LSR_DR   0x01   // data ready
#define LSR_THRE 0x20   // transmit holding register empty

static volatile uint8_t *const uart = (volatile uint8_t *)VIRT_UART0_BASE;

void uart_putc(char c)
{
    while (!(uart[UART_LSR] & LSR_THRE))
        ;
    uart[UART_THR] = (uint8_t)c;
}

void uart_puts(const char *s)
{
    for (; *s; ++s)
        uart_putc(*s);
}

int uart_getc(void)
{
    if (uart[UART_LSR] & LSR_DR)
        return uart[UART_RBR];
    return -1;
}

void _exit(int code)
{
    volatile uint32_t *finisher = (volatile uint32_t *)VIRT_TEST_BASE;
    *finisher = code ? (((uint32_t)code << 16) | FINISH_FAIL) : FINISH_PASS;
    // Finisher exits QEMU and raises usr_irq on the card; loop just in case.
    for (;;)
        __asm__ volatile("wfi");
}
