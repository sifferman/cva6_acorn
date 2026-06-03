// run_elf — minimal CLI over libfpgaexec; the in-process analogue of
// scripts/run_baremetal.sh (FPGA) and `make qemu-run` (QEMU). Also shows the
// shape a dispatcher would use: build a Backend, call run(), inspect RunResult.
//
//   run_elf [--qemu|--fpga] [--dtb path] [--timeout ms] [--verbose] prog.elf
//
// Default backend is --fpga. Exit code: 0 PASS, 1 FAIL, 2 host-side error.
#include "fpgaexec/fpgaexec.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>

using namespace fpgaexec;

int main(int argc, char** argv) {
    bool use_qemu = false;
    std::string dtb, elf;
    unsigned timeout_ms = 0;  // 0 -> backend default
    bool verbose = false;

    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        if (a == "--qemu") use_qemu = true;
        else if (a == "--fpga") use_qemu = false;
        else if (a == "--verbose" || a == "-v") verbose = true;
        else if (a == "--dtb" && i + 1 < argc) dtb = argv[++i];
        else if (a == "--timeout" && i + 1 < argc) timeout_ms = std::atoi(argv[++i]);
        else if (!a.empty() && a[0] == '-') {
            std::fprintf(stderr, "unknown option: %s\n", a.c_str());
            return 2;
        } else elf = a;
    }
    if (elf.empty()) {
        std::fprintf(stderr,
            "usage: run_elf [--qemu|--fpga] [--dtb path] [--timeout ms] [-v] prog.elf\n");
        return 2;
    }

    std::unique_ptr<Backend> backend;
    if (use_qemu) {
        QemuConfig qc;
        if (timeout_ms) qc.timeout_ms = timeout_ms;
        backend = std::make_unique<QemuBackend>(std::move(qc));
    } else {
        FpgaConfig fc;
        fc.dtb_path = dtb;
        fc.verbose = verbose;
        if (timeout_ms) fc.timeout_ms = timeout_ms;
        backend = std::make_unique<FpgaBackend>(std::move(fc));
    }

    std::fprintf(stderr, "[*] backend=%s  elf=%s\n", backend->name(), elf.c_str());
    RunResult r = backend->run(elf);

    std::fputs(r.console.c_str(), stdout);
    if (!r.console.empty() && r.console.back() != '\n') std::fputc('\n', stdout);

    if (!r.error.empty()) {
        std::fprintf(stderr, "[!] error: %s\n", r.error.c_str());
        return 2;
    }
    if (r.passed) {
        std::fprintf(stderr, "[*] PASS (status=0x%08x)\n", r.raw_status);
        return 0;
    }
    std::fprintf(stderr, "[!] FAIL code=%u (status=0x%08x)\n", r.code, r.raw_status);
    return 1;
}
