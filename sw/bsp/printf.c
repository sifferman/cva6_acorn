// Tiny freestanding printf over the 16550 console. Supports:
//   %c  %s  %d/%i (int)  %u (unsigned)  %x (unsigned hex)  %p (pointer)  %%
//   length modifier 'l' (64-bit: %ld %lu %lx) and zero-padded width (%016lx).
// No precision, no non-zero pad, no other flags — deliberately minimal, but
// enough to print fixed-width 64-bit hashes for differential comparison.
#include "bsp.h"

static void put_uint(uint64_t v, unsigned base, int width)
{
    char buf[20];          // enough for 64-bit in any base >= 8
    int i = 0;
    if (v == 0)
        buf[i++] = '0';
    while (v) {
        unsigned d = (unsigned)(v % base);
        buf[i++] = (char)(d < 10 ? '0' + d : 'a' + (d - 10));
        v /= base;
    }
    for (int pad = width - i; pad > 0; pad--)   // left-pad with '0' to width
        uart_putc('0');
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
        ++fmt;
        int width = 0;
        if (*fmt == '0') ++fmt;                 // accept (and require) zero-pad
        while (*fmt >= '0' && *fmt <= '9')
            width = width * 10 + (*fmt++ - '0');
        int is_long = 0;
        if (*fmt == 'l') { is_long = 1; ++fmt; }
        switch (*fmt) {
        case 'c': uart_putc((char)va_arg(ap, int)); break;
        case 's': uart_puts(va_arg(ap, const char *)); break;
        case 'd':
        case 'i': put_int(is_long ? va_arg(ap, int64_t) : va_arg(ap, int)); break;
        case 'u': put_uint(is_long ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 10, width); break;
        case 'x': put_uint(is_long ? va_arg(ap, uint64_t) : va_arg(ap, unsigned), 16, width); break;
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
