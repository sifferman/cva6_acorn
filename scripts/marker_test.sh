#!/usr/bin/env bash
# Load the marker program, let CVA6 run briefly, re-hold reset to quiesce it,
# then read the last progress marker + UART/finisher state.
set -uo pipefail
TO=$(command -v dma_to_device); FROM=$(command -v dma_from_device)
H2C=/dev/xdma0_h2c_0; C2H=/dev/xdma0_c2h_0
BIN=sw/examples/marker/marker.bin
TMP=$(mktemp); trap 'sudo rm -f "$TMP"' EXIT
wr32(){ printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(($2&0xff)) $((($2>>8)&0xff)) $((($2>>16)&0xff)) $((($2>>24)&0xff)))" | sudo "$TO" -d $H2C -a "$1" -s 4 -f /dev/stdin >/dev/null; }
rdx(){ if sudo "$FROM" -d $C2H -a "$1" -s 4 -f "$TMP" >/dev/null 2>&1; then sudo chown "$USER:$USER" "$TMP" 2>/dev/null; xxd -p "$TMP"; else echo "READ-FAILED"; fi; }

# sanity: refuse to load an ELF (must be a raw image)
if [ "$(xxd -p -l4 "$BIN")" = "7f454c46" ]; then echo "ERROR: $BIN is an ELF, not raw. Run objcopy -O binary." >&2; exit 1; fi

echo "[*] hold reset";        wr32 0x60000000 0
echo "[*] clear STATUS";      wr32 0x60000008 0
echo "[*] load $BIN -> 0x80000000"; sudo "$TO" -d $H2C -a 0x80000000 -s "$(stat -c%s "$BIN")" -f "$BIN" >/dev/null
echo "[*] verify @0x80000000 = $(rdx 0x80000000) (want f32240f1, NOT 7f454c46)"
echo "[*] release reset";     wr32 0x60000000 1
sleep 1
echo "[*] re-hold reset (quiesce CVA6; STATUS marker survives)"; wr32 0x60000000 0
echo
echo "marker   (STATUS 0x60000008) = $(rdx 0x60000008)   [10=main 60200000=readLSR-ok/hung-write 30=THR-ok 40=all-returned]"
echo "uart_len (0x10010000)        = $(rdx 0x10010000)   [>01000000 => CVA6 THR write LANDED]"
echo "finisher (0x100000)          = $(rdx 0x100000)     [55550000 => CVA6 finisher write LANDED]"
