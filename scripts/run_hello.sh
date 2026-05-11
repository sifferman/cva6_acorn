#!/usr/bin/env bash
# Load hello.bin into DRAM, release CVA6 from reset, wait, dump the console.
#
# Requires the Xilinx XDMA Linux driver (dma_ip_drivers) producing
# /dev/xdma0_h2c_0 and /dev/xdma0_c2h_0 character devices.
set -euo pipefail

DMA_TO_DEV="${DMA_TO_DEV:-$(command -v dma_to_device)}"
DMA_FROM_DEV="${DMA_FROM_DEV:-$(command -v dma_from_device)}"
if [[ -z "$DMA_TO_DEV" || -z "$DMA_FROM_DEV" ]]; then
    echo "dma_to_device / dma_from_device not found on PATH" >&2
    exit 1
fi

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
printf '\x00\x00\x00\x00' | sudo "$DMA_TO_DEV" -d "$H2C" -a "$CTRL_BASE" -s 4 -f /dev/stdin

echo "[*] Loading $HELLO_BIN into DRAM @ $DRAM_BASE"
SIZE=$(stat -c%s "$HELLO_BIN")
sudo "$DMA_TO_DEV" -d "$H2C" -a "$DRAM_BASE" -s "$SIZE" -f "$HELLO_BIN"

echo "[*] Clearing console buffer header"
printf '\x00\x00\x00\x00' | sudo "$DMA_TO_DEV" -d "$H2C" -a "$CONSOLE_BASE" -s 4 -f /dev/stdin

echo "[*] Releasing CVA6 reset"
printf '\x01\x00\x00\x00' | sudo "$DMA_TO_DEV" -d "$H2C" -a "$CTRL_BASE" -s 4 -f /dev/stdin

TMP=$(mktemp /tmp/c2h.XXXXXX)
rm -f "$TMP"
trap 'sudo rm -f "$TMP"' EXIT

c2h_read() {
    local addr=$1 size=$2
    sudo rm -f "$TMP"
    sudo "$DMA_FROM_DEV" -d "$C2H" -a "$addr" -s "$size" -f "$TMP" > /dev/null
    sudo chown "$USER:$USER" "$TMP"
    sudo chmod 644 "$TMP"
}

echo "[*] Polling STATUS for completion"
for i in $(seq 1 100); do
    c2h_read $((CTRL_BASE + CTRL_STATUS_OFF)) 4
    STATUS_HEX=$(xxd -p "$TMP")
    if [[ "$STATUS_HEX" != "00000000" ]]; then
        echo "[*] CVA6 signalled completion (status=$STATUS_HEX)"
        break
    fi
    sleep 0.1
done

echo "[*] Reading console length"
c2h_read "$CONSOLE_BASE" 4
LEN_HEX=$(xxd -p "$TMP")
LEN=$((16#${LEN_HEX:6:2}${LEN_HEX:4:2}${LEN_HEX:2:2}${LEN_HEX:0:2}))
echo "[*] Console length: $LEN bytes"

if (( LEN > 0 && LEN < 65532 )); then
    echo "[*] Console contents:"
    c2h_read $((CONSOLE_BASE + 4)) "$LEN"
    cat "$TMP"
    echo
fi
