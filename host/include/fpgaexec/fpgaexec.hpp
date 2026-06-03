// libfpgaexec — run one RISC-V ELF on either the FK33 FPGA card or QEMU virt.
//
// The FK33 bitstream mirrors the QEMU `virt` device map, so the SAME ELF that
// runs under `qemu-system-riscv64 -machine virt -bios none -kernel prog.elf`
// also runs on the card. The only difference is *loading*:
//   - QEMU parses the ELF itself (QemuBackend just spawns it).
//   - The FPGA needs us to DMA each PT_LOAD segment to its physical address
//     over XDMA, release CVA6 from reset, then poll the finisher / drain UART
//     (FpgaBackend does this).
//
// A dispatcher picks a Backend by policy and calls run(elf_path); both return
// the same RunResult so the routing decision and the result handling are
// backend-agnostic.
//
// Hardware quirks this library encodes (see project memory):
//   * The sifive_test finisher (0x100000) must NEVER be host-written — a host
//     write hangs the XDMA H2C channel. We only READ it, and detect a fresh
//     result by snapshotting it before releasing reset.
//   * .bss is zeroed by the guest's crt0, so we only DMA PT_LOAD file bytes.
//   * The FPGA bootrom hardcodes a jump to 0x80000000, so the ELF entry must
//     equal that; FpgaBackend refuses otherwise (QEMU honors arbitrary entry).
#ifndef FPGAEXEC_HPP
#define FPGAEXEC_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace fpgaexec {

// Guest-visible (QEMU virt) device map shared by the FK33 bitstream and the
// XDMA host master. Override fields if the bitstream's map changes.
struct AddressMap {
    uint64_t dram_base   = 0x80000000;  // program load region (== ELF entry)
    uint64_t dtb_base    = 0x88000000;  // device tree blob (passed to guest)
    uint64_t ctrl_base   = 0x60000000;  // ctrl_regs; CTRL[0]=1 releases CVA6 (host-writable)
    uint64_t finish_base = 0x00100000;  // sifive_test finisher (READ-ONLY from host)
    uint64_t uart_txlen  = 0x10010000;  // UART TX-capture: total bytes written (u32)
    uint64_t uart_txdata = 0x10010008;  // UART TX-capture: payload base
    uint64_t entry       = 0x80000000;  // required ELF entry (bootrom jump target)
};

// Outcome of a run on either backend.
struct RunResult {
    bool        finished = false;  // finisher fired (FPGA) / process exited (QEMU)
    bool        passed   = false;  // PASS: finisher cmd 0x5555, or QEMU exit 0
    uint32_t    code     = 0;      // FAIL code (finisher high half), 0 on PASS
    uint32_t    raw_status = 0;    // raw finisher word, or QEMU exit status
    std::string console;           // captured UART TX (FPGA) / stdout+stderr (QEMU)
    std::string error;             // non-empty if a host-side error aborted the run
};

// ----------------------------------------------------------------------------
// ELF loading (exposed so a dispatcher can inspect a program before routing).
// ----------------------------------------------------------------------------
struct LoadSegment {
    uint64_t              paddr = 0;  // physical address to place the bytes at
    std::vector<uint8_t>  data;       // p_filesz bytes (BSS tail handled by crt0)
};
struct ElfImage {
    uint64_t                 entry = 0;
    std::vector<LoadSegment> segments;
};
// Parse a RV64 executable ELF. Throws std::runtime_error on a malformed/foreign
// ELF (wrong magic/class/machine/type).
ElfImage loadElf(const std::string& path);

// ----------------------------------------------------------------------------
// Raw XDMA access. Also useful beyond loading (e.g. M3 snapshot/restore: read
// guest memory/registers back over the same channels).
// ----------------------------------------------------------------------------
class Xdma {
public:
    // Opens the H2C (host->card) and C2H (card->host) char devices. Throws
    // std::system_error on failure (commonly EACCES — needs root/device perms).
    explicit Xdma(const std::string& h2c = "/dev/xdma0_h2c_0",
                  const std::string& c2h = "/dev/xdma0_c2h_0");
    ~Xdma();
    Xdma(const Xdma&) = delete;
    Xdma& operator=(const Xdma&) = delete;

    void     writeMem(uint64_t addr, const void* buf, size_t len);  // H2C
    void     readMem (uint64_t addr, void* buf, size_t len);        // C2H
    void     write32 (uint64_t addr, uint32_t val);
    uint32_t read32  (uint64_t addr);

private:
    int h2c_fd_ = -1;
    int c2h_fd_ = -1;
};

// ----------------------------------------------------------------------------
// Backend interface: one ELF in, one RunResult out.
// ----------------------------------------------------------------------------
struct Backend {
    virtual ~Backend() = default;
    virtual RunResult   run(const std::string& elf_path) = 0;
    virtual const char* name() const = 0;
};

// ----------------------------------------------------------------------------
// FPGA backend: DMA the ELF onto the card and run it.
// ----------------------------------------------------------------------------
struct FpgaConfig {
    std::string h2c = "/dev/xdma0_h2c_0";
    std::string c2h = "/dev/xdma0_c2h_0";
    std::string dtb_path;            // optional; if set, loaded at map.dtb_base
    AddressMap  map;
    unsigned    timeout_ms = 10000;  // max wait for the finisher
    unsigned    poll_ms    = 5;      // finisher/UART poll interval
    // Fallback when the finisher is pre-latched (== last run's value, so the
    // "finisher changed" signal can't fire): declare the run done once the UART
    // capture has grown past the snapshot and then stayed unchanged this long.
    unsigned    quiesce_ms = 150;
    bool        verbose    = false;  // narrate load steps to stderr
};
class FpgaBackend : public Backend {
public:
    explicit FpgaBackend(FpgaConfig cfg = {}) : cfg_(std::move(cfg)) {}
    RunResult   run(const std::string& elf_path) override;
    const char* name() const override { return "fpga"; }
private:
    FpgaConfig cfg_;
};

// ----------------------------------------------------------------------------
// QEMU backend: hand the SAME ELF to qemu-system-riscv64 -kernel.
// ----------------------------------------------------------------------------
struct QemuConfig {
    // Base argv; "-kernel <elf>" is appended by run(). Default targets the
    // in-repo wrapper for the Xilinx-bundled QEMU (see sw/qemu-virt.sh).
    std::vector<std::string> argv = {
        "./qemu-virt.sh", "-machine", "virt", "-bios", "none", "-nographic"
    };
    unsigned timeout_ms = 30000;
};
class QemuBackend : public Backend {
public:
    explicit QemuBackend(QemuConfig cfg = {}) : cfg_(std::move(cfg)) {}
    RunResult   run(const std::string& elf_path) override;
    const char* name() const override { return "qemu"; }
private:
    QemuConfig cfg_;
};

}  // namespace fpgaexec

#endif  // FPGAEXEC_HPP
