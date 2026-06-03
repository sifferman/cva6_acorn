// QemuBackend: run the SAME ELF under qemu-system-riscv64 -kernel.
//
// QEMU loads the ELF itself, so there's no DMA/loader here — we just spawn the
// process (default: the in-repo sw/qemu-virt.sh wrapper), capture its combined
// stdout+stderr, and map its exit status to a RunResult. The sifive_test
// finisher makes QEMU exit 0 on PASS and non-zero on FAIL, matching the card's
// finisher semantics closely enough for a routing decision.
#include "fpgaexec/fpgaexec.hpp"

#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cerrno>
#include <chrono>
#include <cstring>

namespace fpgaexec {

RunResult QemuBackend::run(const std::string& elf_path) {
    RunResult res;

    std::vector<std::string> argv = cfg_.argv;
    argv.push_back("-kernel");
    argv.push_back(elf_path);

    int pipefd[2];
    if (::pipe(pipefd) != 0) {
        res.error = std::string("pipe: ") + std::strerror(errno);
        return res;
    }

    pid_t pid = ::fork();
    if (pid < 0) {
        res.error = std::string("fork: ") + std::strerror(errno);
        ::close(pipefd[0]);
        ::close(pipefd[1]);
        return res;
    }

    if (pid == 0) {
        // Child: stdout+stderr -> pipe, then exec.
        ::dup2(pipefd[1], STDOUT_FILENO);
        ::dup2(pipefd[1], STDERR_FILENO);
        ::close(pipefd[0]);
        ::close(pipefd[1]);
        std::vector<char*> cargv;
        cargv.reserve(argv.size() + 1);
        for (auto& s : argv) cargv.push_back(const_cast<char*>(s.c_str()));
        cargv.push_back(nullptr);
        ::execvp(cargv[0], cargv.data());
        // exec failed:
        std::fprintf(stderr, "execvp %s: %s\n", cargv[0], std::strerror(errno));
        ::_exit(127);
    }

    // Parent: read the child's output until EOF or timeout.
    ::close(pipefd[1]);
    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + std::chrono::milliseconds(cfg_.timeout_ms);
    bool timed_out = false;
    char buf[4096];
    for (;;) {
        auto now = clock::now();
        if (now >= deadline) { timed_out = true; break; }
        int ms = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now)
                .count());
        struct pollfd pfd { pipefd[0], POLLIN, 0 };
        int pr = ::poll(&pfd, 1, ms);
        if (pr < 0) { if (errno == EINTR) continue; break; }
        if (pr == 0) { timed_out = true; break; }
        ssize_t n = ::read(pipefd[0], buf, sizeof(buf));
        if (n < 0) { if (errno == EINTR) continue; break; }
        if (n == 0) break;  // child closed the pipe (exited)
        res.console.append(buf, static_cast<size_t>(n));
    }
    ::close(pipefd[0]);

    if (timed_out) {
        ::kill(pid, SIGKILL);
        res.error = "QEMU timed out (guest hung or never hit the finisher)";
    }

    int status = 0;
    ::waitpid(pid, &status, 0);
    if (timed_out) return res;

    res.finished = true;
    if (WIFEXITED(status)) {
        int ec = WEXITSTATUS(status);
        res.raw_status = static_cast<uint32_t>(ec);
        res.passed = (ec == 0);
        if (!res.passed) res.code = static_cast<uint32_t>(ec);
    } else {
        res.passed = false;
        res.error = "QEMU terminated abnormally (signal)";
        res.raw_status = static_cast<uint32_t>(status);
    }
    return res;
}

}  // namespace fpgaexec
