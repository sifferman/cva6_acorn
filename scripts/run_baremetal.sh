#!/usr/bin/env bash
# Run a vanilla baremetal RV64 program on the FK33 card over XDMA.
#
# The card mirrors the QEMU `virt` device map, so the SAME binary that runs on
#   qemu-system-riscv64 -machine virt -bios none -kernel prog.elf
# runs here. This script:
#   1. holds CVA6 in reset
#   2. loads the program .bin to DRAM   (0x80000000)
#   3. loads the device tree blob       (0x88000000, passed to the guest in a1)
#   4. releases reset
#   5. streams the 16550 UART TX capture to stdout while polling the finisher
#
# Requires the Xilinx XDMA driver (dma_to_device / dma_from_device on PATH and
# /dev/xdma0_h2c_0 + /dev/xdma0_c2h_0). Run on the DEVICE machine.
#
# Usage: run_baremetal.sh [program.bin] [dtb]
#   defaults: sw/examples/hello/hello.bin  sw/dts/fk33-virt.dtb
set -uo pipefail

PROG="${1:-sw/examples/hello/hello.bin}"
DTB="${2:-sw/dts/fk33-virt.dtb}"

DMA_TO_DEV="${DMA_TO_DEV:-$(command -v dma_to_device || true)}"
DMA_FROM_DEV="${DMA_FROM_DEV:-$(command -v dma_from_device || true)}"
H2C=/dev/xdma0_h2c_0
C2H=/dev/xdma0_c2h_0

# Guest-visible (QEMU virt) map.
DRAM_BASE=0x80000000
DTB_BASE=0x88000000
CTRL_BASE=0x60000000          # ctrl_regs: CTRL[0] = release CVA6 (host-only)
FINISH_BASE=0x100000          # sifive_test finisher
UART_TXLEN=0x10010000         # UART TX-drain: tx_len (32-bit)
UART_TXDATA=0x10010008        # UART TX-drain: payload bytes

TIMEOUT_S="${TIMEOUT_S:-10}"

if [[ -z "$DMA_TO_DEV" || -z "$DMA_FROM_DEV" ]]; then
    echo "dma_to_device / dma_from_device not on PATH" >&2; exit 1
fi
if [[ ! -e "$H2C" || ! -e "$C2H" ]]; then
    echo "XDMA char devices missing — load the driver after rebooting." >&2; exit 1
fi
[[ -f "$PROG" ]] || { echo "program not found: $PROG" >&2; exit 1; }
[[ -f "$DTB"  ]] || { echo "dtb not found: $DTB" >&2; exit 1; }

TMP=$(mktemp /tmp/c2h.XXXXXX); rm -f "$TMP"
trap 'sudo rm -f "$TMP"' EXIT

wr32() {  # wr32 <addr> <value>
    local a=$1 v=$2
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((v & 0xff)) $(((v>>8) & 0xff)) $(((v>>16) & 0xff)) $(((v>>24) & 0xff)))" \
        | sudo "$DMA_TO_DEV" -d "$H2C" -a "$a" -s 4 -f /dev/stdin >/dev/null
}
rd32() {  # rd32 <addr> -> decimal value (4-byte LE)
    sudo rm -f "$TMP"
    sudo "$DMA_FROM_DEV" -d "$C2H" -a "$1" -s 4 -f "$TMP" >/dev/null 2>&1
    local h; h=$(xxd -p "$TMP")
    echo $((16#${h:6:2}${h:4:2}${h:2:2}${h:0:2}))
}
read_range() {  # read_range <addr> <size> -> fills $TMP
    sudo rm -f "$TMP"
    sudo "$DMA_FROM_DEV" -d "$C2H" -a "$1" -s "$2" -f "$TMP" >/dev/null 2>&1
    sudo chown "$USER:$USER" "$TMP" 2>/dev/null
}

echo "[*] Holding CVA6 in reset"
wr32 "$CTRL_BASE" 0

PROG_SZ=$(stat -c%s "$PROG")
echo "[*] Loading $PROG ($PROG_SZ B) -> DRAM @ $DRAM_BASE"
sudo "$DMA_TO_DEV" -d "$H2C" -a "$DRAM_BASE" -s "$PROG_SZ" -f "$PROG" >/dev/null

DTB_SZ=$(stat -c%s "$DTB")
echo "[*] Loading $DTB ($DTB_SZ B) -> DTB @ $DTB_BASE"
sudo "$DMA_TO_DEV" -d "$H2C" -a "$DTB_BASE" -s "$DTB_SZ" -f "$DTB" >/dev/null

# Clear residual peripheral state. On bitstreams with the clear paths this wipes
# the finisher (FINISH_RESET=0x7777) and rewinds the UART capture buffer; on
# older bitstreams these are no-ops and the snapshot below still handles residue.
wr32 "$FINISH_BASE" 0x7777
wr32 "$UART_TXLEN"  0

# Snapshot peripheral state BEFORE release so we stream only THIS run's bytes and
# detect a fresh finisher write rather than a stale one.
prev=$(rd32 "$UART_TXLEN")
fin0=$(rd32 "$FINISH_BASE")
if [[ "$fin0" != "0" ]]; then
    echo "[!] finisher pre-latched (0x$(printf %08x "$fin0")) from a prior run — reset the device (reboot/PCIe reset) for a pristine finisher result." >&2
fi

echo "[*] Releasing CVA6 reset"
wr32 "$CTRL_BASE" 1

echo "[*] ---- console ----"
deadline=$((SECONDS + TIMEOUT_S))
finish=$fin0
drain() {  # print any newly-captured UART bytes (aligned full read + local slice)
    local len; len=$(rd32 "$UART_TXLEN")
    if (( len > prev )); then
        read_range "$UART_TXDATA" "$len"      # aligned start (0x...08)
        tail -c "+$((prev + 1))" "$TMP"
        prev=$len
    fi
}
while (( SECONDS < deadline )); do
    drain
    finish=$(rd32 "$FINISH_BASE")
    (( finish != fin0 )) && break          # fresh finisher write this run
    sleep 0.05
done
drain   # final drain between last poll and the finisher write
echo
echo "[*] ------------------"

if (( finish == fin0 )); then
    echo "[!] Finisher unchanged within ${TIMEOUT_S}s (guest still running, hung, or finisher pre-latched to the same value)." >&2
    exit 2
fi
cmd=$((finish & 0xffff))
code=$(( (finish >> 16) & 0xffff ))
if (( cmd == 0x5555 )); then
    echo "[*] Guest exited PASS (finisher=0x$(printf %08x "$finish"))"
    exit 0
elif (( cmd == 0x3333 )); then
    echo "[!] Guest exited FAIL, code=$code (finisher=0x$(printf %08x "$finish"))" >&2
    exit 1
else
    echo "[?] Unexpected finisher value 0x$(printf %08x "$finish")" >&2
    exit 3
fi
