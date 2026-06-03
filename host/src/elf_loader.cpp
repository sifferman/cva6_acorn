// ELF64 RISC-V loader: extract PT_LOAD segments + entry point.
//
// We deliberately only copy p_filesz bytes per segment. The remaining
// (p_memsz - p_filesz) is .bss, which the guest's crt0 zeroes at startup — the
// same contract QEMU's -kernel loader relies on.
#include "fpgaexec/fpgaexec.hpp"

#include <elf.h>

#include <cstdio>
#include <fstream>
#include <stdexcept>

namespace fpgaexec {

ElfImage loadElf(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open ELF: " + path);

    std::vector<uint8_t> buf((std::istreambuf_iterator<char>(f)),
                             std::istreambuf_iterator<char>());
    if (buf.size() < sizeof(Elf64_Ehdr))
        throw std::runtime_error("ELF too small: " + path);

    const auto* eh = reinterpret_cast<const Elf64_Ehdr*>(buf.data());
    if (eh->e_ident[EI_MAG0] != ELFMAG0 || eh->e_ident[EI_MAG1] != ELFMAG1 ||
        eh->e_ident[EI_MAG2] != ELFMAG2 || eh->e_ident[EI_MAG3] != ELFMAG3)
        throw std::runtime_error("not an ELF file: " + path);
    if (eh->e_ident[EI_CLASS] != ELFCLASS64)
        throw std::runtime_error("not ELF64 (need RV64): " + path);
    if (eh->e_ident[EI_DATA] != ELFDATA2LSB)
        throw std::runtime_error("not little-endian ELF: " + path);
    if (eh->e_machine != EM_RISCV)
        throw std::runtime_error("not a RISC-V ELF: " + path);
    if (eh->e_type != ET_EXEC)
        throw std::runtime_error("not a static executable ELF (ET_EXEC): " + path);
    if (eh->e_phoff == 0 || eh->e_phnum == 0)
        throw std::runtime_error("ELF has no program headers: " + path);
    if (eh->e_phentsize != sizeof(Elf64_Phdr))
        throw std::runtime_error("unexpected e_phentsize: " + path);

    ElfImage img;
    img.entry = eh->e_entry;

    for (unsigned i = 0; i < eh->e_phnum; ++i) {
        uint64_t off = eh->e_phoff + static_cast<uint64_t>(i) * eh->e_phentsize;
        if (off + sizeof(Elf64_Phdr) > buf.size())
            throw std::runtime_error("truncated program header table: " + path);
        const auto* ph = reinterpret_cast<const Elf64_Phdr*>(buf.data() + off);
        if (ph->p_type != PT_LOAD || ph->p_filesz == 0) continue;
        if (ph->p_offset + ph->p_filesz > buf.size())
            throw std::runtime_error("PT_LOAD extends past EOF: " + path);

        LoadSegment seg;
        seg.paddr = ph->p_paddr;  // physical address (== vaddr for these images)
        seg.data.assign(buf.begin() + ph->p_offset,
                        buf.begin() + ph->p_offset + ph->p_filesz);
        img.segments.push_back(std::move(seg));
    }

    if (img.segments.empty())
        throw std::runtime_error("ELF has no loadable PT_LOAD segments: " + path);
    return img;
}

}  // namespace fpgaexec
