#!/usr/bin/env bash
# Load hello.bin into DRAM, release CVA6 from reset, wait, dump the console.
#
# Requires the Xilinx XDMA Linux driver (dma_ip_drivers) producing
# /dev/xdma0_h2c_0 and /dev/xdma0_c2h_0 character devices.
set -euo pipefail

XDMA_TOOLS_DIR="${XDMA_TOOLS_DIR:-$HOME/dma_ip_drivers/XDMA/linux-kernel/tools}"
DMA_TO_DEV="${XDMA_TOOLS_DIR}/dma_to_device"
DMA_FROM_DEV="${XDMA_TOOLS_DIR}/dma_from_device"

H2C=/dev/xdma0_h2c_0
C2H=/dev/xdma0_c2h_0

HELLO_BIN="${HELLO_BIN:-sw/hello/hello.bin}"

DRAM_BASE=0x80000000
CONSOLE_BASE=0x40000000
CTRL_BASE=0x60000000
CTRL_RESET_OFF=0x0
CTRL_STATUS_OFF=0x8

if [[ ! -e "$H2C" ]]; then
    echo "XDMA char devices not present. Did you load the kernel module after rebooting?" >&2
    exit 1
fi

echo "[*] Holding CVA6 in reset"
printf '\x00\x00\x00\x00' | "$DMA_TO_DEV" -d "$H2C" -a "$CTRL_BASE" -s 4 -f /dev/stdin

echo "[*] Loading $HELLO_BIN into DRAM @ $DRAM_BASE"
SIZE=$(stat -c%s "$HELLO_BIN")
"$DMA_TO_DEV" -d "$H2C" -a "$DRAM_BASE" -s "$SIZE" -f "$HELLO_BIN"

echo "[*] Clearing console buffer header"
printf '\x00\x00\x00\x00' | "$DMA_TO_DEV" -d "$H2C" -a "$CONSOLE_BASE" -s 4 -f /dev/stdin

echo "[*] Releasing CVA6 reset"
printf '\x01\x00\x00\x00' | "$DMA_TO_DEV" -d "$H2C" -a "$CTRL_BASE" -s 4 -f /dev/stdin

echo "[*] Polling STATUS for completion"
for i in $(seq 1 100); do
    STATUS_HEX=$("$DMA_FROM_DEV" -d "$C2H" -a $((CTRL_BASE + CTRL_STATUS_OFF)) -s 4 -f /dev/stdout 2>/dev/null | xxd -p)
    if [[ "$STATUS_HEX" != "00000000" ]]; then
        echo "[*] CVA6 signalled completion (status=$STATUS_HEX)"
        break
    fi
    sleep 0.1
done

echo "[*] Reading console length"
LEN_HEX=$("$DMA_FROM_DEV" -d "$C2H" -a "$CONSOLE_BASE" -s 4 -f /dev/stdout 2>/dev/null | xxd -p)
LEN=$((16#${LEN_HEX:6:2}${LEN_HEX:4:2}${LEN_HEX:2:2}${LEN_HEX:0:2}))
echo "[*] Console length: $LEN bytes"

if (( LEN > 0 && LEN < 65532 )); then
    echo "[*] Console contents:"
    "$DMA_FROM_DEV" -d "$C2H" -a $((CONSOLE_BASE + 4)) -s "$LEN" -f /dev/stdout
    echo
fi
