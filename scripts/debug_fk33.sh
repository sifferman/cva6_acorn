#!/usr/bin/env bash
# FK33 bring-up diagnostic ladder. Run on the DEVICE machine (the one with the
# Acorn/FK33 card and the XDMA driver loaded), not the build server.
#
# Isolates "console buffer is empty" into one of:
#   (1) PCIe/XDMA link dead              -> XDMA char devs missing / all reads fail
#   (2) AXI fabric to BRAM slaves dead   -> SCRATCH/console loopback fails
#   (3) clk_wiz unlocked / HBM uncalibrated -> BRAM loopback OK but HBM rw fails
#   (4) CVA6 never released / never ran  -> HBM OK, binary loads, but STATUS stays 0
#
# Case (3) is the prime FK33 suspect: the MMCM input moved to the board
# sysclk_200 oscillator. No lock => CVA6 held in reset AND HBM never calibrates,
# yet the PCIe-clocked console BRAM still answers => "runs clean, empty console".

set -uo pipefail   # NOTE: no -e; we want to keep going after a failed probe.

DMA_TO_DEV="${DMA_TO_DEV:-$(command -v dma_to_device || true)}"
DMA_FROM_DEV="${DMA_FROM_DEV:-$(command -v dma_from_device || true)}"
H2C=/dev/xdma0_h2c_0
C2H=/dev/xdma0_c2h_0

DRAM_BASE=0x80000000
CONSOLE_BASE=0x40000000
CTRL_BASE=0x60000000
SCRATCH=0x6000000C     # CTRL+0xC, free RW register, safe to clobber
STATUS=0x60000008      # CTRL+0x8, written by CVA6
CTRL_RST=0x60000000    # CTRL+0x0, bit0 = release CVA6

HELLO_BIN="${HELLO_BIN:-sw/hello/hello.bin}"

TMP=$(mktemp /tmp/fk33dbg.XXXXXX); rm -f "$TMP"
trap 'sudo rm -f "$TMP"' EXIT

pass(){ echo "    PASS: $*"; }
fail(){ echo "    FAIL: $*"; }

wr(){ # wr <addr> <4-byte-hex-le e.g. deadbeef>
    local addr=$1 hex=$2
    printf "$(echo "$hex" | sed 's/../\\x&/g')" \
        | sudo "$DMA_TO_DEV" -d "$H2C" -a "$addr" -s 4 -f /dev/stdin >/dev/null 2>&1
}
rd(){ # rd <addr> <size> -> hex on stdout
    sudo rm -f "$TMP"
    sudo "$DMA_FROM_DEV" -d "$C2H" -a "$1" -s "$2" -f "$TMP" >/dev/null 2>&1
    xxd -p "$TMP" 2>/dev/null | tr -d '\n'
}

echo "=== 0. XDMA driver / char devices ==========================="
if [[ -z "$DMA_TO_DEV" || -z "$DMA_FROM_DEV" ]]; then
    fail "dma_to_device / dma_from_device not on PATH (build dma_ip_drivers/tools)"
fi
ls -l /dev/xdma0_* 2>&1 | sed 's/^/    /'
[[ -e "$H2C" && -e "$C2H" ]] && pass "char devices present" \
    || { fail "char devices missing -> driver not loaded or PCIe not enumerated"; \
         echo "    -> check: lspci -d 10ee: ; dmesg | grep -i xdma ; sudo modprobe xdma"; }
echo "    --- recent XDMA dmesg ---"
sudo dmesg 2>/dev/null | grep -iE "xdma|usr_irq" | tail -n 8 | sed 's/^/    /'

echo
echo "=== 1. AXI fabric -> SCRATCH register (PCIe-clocked) ========="
echo "    (proves host can reach BRAM/reg slaves; independent of clk_wiz/HBM)"
wr "$SCRATCH" "efbeadde"          # writes 0xdeadbeef LE
got=$(rd "$SCRATCH" 4)
echo "    wrote deadbeef, read back: ${got:-<none>}"
[[ "$got" == "efbeadde" ]] && pass "fabric to ctrl-regs alive" \
    || fail "cannot read/write SCRATCH -> XDMA reaches card but not user AXI (clock/reset/addr-map)"

