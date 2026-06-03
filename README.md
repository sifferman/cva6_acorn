# cva6_acorn

CVA6 RISC-V softcore on an SQRL Forest Kitten 33 (FK33, Virtex UltraScale+
VU33P + HBM) FPGA, driven from the host PC over PCIe via Xilinx XDMA. The
bitstream mirrors the QEMU `virt` device map, so a single baremetal RV64 ELF
runs unmodified on both the card and `qemu-system-riscv64 -machine virt`.
Long-term goal: a host scheduler that routes each RISC-V job to the FPGA or to
QEMU and can migrate jobs between them.

> Earlier bring-up targeted the SQRL/RHS Acorn (xc7a200t); see git history for
> that variant. The active board is FK33 (branch `forest_kitten_33`).

## Status

- **M1 (hello world): done.** CVA6 boots bootrom → DRAM, runs a baremetal
  program, prints over the 16550 UART, and exits via the SiFive finisher.
- **RISC-V atomics (A extension): working.** AMOs / LR-SC are resolved by an
  `axi_riscv_atomics` adapter; a FIXED→INCR burst remap on `m_axi` was required
  because Xilinx SmartConnect/HBM mishandle FIXED bursts. `arith.elf` reproduces
  the atomics section bit-for-bit against QEMU on hardware.
- **`libfpgaexec`:** a host C++ library that runs one ELF on either backend
  (card or QEMU) behind a common interface — the substrate for the scheduler.
- **Next:** M2 (Linux — CLINT + PLIC, OpenSBI/u-boot/Linux via cva6-sdk).

## Address map

The bitstream mirrors the QEMU `virt` map, shared by the XDMA host master and
the CVA6 master:

| Base         | Slave                | Notes                                          |
|--------------|----------------------|------------------------------------------------|
| 0x0001_0000  | bootrom (BRAM)       | CVA6 reset vector; jumps to 0x8000_0000         |
| 0x0010_0000  | SiFive test finisher | guest writes 0x5555=PASS / 0x3333=FAIL; **host reads only** |
| 0x1000_0000  | 16550 UART0 (regs)   | guest console (write THR)                       |
| 0x1001_0000  | UART TX-capture      | `tx_len` @ +0 (u32), payload @ +8               |
| 0x6000_0000  | ctrl regs            | `CTRL[0]=1` releases CVA6 from reset            |
| 0x8000_0000  | HBM / DRAM           | program load address **and** ELF entry          |
| 0x8800_0000  | DTB                  | device tree blob, passed to the guest           |

CVA6 reset vector `0x10000` (bootrom) jumps to `0x80000000` with `a0=mhartid`.
A loadable ELF's entry must be `0x80000000` (the bootrom's hardcoded target).

> The finisher must **never** be host-written — a host write hangs the XDMA H2C
> channel and wedges it. All tooling only reads it.

## Commands

Prereqs: Vivado 2022+ on PATH; for card steps, the FK33 in a PCIe slot and the
XDMA kernel module + `dma_to_device`/`dma_from_device` installed (see
[third_party/vivado_acorn/README.md](third_party/vivado_acorn/README.md) for
driver install and the post-program reboot procedure).

> Firmware/QEMU steps run anywhere. **Card** steps (`run_baremetal.sh`,
> `run_elf --fpga`, `debug_fk33.sh`) must run on the host PC with the FK33
> installed and `/dev/xdma0_*` present, under `sudo` (the char devices are
> root-owned).

### One-time setup
```bash
git submodule update --init --recursive
```

### Build firmware & test programs
```bash
make fw                                   # bootrom (.memh) + hello.bin
make -C sw all                            # bootrom, DTB, and all example .elf/.bin
make -C sw examples/arith/arith.elf       # build one example
# arith validates the A extension by default; disable for a no-atomics bitstream:
make -C sw examples/arith/arith.elf EXTRA_CFLAGS=-DTEST_ATOMICS=0
```

### Build & program the bitstream
```bash
make bitstream                            # synth + P&R (long; VU33P)
make program                              # program over JTAG, then reboot so XDMA enumerates
```

### Run on QEMU (golden reference)
The same ELF QEMU runs is the one the card runs. On a host without a standalone
QEMU, use the bundled wrapper `sw/qemu-virt.sh`.
```bash
make -C sw qemu-run-arith QEMU=./qemu-virt.sh      # via the Makefile
( cd sw && ./qemu-virt.sh -machine virt -bios none -nographic -kernel examples/arith/arith.elf )
( cd sw && ../host/run_elf --qemu examples/arith/arith.elf )   # via libfpgaexec
```

