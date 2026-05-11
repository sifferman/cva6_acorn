# cva6_xdma

CVA6 RISC-V softcore on the SQRL/RHS Acorn (xc7a200t) FPGA, accessed from the
host PC over PCIe via Xilinx XDMA. Long-term goal: route RISC-V binaries to the
FPGA from a host scheduler via `binfmt_misc`. See [official-pitch.md](official-pitch.md)
for full project context.

## Layout

```
.
├── Makefile                  Top-level orchestration (variant, vivado, fw)
├── vivado/
│   ├── vivado.tcl            Vivado project bootstrap
│   ├── bd.tcl                Block design: XDMA + MIG + CVA6 + peripherals
│   └── acorn.xdc             Acorn pin/clock constraints (PCIe + LEDs)
├── rtl/
│   ├── cva6_acorn_wrapper.sv Wraps the cva6 core; exposes plain AXI to BD
│   ├── axi_bram_init.sv      Bootrom (4 KB BRAM @ 0x10000)
│   ├── axi_console_buffer.sv 64 KB host-readable console buffer @ 0x40000000
│   └── axi_ctrl_regs.sv      Reset / doorbell / status @ 0x60000000
├── sw/
│   ├── bootrom/              Reset-vector ROM (jumps to DRAM)
│   └── hello/                Hello-world firmware loaded into DRAM
├── scripts/
│   └── run_hello.sh          Host script: load fw, release reset, dump console
└── references/               Read-only reference repos (cva6, vivado_acorn,
                              cva6-platform, cva6-sdk, openpiton)
```

## Address map

Both the XDMA host master and the CVA6 master see the same map:

| Range                   | Size  | Slave             |
|-------------------------|-------|-------------------|
| 0x0001_0000–0x0001_0FFF | 4 KB  | bootrom (BRAM)    |
| 0x4000_0000–0x4000_FFFF | 64 KB | console buffer    |
| 0x6000_0000–0x6000_000F | 16 B  | ctrl regs         |
| 0x8000_0000–0xBFFF_FFFF | 1 GB  | DDR3 (cle215+)    |

Control registers (32-bit each):
- `0x00 CTRL`     bit 0 = CVA6_RST_N (1 releases CVA6)
- `0x04 DOORBELL` bit 0 = host→CVA6 IRQ (PLIC src 1)
- `0x08 STATUS`   nonzero raises XDMA `usr_irq` to the host
- `0x0C SCRATCH`  unused

CVA6 reset vector: `0x10000` (bootrom). Bootrom jumps to `0x80000000` (DRAM)
with `a0=mhartid, a1=0`.

## Bring-up plan

This is staged — get each milestone running before adding the next.

### M1: Hello world from CVA6 (this commit)

Goal: confirm XDMA reaches DRAM, CVA6 fetches from bootrom, runs from DRAM,
and host reads back a known string.

```
# 1. Build firmware
make fw

# 2. Build bitstream (long; ~1 hr on a fast box)
make bitstream

# 3. Program the FPGA, then reboot the host so XDMA enumerates
make program && sudo reboot

# 4. Load the XDMA Linux kernel module (from Xilinx/dma_ip_drivers)
sudo insmod ~/dma_ip_drivers/XDMA/linux-kernel/xdma/xdma.ko

# 5. Run hello world
./scripts/run_hello.sh
# Expected output: "Hello, FPGA!"
```

### M2: Linux on CVA6 with host-backed swap (next)

- Add CLINT + PLIC (or `clint_axi`/`plic_axi`) to the BD.
- Pull cva6-sdk's OpenSBI/u-boot/Linux build, add an `acorn` BOARD target, DTS
  pointing at our memory map.
- Replace the simple console buffer with a virtio-mmio device backed by an
  XDMA mailbox. Linux uses it as a block device → the host stores swap files.
- Optionally wire a virtio-console for proper getty/console.

### M3: Host-driven preempt + context save (next)

- Host writes `DOORBELL[0]=1` → PLIC fires → M-mode handler dumps GPRs, FPRs,
  CSRs (mstatus, mepc, satp, etc.) to a known DRAM region.
- Host DMAs the snapshot out, restarts CVA6 with a different binary.
- Snapshot format must match QEMU's `-loadvm` / `cpu_state` format so jobs can
  migrate between FPGA and `qemu-riscv64` (per project goals).

### M4: Multicore (later, only if needed)

- xc7a200t was already snug for 1× CVA6 + XDMA + MIG. Multicore likely requires
  trimming caches/FPU. **Skip OpenPiton** — its mesh tile is ~half a kintex 325t
  by itself; will not fit on artix 200t alongside XDMA.

## Known unknowns / TODOs before first synth

These are flagged because the design hasn't been synthesized yet and likely
needs adjustment:

1. **CVA6 config choice.** Wrapper picks up `cva6_config_pkg::cva6_cfg` — i.e.,
   whichever config is set in the cva6 build environment. `cv32a6_ima_sv32_fpga`
   is the smallest; even that may be tight on xc7a200t once XDMA + MIG are
   counted. Run `report_utilization` after synth and adjust.

2. **Clock domain.** The wrapper currently runs CVA6 directly on `mig_7series_0/
   ui_clk` (~100 MHz at DDR3-800). CVA6 fmax on artix 200t is typically
   50 MHz. If timing fails, add an MMCM and an axi_clock_converter on the
   wrapper's m_axi.

3. **Bootrom .memh path.** `axi_bram_init` is given `MEM_INIT_FILE = "bootrom.memh"`
   as a relative path. Vivado's `$readmemh` resolution at synth time is fussy
   — may need to copy `sw/bootrom/bootrom.memh` into the project's working
   directory or provide an absolute path via TCL.

4. **AXI ID widths.** Wrapper assumes `AxiIdWidth=4`. CVA6's actual upstream ID
   width depends on config (typically 4 in fpga configs). SmartConnect tolerates
   mismatched IDs but verify.

5. **`assign_bd_address` will rename our hand-crafted segs.** Calling it after
   manually creating address segs may be redundant or conflicting. If BD
   validation complains, drop the explicit `create_bd_addr_seg` calls and let
   `assign_bd_address` infer from connectivity.

6. **CVA6 needs `ndmreset`, not just rst_n.** Real CVA6 setups gate reset on
   `ndmreset_n` (debug-module reset). Without a debug module instantiated we
   tie `debug_req_i = 0`, which is fine; just confirm CVA6 boots without an
   active OpenOCD.

## Third-party code

- [`third_party/cva6`](third_party/cva6) — CVA6 (openhwgroup/cva6) as a git
  submodule. After cloning this repo: `git submodule update --init --recursive
  third_party/cva6`.