echo
echo "=== 2. Console buffer loopback (PCIe-clocked BRAM) =========="
wr "$CONSOLE_BASE" "78563412"     # 0x12345678 LE at console+0
got=$(rd "$CONSOLE_BASE" 4)
echo "    wrote 12345678, read back: ${got:-<none>}"
[[ "$got" == "78563412" ]] && pass "console BRAM rw OK (host read path is fine)" \
    || fail "console BRAM rw broken"
wr "$CONSOLE_BASE" "00000000"     # clear header again

echo
echo "=== 3. HBM / DRAM @ 0x80000000 (clk_wiz lock + calibration) =="
echo "    *** THE FK33 SMOKING GUN: if step 2 passed but this fails, ***"
echo "    *** clk_wiz never locked or HBM never calibrated.          ***"
wr "$DRAM_BASE" "0dd0feca"        # 0xcafed00d LE
got=$(rd "$DRAM_BASE" 4)
echo "    wrote cafed00d, read back: ${got:-<none>}"
if [[ "$got" == "0dd0feca" ]]; then
    pass "HBM read/write works -> clk_wiz locked, HBM calibrated"
    HBM_OK=1
else
    fail "HBM not writable -> MMCM unlocked or HBM uncalibrated"
    echo "    -> CVA6 is almost certainly held in reset too (shares clk_wiz lock)."
    echo "    -> Check sysclk_200 pin/constraint in vivado/sqrl_fk33.xdc and that"
    echo "       the 200 MHz board oscillator is actually present on this part."
    HBM_OK=0
fi

echo
echo "=== 4. Load firmware + verify it landed in DRAM ============="
if [[ "${HBM_OK:-0}" == "1" && -f "$HELLO_BIN" ]]; then
    SIZE=$(stat -c%s "$HELLO_BIN")
    sudo "$DMA_TO_DEV" -d "$H2C" -a "$DRAM_BASE" -s "$SIZE" -f "$HELLO_BIN" >/dev/null 2>&1
    want=$(xxd -p -l 16 "$HELLO_BIN" | tr -d '\n')
    got=$(rd "$DRAM_BASE" 16)
    echo "    bin first16:  $want"
    echo "    dram first16: $got"
    [[ "$want" == "$got" ]] && pass "hello.bin present in DRAM" \
        || fail "DRAM readback != binary (HBM data integrity / addressing)"
else
    echo "    skipped (HBM not OK, or $HELLO_BIN missing on this machine)"
fi

echo
echo "=== 5. Bootrom present @ 0x10000 ============================"
got=$(rd 0x00010000 16)
echo "    bootrom first16: ${got:-<none>}"
[[ -n "$got" && "$got" != "00000000000000000000000000000000" ]] \
    && pass "bootrom BRAM non-zero (memh initialised)" \
    || fail "bootrom reads zero -> bootrom.memh not loaded into BRAM at synth"

echo
echo "=== 6. Release CVA6 and watch STATUS / console ============="
wr "$CONSOLE_BASE" "00000000"     # clear console length
wr "$STATUS" "00000000"           # (host can't really clear it, but harmless)
echo "    asserting reset (CTRL=0)..."; wr "$CTRL_RST" "00000000"
echo "    CTRL readback: $(rd "$CTRL_RST" 4)  (expect 00000000)"
echo "    releasing reset (CTRL=1)..."; wr "$CTRL_RST" "01000000"
echo "    CTRL readback: $(rd "$CTRL_RST" 4)  (expect 01000000 -> reg latched)"
echo "    polling STATUS @ $STATUS for 5s..."
for i in $(seq 1 50); do
    st=$(rd "$STATUS" 4)
    if [[ -n "$st" && "$st" != "00000000" ]]; then
        echo "    STATUS=$st after $((i*100))ms -> CVA6 RAN and signalled done"; break
    fi
    sleep 0.1
done
[[ "${st:-00000000}" == "00000000" ]] && \
    fail "STATUS stayed 0 -> CVA6 never reached the doorbell store (no clock / still in reset / hung)"
len=$(rd "$CONSOLE_BASE" 4)
echo "    console length word: ${len:-<none>}"
echo
echo "=== interpretation ==========================================="
echo "  step2 PASS, step3 FAIL  -> clk_wiz/sysclk_200 lock or HBM calibration (FK33)"
echo "  step2 FAIL              -> XDMA reaches card but AXI fabric/addr-map broken"
echo "  step0 FAIL              -> driver/PCIe enumeration problem"
echo "  all PASS but step6 0    -> CVA6 reset/clock path (cpu_rstgen aux_reset_in)"
