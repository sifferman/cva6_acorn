# Build bootrom (.memh for axi_bram_init $readmemh) and DRAM firmware (hello.bin).

CROSS ?= riscv64-unknown-elf-
ARCH  ?= rv64imafdc
ABI   ?= lp64

CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

CFLAGS  := -march=$(ARCH) -mabi=$(ABI) -nostdlib -nostartfiles -fno-builtin -Os
# Suppress the .note.gnu.build-id section. The riscv64-unknown-linux-gnu
# toolchain emits it by default and the linker can place it at offset 0,
# ahead of .text.start — which corrupts the reset vector at 0x10000 (CVA6
# fetches the note header as its first instruction and faults). Harmless and
# robust across both the bare-metal (-elf-) and linux-gnu toolchains.
LDFLAGS := -Wl,--build-id=none

.PHONY: all clean
all: bootrom/bootrom.memh bootrom/bootrom.dump hello/hello.bin hello/hello.dump

%.elf: %.S %.ld
	$(CC) $(CFLAGS) $(LDFLAGS) -T $*.ld -o $@ $<

%.bin: %.elf
	$(OBJCOPY) -O binary $< $@

%.dump: %.elf
	$(OBJDUMP) -d $< > $@

# 64-bit-word .mem file for $readmemh, padded to axi_bram_init.DEPTH_WORDS.
bootrom/bootrom.memh: bootrom/bootrom.bin
	python3 -c 'import sys; \
data = open("$<","rb").read(); \
data += b"\x00" * (8192 - len(data)); \
out = open("$@","w"); \
[out.write("%016x\n" % int.from_bytes(data[i:i+8], "little")) for i in range(0, 8192, 8)]; \
out.close()'

clean:
	rm -f bootrom/bootrom.elf bootrom/bootrom.bin bootrom/bootrom.memh bootrom/bootrom.dump
	rm -f hello/hello.elf hello/hello.bin hello/hello.dump
