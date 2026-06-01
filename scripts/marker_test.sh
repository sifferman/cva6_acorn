#!/usr/bin/env bash
# Load the marker program, release CVA6, then read where it stalled.
set -uo pipefail
TO=$(command -v dma_to_device); FROM=$(command -v dma_from_device)
H2C=/dev/xdma0_h2c_0; C2H=/dev/xdma0_c2h_0
BIN=sw/examples/marker/marker.bin
TMP=$(mktemp); trap 'sudo rm -f "$TMP"' EXIT
wr32(){ printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($2&0xff)) $((($2>>8)&0xff)) $((($2>>16)&0xff)) $((($2>>24)&0xff)))" | sudo "$TO" -d $H2C -a "$1" -s 4 -f /dev/stdin >/dev/null; }
rdx(){ sudo "$FROM" -d $C2H -a "$1" -s 4 -f "$TMP" >/dev/null 2>&1 && xxd -p "$TMP"; }

echo "[*] hold reset"; wr32 0x60000000 0
echo "[*] clear STATUS marker"; wr32 0x60000008 0
echo "[*] load $BIN -> 0x80000000"; sudo "$TO" -d $H2C -a 0x80000000 -s $(stat -c%s "$BIN") -f "$BIN" >/dev/null
echo "[*] release reset"; wr32 0x60000000 1
sleep 1
echo
echo "marker   (STATUS 0x60000008) = $(rdx 0x60000008)   [10=main 2060=readLSR-ok,hung-write 30=THR-write-ok 40=all-writes-returned]"
echo "uart_len (0x10010000)        = $(rdx 0x10010000)   [grew past residue => CVA6 THR write LANDED]"
echo "finisher (0x100000)          = $(rdx 0x100000)     [55550000 => CVA6 finisher write LANDED]"
