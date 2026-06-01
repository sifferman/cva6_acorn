#!/usr/bin/env bash
# FK33 host-side peripheral diagnostic for the QEMU-virt-compatible bitstream.
# Run on the DEVICE machine (XDMA driver loaded, /dev/xdma0_*). It checks that
# the host can reach and exercise each slave, independent of CVA6:
#
#   ctrl_regs   0x60000000   (SCRATCH @ +0xC  -> fabric reachability + lane fix)
#   uart16550   0x10000000   (regs; LSR must read 0x60; TX capture @ 0x10010000)
#   finisher    0x00100000   (sifive_test; read-only here, see note below)
#   HBM/DRAM    0x80000000   (clk_wiz lock + calibration)
#   bootrom     0x00010000   (reset-vector BRAM)
#
# This is a SUBSTRATE check. To run a guest program end-to-end use
# run_baremetal.sh. NOTE: the UART TX test below appends a couple of bytes to
# the capture buffer, and neither that buffer nor the finisher clear on a CVA6
# reset (only on a PCIe/driver reset). For clean run_baremetal output, reload
# the xdma driver (or power-cycle) after running this with the TX test.
set -uo pipefail

TO=$(command -v dma_to_device || true)
FROM=$(command -v dma_from_device || true)
H2C=/dev/xdma0_h2c_0
C2H=/dev/xdma0_c2h_0

CTRL_BASE=0x60000000
SCRATCH=0x6000000C
UART_REGS=0x10000000
UART_TXLEN=0x10010000
UART_TXDATA=0x10010008
FINISH=0x100000
HBM=0x80000000
BOOTROM=0x10000

if [[ -z "$TO" || -z "$FROM" ]]; then
    echo "dma_to_device / dma_from_device not on PATH" >&2; exit 1
fi
if [[ ! -e "$H2C" || ! -e "$C2H" ]]; then
    echo "XDMA char devices missing — is the Xilinx xdma driver bound? (ls /dev/xdma*)" >&2; exit 1
fi

TMP=$(mktemp /tmp/fk33dbg.XXXXXX); rm -f "$TMP"
trap 'sudo rm -f "$TMP"' EXIT
pass(){ echo "    PASS: $*"; }
fail(){ echo "    FAIL: $*"; }

