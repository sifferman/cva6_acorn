// Vanilla baremetal RV64 "hello world". Identical binary runs on
//   qemu-system-riscv64 -machine virt -bios none -kernel hello.elf
// and on the FK33 card (which mirrors QEMU virt's device map).
//
// Console is the 16550 UART0 @ 0x10000000; returning from main() exits via the
// SiFive test finisher @ 0x100000 (exit code = return value).
#include "bsp.h"

int main(int hartid, void *dtb)
{
    uart_puts("Hello, FPGA!\n");
    printf("hartid=%d dtb=%p\n", hartid, dtb);
    return 0;
}
