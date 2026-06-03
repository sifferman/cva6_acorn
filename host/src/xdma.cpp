// Thin RAII wrapper over the Xilinx XDMA char devices.
//
// The XDMA char interface maps the file offset directly to the AXI address on
// the card side, so a transfer is: lseek(addr) then read/write the bytes. This
// mirrors what the stock dma_to_device / dma_from_device tools do; we just do
// it in-process so the dispatcher gets structured results without forking sudo
// per segment. (The process must have access to /dev/xdma0_* — typically root.)
#include "fpgaexec/fpgaexec.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <stdexcept>
#include <system_error>

namespace fpgaexec {

namespace {
int openOrThrow(const std::string& path, int flags) {
    int fd = ::open(path.c_str(), flags);
    if (fd < 0)
        throw std::system_error(errno, std::generic_category(),
                                "open " + path);
    return fd;
}

// Transfer exactly len bytes at the given AXI address, looping over partial
// and EINTR-interrupted transfers. The XDMA driver advances the file position
// by each completed transfer, so a single lseek up front is enough.
void xferAll(int fd, uint64_t addr, void* buf, size_t len, bool writing) {
    if (::lseek(fd, static_cast<off_t>(addr), SEEK_SET) < 0)
        throw std::system_error(errno, std::generic_category(), "lseek xdma");
    auto* p = static_cast<uint8_t*>(buf);
    size_t done = 0;
    while (done < len) {
        ssize_t n = writing ? ::write(fd, p + done, len - done)
                            : ::read(fd, p + done, len - done);
        if (n < 0) {
            if (errno == EINTR) continue;
            throw std::system_error(errno, std::generic_category(),
                                    writing ? "xdma write" : "xdma read");
        }
        if (n == 0)
            throw std::runtime_error("xdma short transfer (unexpected EOF)");
        done += static_cast<size_t>(n);
    }
}
}  // namespace

Xdma::Xdma(const std::string& h2c, const std::string& c2h) {
    h2c_fd_ = openOrThrow(h2c, O_WRONLY);
    try {
        c2h_fd_ = openOrThrow(c2h, O_RDONLY);
    } catch (...) {
        ::close(h2c_fd_);
        throw;
    }
}

Xdma::~Xdma() {
    if (h2c_fd_ >= 0) ::close(h2c_fd_);
    if (c2h_fd_ >= 0) ::close(c2h_fd_);
}

void Xdma::writeMem(uint64_t addr, const void* buf, size_t len) {
    xferAll(h2c_fd_, addr, const_cast<void*>(buf), len, /*writing=*/true);
}

void Xdma::readMem(uint64_t addr, void* buf, size_t len) {
    xferAll(c2h_fd_, addr, buf, len, /*writing=*/false);
}

void Xdma::write32(uint64_t addr, uint32_t val) {
    uint8_t b[4] = {static_cast<uint8_t>(val), static_cast<uint8_t>(val >> 8),
                    static_cast<uint8_t>(val >> 16),
                    static_cast<uint8_t>(val >> 24)};  // little-endian
    writeMem(addr, b, sizeof(b));
}

uint32_t Xdma::read32(uint64_t addr) {
    uint8_t b[4];
    readMem(addr, b, sizeof(b));
    return static_cast<uint32_t>(b[0]) | (static_cast<uint32_t>(b[1]) << 8) |
           (static_cast<uint32_t>(b[2]) << 16) |
           (static_cast<uint32_t>(b[3]) << 24);
}

}  // namespace fpgaexec
