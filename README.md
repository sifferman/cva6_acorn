# cva6_acorn

CVA6 RISC-V softcore on the SQRL/RHS Acorn (xc7a200t) FPGA, accessed from the
host PC over PCIe via Xilinx XDMA. Long-term goal: route RISC-V binaries to the
FPGA from a host scheduler via `binfmt_misc`.

## Status

**M1 (hello world) works.** Bitstream synthesises with timing met (commit
[84deef9](https://github.com/)), CVA6 boots from the bootrom into DRAM, runs
`sw/hello/hello.bin`, raises `STATUS=0x1`, and prints `Hello, FPGA!` through
the console buffer.

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

## Quickstart

Prereqs: Vivado 2022+ on PATH, the Acorn board installed in a PCIe slot, and
the XDMA kernel module + userspace tools installed (see
[third_party/vivado_acorn/README.md](third_party/vivado_acorn/README.md) for
step-by-step driver install and reboot procedure).

```bash
# One-time: clone submodules
git submodule update --init --recursive

# 1. Build firmware (bootrom + hello.bin)
make fw

# 2. Build bitstream (long; ~1 hr)
make bitstream

# 3. Program the FPGA, then reboot so XDMA enumerates and /dev/xdma0_* appear
make program && sudo reboot

# 4. Run hello world
./scripts/run_hello.sh
# Expected:  Console contents:  Hello, FPGA!
```

`scripts/run_hello.sh` expects `dma_to_device` / `dma_from_device` from
[Xilinx/dma_ip_drivers](https://github.com/Xilinx/dma_ip_drivers) to be on
`$PATH`. It runs them under `sudo` because the `/dev/xdma0_*` char devices are
root-owned.

## Bring-up plan

- [x] **M1: Hello world from CVA6.** Confirmed XDMA reaches DRAM, CVA6 fetches
      from bootrom, runs from DRAM, host reads the console buffer back.
- [ ] **M2: Linux on CVA6 with host-backed swap.** Add CLINT + PLIC to the BD,
      pull cva6-sdk's OpenSBI/u-boot/Linux build with an `acorn` BOARD target
      and DTS for our memory map, swap the console buffer for a virtio-mmio
      block device backed by an XDMA mailbox so the host can serve swap files.
      Optionally add a virtio-console for getty.
- [ ] **M3: Host-driven preempt + context save.** Host writes `DOORBELL[0]=1`
      → PLIC fires → M-mode handler dumps GPRs/FPRs/CSRs (mstatus, mepc, satp,
      …) to a known DRAM region. Host DMAs the snapshot out and restarts CVA6
      with a different binary. Snapshot format should match QEMU's `-loadvm`
      so jobs can migrate between FPGA and `qemu-riscv64`.
- [ ] **M4: Multicore (only if needed).** xc7a200t was already snug for 1× CVA6
      + XDMA + MIG; multicore likely means trimming caches/FPU. **Skip
      OpenPiton** — its mesh tile is ~half a kintex 325t alone and will not
      fit on artix 200t alongside XDMA.

## Layout

```
rtl/                          Project RTL
  cva6_acorn_wrapper.v        Plain-Verilog BD wrapper (IPI rejects SV tops)
  cva6_acorn_core.sv          Inner CVA6 instance + glue
  axi_bram_init.v             4 KB AXI BRAM, $readmemh-initialised bootrom
  axi_console_buffer.v        64 KB AXI buffer, len@0 + payload@4
  axi_ctrl_regs.v             16-byte CTRL/DOORBELL/STATUS/SCRATCH
sw/
  bootrom/                    Reset-vector trampoline → jr 0x80000000
  hello/                      M1 hello-world (link addr 0x80000000)
vivado/
  vivado.tcl                  Project bootstrap (called from `make bitstream`)
  bd.tcl                      Block design: XDMA + MIG + CVA6 + slaves
  shims/                      Local overrides for CVA6 includes
scripts/
  run_hello.sh                Load hello.bin, release reset, dump console
third_party/
  cva6/                       openhwgroup/cva6 submodule
  vivado_acorn/               sifferman/vivado_acorn submodule — Acorn board
                              reference designs, XDMA driver install
                              instructions, xdma_helpers.sh
```

## Third-party references

- [`third_party/cva6`](third_party/cva6) — CVA6
  ([openhwgroup/cva6](https://github.com/openhwgroup/cva6)) as a git submodule.
- [`third_party/vivado_acorn`](third_party/vivado_acorn) — Acorn board
  ([sifferman/vivado_acorn](https://github.com/sifferman/vivado_acorn))
  reference designs and tooling. **Refer to its README for XDMA kernel-driver
  install, the post-program reboot requirement, and FPGA programming
  options.** [`xdma_helpers.sh`](third_party/vivado_acorn/xdma_helpers.sh)
  also has handy bash helpers (`xdma_h2c_file`, `xdma_c2h_int32`, etc.) that
  work with the same `/dev/xdma0_*` device this project exposes.
