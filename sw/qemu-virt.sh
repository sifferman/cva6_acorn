#!/usr/bin/env bash
# Wrapper for the Xilinx-bundled qemu-system-riscv64 on this build server
# (no standalone QEMU installed). Runs it through the SDK sysroot's loader so
# the hardcoded-buildpath interpreter doesn't bite. Usage:
#   ./qemu-virt.sh -machine virt -bios none -nographic -kernel examples/hello/hello.elf
# or:  make qemu-run QEMU=./qemu-virt.sh
QBASE="/opt/Xilinx/2025.2/data/emulation/qemu/comp/qemu/sysroots/x86_64-petalinux-linux"
exec "$QBASE/lib/ld-linux-x86-64.so.2" --library-path "$QBASE/usr/lib:$QBASE/lib" \
    "$QBASE/usr/bin/qemu-system-riscv64" "$@"
