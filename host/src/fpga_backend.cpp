// FpgaBackend: load an ELF onto the FK33 card over XDMA and run it.
//
// This is the in-process equivalent of scripts/run_baremetal.sh:
//   1. hold CVA6 in reset       (CTRL=0)
//   2. DMA each PT_LOAD segment  to its physical address
//   3. DMA the DTB (optional)    to dtb_base
//   4. snapshot UART len + finisher (so we read only THIS run's output and
//      detect a *fresh* finisher write — the finisher is never host-cleared)
//   5. release reset            (CTRL=1)
//   6. poll: drain new UART bytes, watch the finisher, stop on a fresh write
//   7. decode the finisher -> PASS / FAIL(code)
#include "fpgaexec/fpgaexec.hpp"

#include <algorithm>
#include <chrono>
#include <cstdarg>
#include <cstdio>
#include <fstream>
#include <thread>

namespace fpgaexec {

namespace {
void log(const FpgaConfig& cfg, const char* fmt, ...) {
    if (!cfg.verbose) return;
    va_list ap;
    va_start(ap, fmt);
    std::vfprintf(stderr, fmt, ap);
    va_end(ap);
}

std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open: " + path);
    return {std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>()};
}
}  // namespace

RunResult FpgaBackend::run(const std::string& elf_path) {
    RunResult res;
    const AddressMap& m = cfg_.map;
    try {
        ElfImage img = loadElf(elf_path);

        // Parity guardrail: the bootrom hardcodes the jump target, so the ELF
        // entry must match it. QEMU jumps to an arbitrary entry; the card can't
        // (yet), so refuse rather than silently run from the wrong PC.
        if (img.entry != m.entry) {
            char buf[128];
            std::snprintf(buf, sizeof(buf),
                          "ELF entry 0x%llx != bootrom target 0x%llx",
                          (unsigned long long)img.entry,
                          (unsigned long long)m.entry);
            res.error = buf;
            return res;
        }

        Xdma x(cfg_.h2c, cfg_.c2h);

        log(cfg_, "[*] Holding CVA6 in reset\n");
        x.write32(m.ctrl_base, 0);

        for (const auto& seg : img.segments) {
            log(cfg_, "[*] Loading segment %zu B -> 0x%llx\n", seg.data.size(),
                (unsigned long long)seg.paddr);
            x.writeMem(seg.paddr, seg.data.data(), seg.data.size());
        }

        if (!cfg_.dtb_path.empty()) {
            auto dtb = readFile(cfg_.dtb_path);
            log(cfg_, "[*] Loading DTB %zu B -> 0x%llx\n", dtb.size(),
                (unsigned long long)m.dtb_base);
            x.writeMem(m.dtb_base, dtb.data(), dtb.size());
        }

        // Snapshot BEFORE release. The UART capture buffer and finisher are not
        // cleared on a CVA6 reset (only on a PCIe/driver reset), and the
        // finisher must never be host-written, so we work around residue: read
        // only UART bytes past `base`, and treat the finisher as fired when it
        // differs from `fin0`. If `fin0` already holds a prior run's result, that
        // change signal can't fire when THIS run produces the same value — hence
        // the UART-quiescence fallback below.
        const uint32_t base = x.read32(m.uart_txlen);
        const uint32_t fin0 = x.read32(m.finish_base);
        const bool prelatched = (fin0 != 0);
        log(cfg_, "[*] snapshot: uart_txlen(base)=%u finisher(fin0)=0x%08x%s\n",
            base, fin0, prelatched ? " [pre-latched]" : "");

        log(cfg_, "[*] Releasing CVA6 reset\n");
        x.write32(m.ctrl_base, 1);

        using clock = std::chrono::steady_clock;
        const auto deadline =
            clock::now() + std::chrono::milliseconds(cfg_.timeout_ms);
        const unsigned quiesce_polls =
            std::max(1u, cfg_.quiesce_ms / std::max(1u, cfg_.poll_ms));

        uint32_t finish   = fin0;
        uint32_t last_len = base;
        unsigned stable   = 0;
        bool     done     = false;
        const char* how   = "timeout";
        while (clock::now() < deadline) {
            const uint32_t len = x.read32(m.uart_txlen);
            finish = x.read32(m.finish_base);
            if (finish != fin0) { done = true; how = "finisher-change"; break; }
            if (prelatched && len > base) {
                // No change signal available: end-of-run == UART produced new
                // output and then went quiet for quiesce_polls polls.
                stable = (len == last_len) ? stable + 1 : 0;
                if (stable >= quiesce_polls) { done = true; how = "uart-quiesce"; break; }
            }
            last_len = len;
            std::this_thread::sleep_for(std::chrono::milliseconds(cfg_.poll_ms));
        }
        log(cfg_, "[*] completion: done=%d via %s finish=0x%08x\n", done, how, finish);

        // Authoritative UART capture: a single read now that the guest is
        // quiescent, avoiding the read-len-then-read-data race of incremental
        // draining (which dropped a byte at poll boundaries). Round the length up
        // to a 4-byte multiple for the XDMA C2H engine; the capture buffer
        // absorbs the few extra bytes. Byte i of the payload lives at
        // uart_txdata+i, so the new output is [base, final_len).
        const uint32_t final_len = x.read32(m.uart_txlen);
        const uint32_t start = (final_len >= base) ? base : 0;  // 0 if buffer reset
        log(cfg_, "[*] uart: final_len=%u start=%u emit=%d bytes\n", final_len,
            start, final_len > start ? int(final_len - start) : 0);
        if (final_len > start) {
            const uint32_t rdlen = (final_len + 3u) & ~3u;
            std::vector<uint8_t> tmp(rdlen, 0);
            x.readMem(m.uart_txdata, tmp.data(), rdlen);
            res.console.assign(reinterpret_cast<char*>(tmp.data()) + start,
                               final_len - start);
        }

        res.raw_status = finish;
        if (!done) {
            res.error = prelatched
                ? "no fresh finisher and UART never quiesced within timeout "
                  "(guest hung, silent, or still running)"
                : "finisher unchanged within timeout (guest still running or hung)";
            return res;
        }

        res.finished = true;
        const uint32_t cmd = finish & 0xffff;
        if (cmd == 0x5555) {
            res.passed = true;
        } else if (cmd == 0x3333) {
            res.passed = false;
            res.code = (finish >> 16) & 0xffff;
        } else {
            res.error = "unexpected finisher value";
        }
    } catch (const std::exception& e) {
        res.error = e.what();
    }
    return res;
}

}  // namespace fpgaexec
