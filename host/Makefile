# libfpgaexec — host-side library to run a RISC-V ELF on the FK33 card or QEMU.
#
#   make            # build lib + run_elf CLI
#   make lib        # static library only (libfpgaexec.a)
#   make clean
#
# Link into a dispatcher: -Ihost/include host/libfpgaexec.a  (C++17).
CXX      ?= g++
CXXFLAGS ?= -std=c++17 -O2 -Wall -Wextra -Iinclude
AR       ?= ar

LIB_SRCS := src/elf_loader.cpp src/xdma.cpp src/fpga_backend.cpp src/qemu_backend.cpp
LIB_OBJS := $(LIB_SRCS:.cpp=.o)
LIB      := libfpgaexec.a
BIN      := run_elf

.PHONY: all lib clean
all: $(BIN)

lib: $(LIB)

$(LIB): $(LIB_OBJS)
	$(AR) rcs $@ $^

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BIN): examples/run_elf.cpp $(LIB)
	$(CXX) $(CXXFLAGS) $< $(LIB) -o $@

clean:
	rm -f $(LIB_OBJS) $(LIB) $(BIN)
