// Tiny freestanding printf over the 16550 console. Supports:
//   %c  %s  %d/%i (int)  %u (unsigned)  %x (unsigned hex)  %p (pointer)  %%
// No field width, precision, or length modifiers — deliberately minimal.
#include "bsp.h"

static void put_uint(uint64_t v, unsigned base, int width_unused)
{
    char buf[20];          // enough for 64-bit in any base >= 8
    int i = 0;
    (void)width_unused;
    if (v == 0)
        buf[i++] = '0';
    while (v) {
        unsigned d = (unsigned)(v % base);
        buf[i++] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
        v /= base;
    }
    while (i)
        uart_putc(buf[--i]);
}

static void put_int(int64_t v)
{
    if (v < 0) {
        uart_putc('-');
        put_uint((uint64_t)(-v), 10, 0);
    } else {
        put_uint((uint64_t)v, 10, 0);
    }
}

int vprintf(const char *fmt, va_list ap)
{
    for (; *fmt; ++fmt) {
        if (*fmt != '%') {
            uart_putc(*fmt);
            continue;
        }
        switch (*++fmt) {
        case 'c': uart_putc((char)va_arg(ap, int)); break;
        case 's': uart_puts(va_arg(ap, const char *)); break;
        case 'd':
        case 'i': put_int(va_arg(ap, int)); break;
        case 'u': put_uint((unsigned)va_arg(ap, unsigned), 10, 0); break;
        case 'x': put_uint((unsigned)va_arg(ap, unsigned), 16, 0); break;
        case 'p':
            uart_puts("0x");
            put_uint((uint64_t)(uintptr_t)va_arg(ap, void *), 16, 0);
            break;
        case '%': uart_putc('%'); break;
        case '\0': return 0;
        default:  uart_putc('%'); uart_putc(*fmt); break;
        }
    }
    return 0;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int r = vprintf(fmt, ap);
    va_end(ap);
    return r;
}