### Run on the FK33 card (host PC)
```bash
# ELF loader via libfpgaexec (preferred — same .elf as QEMU):
make -C host
sudo ./host/run_elf --fpga --dtb sw/dts/fk33-virt.dtb sw/examples/arith/arith.elf

# raw flat .bin loader (legacy shell harness):
sudo ./scripts/run_baremetal.sh sw/examples/arith/arith.bin sw/dts/fk33-virt.dtb

# substrate diagnostic — exercises each AXI slave independent of CVA6:
sudo ./scripts/debug_fk33.sh
```
Expected for `arith`: the four sections (`int64`, `word32`, `shift`, `atomic`)
each print `PASS` and the run exits PASS.

## libfpgaexec

`host/` is a host-side C++17 library that runs one RISC-V ELF on **either**
backend behind a common `Backend` interface, returning a uniform `RunResult`.
It is the execution substrate for the job scheduler. Full API docs:
[host/README.md](host/README.md).

| Backend | Loads the ELF via | Result from |
|---------|-------------------|-------------|
| `QemuBackend` | `qemu-system-riscv64 -kernel` (QEMU's own loader) | process exit + stdout |
| `FpgaBackend` | parse `PT_LOAD`, DMA each segment to `p_paddr` over XDMA | finisher + UART capture |

### Build
```bash
make -C host            # libfpgaexec.a + the run_elf CLI
make -C host lib        # static library only
make -C host clean
```

### Use from a dispatcher
```cpp
#include "fpgaexec/fpgaexec.hpp"
using namespace fpgaexec;

std::unique_ptr<Backend> b = route_to_fpga(job)
    ? std::unique_ptr<Backend>(new FpgaBackend(FpgaConfig{.dtb_path = "sw/dts/fk33-virt.dtb"}))
    : std::unique_ptr<Backend>(new QemuBackend());

RunResult r = b->run(job.elf_path);   // same .elf on either backend
if      (!r.error.empty()) { /* host-side failure: requeue / fall back */ }
else if (r.passed)         { /* done */ }
else                       { /* guest FAIL, code in r.code */ }
```
Link against `host/libfpgaexec.a` with `-Ihost/include` (C++17). `Xdma` is
exposed separately for finer-grained access (e.g. M3 snapshot/restore over C2H).

### CLI
```
run_elf [--qemu|--fpga] [--dtb path] [--timeout ms] [--verbose|-v] prog.elf
```
Default backend is `--fpga`. Exit: `0` PASS, `1` guest FAIL, `2` host-side error.
`--verbose` prints the snapshot / completion-path / UART-capture diagnostics.

### Key behaviors & contracts
- **Unified artifact is the `.elf`** — QEMU needs it, the FPGA loader needs its
  segment addresses + entry, and multi-segment images (OpenSBI/Linux) can't be a
  flat `.bin`.
- **Entry guardrail:** `FpgaBackend` refuses an ELF whose entry ≠ `0x8000_0000`
  (the bootrom's hardcoded jump target); QEMU honors arbitrary entries.
- **`.bss`** is zeroed by the guest crt0, so only `p_filesz` bytes are DMA'd.
- **Completion detection:** primary signal is the finisher changing vs a
  pre-release snapshot; a UART-quiescence fallback resolves a pre-latched
  finisher (it can't be host-cleared). UART is read once after quiescence.

> Known issue: the 16550 TX-capture drops ~1 byte at output-burst boundaries (a
> hardware race in `rtl/axi_uart16550.v`); cosmetic — hex hashes and PASS/FAIL
> survive.


## Layout

```
rtl/                          Project RTL
  cva6_acorn_wrapper.v        Plain-Verilog BD wrapper (IPI rejects SV tops)
  cva6_acorn_core.sv          Inner CVA6 + atomics adapter + FIXED→INCR remap
  axi_bram_init.v             4 KB AXI BRAM, $readmemh-initialised bootrom
  axi_uart16550.v             NS16550 UART, headless TX-capture variant
  axi_sifive_test.v           SiFive test finisher (PASS/FAIL exit)
  axi_ctrl_regs.v             ctrl regs (CTRL[0] releases CVA6)
sw/
  bsp/                        Baremetal BSP (crt0, printf, virt.ld) for QEMU virt + FK33
  examples/                   Test programs (hello, arith, atomic_probe, …)
  dts/                        fk33-virt device tree
  qemu-virt.sh                Wrapper for the Xilinx-bundled qemu-system-riscv64
vivado/
  vivado.tcl                  Project bootstrap (called from `make bitstream`)
  bd_fk33.tcl                 FK33 block design: XDMA + HBM + CVA6 + slaves
  shims/                      Local overrides for CVA6 includes
host/                         libfpgaexec — C++ runner (FpgaBackend / QemuBackend)
scripts/
  run_baremetal.sh            Load a .bin to DRAM, release reset, stream UART + finisher
  debug_fk33.sh               Per-slave substrate diagnostic
third_party/
  cva6/                       openhwgroup/cva6 submodule (incl. pulp axi_riscv_atomics)
  vivado_acorn/               sifferman/vivado_acorn submodule — board tooling,
                              XDMA driver install instructions, xdma_helpers.sh
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
