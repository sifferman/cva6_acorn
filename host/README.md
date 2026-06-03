# libfpgaexec

Host-side C++17 library to run **one** RISC-V ELF on **either** the FK33 FPGA
card (over XDMA) or QEMU `virt` — the substrate for a dispatcher that decides
where a RISC-V job should run.

The FK33 bitstream mirrors the QEMU `virt` device map, so the same ELF runs on
both. The only difference is loading:

| Backend | How the ELF is loaded | Result source |
|---|---|---|
| `QemuBackend` | `qemu-system-riscv64 -kernel prog.elf` (QEMU's own loader) | process exit + stdout |
| `FpgaBackend` | parse `PT_LOAD`, DMA each segment to its `p_paddr`, release reset | sifive_test finisher + UART capture |

Both return the same `RunResult { finished, passed, code, raw_status, console, error }`.

## Build

```sh
make            # libfpgaexec.a + run_elf CLI
make lib        # static library only
```

C++17, no external deps (uses `<elf.h>` and the XDMA char devices).

## CLI (manual testing — analogue of run_baremetal.sh / `make qemu-run`)

```sh
# on the card (needs /dev/xdma0_* access — typically root):
sudo ./run_elf --fpga --dtb ../sw/dts/fk33-virt.dtb ../sw/examples/arith/arith.elf

# on any host with the QEMU wrapper on the CWD:
( cd ../sw && ../host/run_elf --qemu examples/arith/arith.elf )
```

Exit code: `0` PASS, `1` FAIL, `2` host-side error.

## Dispatcher integration

```cpp
#include "fpgaexec/fpgaexec.hpp"
using namespace fpgaexec;

std::unique_ptr<Backend> pick(const Job& j) {
    if (route_to_fpga(j)) {
        FpgaConfig c; c.dtb_path = "sw/dts/fk33-virt.dtb";
        return std::make_unique<FpgaBackend>(std::move(c));
    }
    return std::make_unique<QemuBackend>();
}

RunResult r = pick(job)->run(job.elf_path);
if (!r.error.empty())      /* host-side failure: requeue / fall back */;
else if (r.passed)         /* done */;
else                       /* guest FAIL, r.code */;
```

`Xdma` is exposed separately for finer-grained access (e.g. M3 snapshot/restore:
read guest memory/registers back over the same C2H channel).

## Hardware contracts encoded here

- **Finisher is read-only from the host.** A host *write* to `0x100000` hangs the
  XDMA H2C channel, so we only read it and detect a fresh result by snapshotting
  before reset release.
- **`.bss` is zeroed by the guest crt0**, so only `p_filesz` bytes are DMA'd.
- **ELF entry must be `0x80000000`** — the bootrom hardcodes that jump target.
  `FpgaBackend` refuses a mismatch (QEMU honors arbitrary entries).