rdhex(){ # rdhex <addr> <size> -> contiguous hex string ("" on failure)
    sudo rm -f "$TMP"
    sudo "$FROM" -d "$C2H" -a "$1" -s "$2" -f "$TMP" >/dev/null 2>&1 || { echo ""; return; }
    xxd -p "$TMP" | tr -d '\n'
}
rd32(){ # rd32 <addr> -> decimal (4-byte LE)
    local h; h=$(rdhex "$1" 4)
    [[ -n "$h" ]] && echo $((16#${h:6:2}${h:4:2}${h:2:2}${h:0:2})) || echo -1
}
wr32(){ # wr32 <addr> <value>
    local a=$1 v=$2
    printf "$(printf '\\x%02x\\x%02x\\x%02x\\x%02x' \
        $((v&0xff)) $(((v>>8)&0xff)) $(((v>>16)&0xff)) $(((v>>24)&0xff)))" \
        | sudo "$TO" -d "$H2C" -a "$a" -s 4 -f /dev/stdin >/dev/null 2>&1
}
wr8(){ # wr8 <addr> <byte>
    printf "$(printf '\\x%02x' $(( $2 & 0xff )))" \
        | sudo "$TO" -d "$H2C" -a "$1" -s 1 -f /dev/stdin >/dev/null 2>&1
}

echo "=== 0. XDMA driver / char devices ==========================="
ls -l /dev/xdma0_h2c_0 /dev/xdma0_c2h_0 2>&1 | sed 's/^/    /'
pass "char devices present"
echo "    --- recent xdma dmesg ---"
sudo dmesg 2>/dev/null | grep -iE "xdma" | tail -4 | sed 's/^/    /'

echo
echo "=== 1. ctrl_regs SCRATCH loopback @ $SCRATCH (fabric + lane fix) ==="
wr32 "$SCRATCH" $((0xdeadbeef))
got=$(rd32 "$SCRATCH")
printf "    wrote 0xdeadbeef, read back 0x%08x\n" "$got"
(( got == 0xdeadbeef )) && pass "host->AXI fabric alive; ctrl_regs upper-word R/W ok" \
    || fail "SCRATCH mismatch -> fabric/decode/lane problem"

echo
echo "=== 2. UART 16550 register read @ $UART_REGS (LSR must be 0x60) ==="
h=$(rdhex "$UART_REGS" 8)
echo "    reg bytes [0..7]: ${h:-<read failed>}"
if [[ -n "$h" ]]; then
    lsr=${h:10:2}; iir=${h:4:2}
    echo "    IIR(byte2)=0x$iir  LSR(byte5)=0x$lsr"
    [[ "$lsr" == "60" ]] && pass "UART responds; LSR THRE+TEMT set (TX ready)" \
        || fail "LSR != 0x60 -> UART read/decode wrong"
else
    fail "UART register read failed (slave not responding)"
fi

echo
echo "=== 3. UART TX capture: write a byte, expect tx_len to increment ==="
echo "    *** This is the write-path that was broken (undriven bvalid). ***"
prev=$(rd32 "$UART_TXLEN")
wr8 "$UART_REGS" 0x41          # 'A' -> THR (offset 0)
now=$(rd32 "$UART_TXLEN")
echo "    tx_len: $prev -> $now"
if (( now == prev + 1 )); then
    last=$(rdhex $((UART_TXDATA)) "$now"); last=${last: -2}
    echo "    last payload byte: 0x$last (expect 41 = 'A')"
    pass "UART AXI write completed (bvalid fix works)"
else
    fail "tx_len did not increment -> UART write still hanging/dropped"
fi

echo
echo "=== 4. sifive_test finisher read @ $FINISH (read-only) ==="
fin=$(rd32 "$FINISH")
printf "    finisher = 0x%08x\n" "$fin"
if (( fin == 0 )); then
    pass "finisher reachable, not latched (guest hasn't exited)"
else
    cmd=$((fin & 0xffff))
    if (( cmd == 0x5555 )); then echo "    (latched PASS — from a prior guest or host write; clears on device reset)"
    elif (( cmd == 0x3333 )); then echo "    (latched FAIL code=$(((fin>>16)&0xffff)))"
    else echo "    (unexpected latched value)"; fi
    pass "finisher reachable"
fi

echo
echo "=== 5. HBM / DRAM @ $HBM loopback (clk_wiz lock + calibration) ==="
wr32 "$HBM" $((0xcafed00d))
got=$(rd32 "$HBM")
printf "    wrote 0xcafed00d, read back 0x%08x\n" "$got"
(( got == 0xcafed00d )) && pass "HBM R/W ok" || fail "HBM not writable -> clk_wiz/calibration"

echo
echo "=== 6. bootrom @ $BOOTROM (expect new reset vector 732540f1...) ==="
h=$(rdhex "$BOOTROM" 8)
echo "    first 8 bytes: ${h:-<read failed>}"
[[ "${h:0:8}" == "732540f1" ]] && pass "bootrom = csrr a0,mhartid (new DTB-aware bootrom)" \
    || fail "unexpected bootrom contents"

echo
echo "=== interpretation ==========================================="
echo "  All PASS  -> substrate good; run ./scripts/run_baremetal.sh for the guest test."
echo "  Step 3 FAIL but step 2 PASS -> UART read ok, write path still broken."
echo "  Step 1 FAIL -> host cannot reach the AXI fabric at all."
echo
echo "  NOTE: step 3 appended a byte to the UART capture buffer. It (and the"
echo "  finisher) only clear on a PCIe/driver reset, not a CVA6 reset — reload"
echo "  the xdma driver before run_baremetal.sh if you want pristine output."
