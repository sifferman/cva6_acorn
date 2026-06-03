# Build bootrom (.memh for axi_bram_init $readmemh) and DRAM firmware (hello.bin).

# The CVA6 on the card is RV64IMAC (no FPU). Build for exactly that subset so
# the compiler can never emit an FP instruction — those are illegal on the core
# and would trap/hang. lp64 (soft-float ABI) matches. QEMU virt is a superset,
# so the same imac binary still runs there for the golden reference.
CROSS ?= riscv64-unknown-elf-
# _zicsr: crt0 uses csrr/csrw (csr access is a separate extension in recent
# toolchains and no longer implied by the base ISA string).
ARCH  ?= rv64imac_zicsr
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

# --- Baremetal BSP (QEMU virt / FK33 card) ----------------------------------
# The BSP + an example program link at 0x80000000 against the QEMU `virt` device
# map (16550 UART0 @ 0x10000000, SiFive finisher @ 0x100000), so the identical
# binary runs under `make qemu-run` and on the card.
BSP_DIR    := bsp
BSP_SRCS   := $(BSP_DIR)/crt0.S $(BSP_DIR)/console.c $(BSP_DIR)/printf.c $(BSP_DIR)/string.c
BSP_LD     := $(BSP_DIR)/virt.ld
# medany: code/data live at 0x80000000, out of range for the default medlow.
BSP_CFLAGS := -ffreestanding -mcmodel=medany -I$(BSP_DIR)
QEMU       ?= qemu-system-riscv64
DTC        ?= dtc

.PHONY: all clean qemu-run
all: bootrom/bootrom.memh bootrom/bootrom.dump hello/hello.bin hello/hello.dump \
     examples/hello/hello.bin examples/hello/hello.dump \
     examples/arith/arith.bin examples/arith/arith.dump dts/fk33-virt.dtb

# Device tree blob the host loads to 0x88000000 (passed in a1) on the card.
dts/fk33-virt.dtb: dts/fk33-virt.dts
	$(DTC) -I dts -O dtb -o $@ $<

# Baremetal example: BSP objects + program, one link command.
examples/hello/hello.elf: examples/hello/main.c $(BSP_SRCS) $(BSP_LD)
	$(CC) $(CFLAGS) $(BSP_CFLAGS) $(LDFLAGS) -T $(BSP_LD) -o $@ examples/hello/main.c $(BSP_SRCS)

# Run the example on QEMU's virt machine (UART0 -> stdio; finisher exits QEMU).
qemu-run: examples/hello/hello.elf
	$(QEMU) -machine virt -bios none -nographic -kernel $<

# Arithmetic-consistency validation kernel (RV64IMAC differential check).
# Build with EXTRA_CFLAGS=-DTEST_ATOMICS=1 to also validate the A extension
# (needs the axi_riscv_atomics adapter in the loaded bitstream; QEMU is fine).
examples/arith/arith.elf: examples/arith/main.c $(BSP_SRCS) $(BSP_LD)
	$(CC) $(CFLAGS) $(BSP_CFLAGS) $(EXTRA_CFLAGS) $(LDFLAGS) -T $(BSP_LD) -o $@ examples/arith/main.c $(BSP_SRCS)

# Capture the golden hash from QEMU (the reference the FPGA must reproduce).
qemu-run-arith: examples/arith/arith.elf
	$(QEMU) -machine virt -bios none -nographic -kernel $<

# Per-operation atomics diagnostic (isolates which amo*/lr-sc op + width diverges).
examples/atomic_probe/atomic_probe.elf: examples/atomic_probe/main.c $(BSP_SRCS) $(BSP_LD)
	$(CC) $(CFLAGS) $(BSP_CFLAGS) $(LDFLAGS) -T $(BSP_LD) -o $@ examples/atomic_probe/main.c $(BSP_SRCS)

qemu-run-atomic: examples/atomic_probe/atomic_probe.elf
	$(QEMU) -machine virt -bios none -nographic -kernel $<

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
	rm -f examples/hello/hello.elf examples/hello/hello.bin examples/hello/hello.dump
	rm -f examples/arith/arith.elf examples/arith/arith.bin examples/arith/arith.dump
	rm -f dts/fk33-virt.dtb
