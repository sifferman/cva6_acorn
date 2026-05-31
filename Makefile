# cva6_xdma — CVA6 over PCIe (XDMA) on SQRL FPGA boards.
#
# Targets:
#   make bitstream                # Build the FPGA bitstream
#   make program                  # Program the FPGA over JTAG (then reboot host)
#   make fw                       # Build hello-world firmware + bootrom hex
#   make clean                    # Remove build artifacts
#
# Supported VARIANTs:
#   cle101, cle215, cle215+       — SQRL Acorn (xc7a100t/200t) with DDR3
#   fk33                          — SQRL Forest Kitten 33 (xcvu33p) with HBM
#
# Defaults to cle215+. Override on the command line, e.g.:
#   make VARIANT=fk33 bitstream

VARIANT ?= fk33

ACORN_VARIANTS := cle101 cle215 cle215+
FK33_VARIANTS  := fk33
ALL_VARIANTS   := $(ACORN_VARIANTS) $(FK33_VARIANTS)

ifeq ($(filter $(VARIANT),$(ALL_VARIANTS)),)
    $(error Invalid VARIANT '$(VARIANT)'. Must be one of: $(ALL_VARIANTS))
endif

ifneq ($(filter $(VARIANT),$(ACORN_VARIANTS)),)
    BOARD := acorn
else
    BOARD := fk33
endif

# Per-variant part / memory size.
ifeq ($(VARIANT), cle101)
    PART_NAME := xc7a100tfgg484-2
    DRAM_SIZE := 512M
endif
ifeq ($(VARIANT), cle215)
    PART_NAME := xc7a200tfbg484-2
    DRAM_SIZE := 512M
endif
ifeq ($(VARIANT), cle215+)
    PART_NAME := xc7a200tfbg484-3
    DRAM_SIZE := 1G
endif
ifeq ($(VARIANT), fk33)
    PART_NAME := xcvu33p-fsvh2104-2-e
    DRAM_SIZE := 1G
endif

# Per-board BD script, XDC, and (Acorn-only) MIG project.
ifeq ($(BOARD), acorn)
    BD_TCL   ?= $(CURDIR)/vivado/bd_acorn.tcl
    XDC_FILE ?= $(CURDIR)/third_party/vivado_acorn/sqrl_acorn.xdc
    MIG_PRJ  ?= $(CURDIR)/third_party/vivado_acorn/mig_$(VARIANT).prj
endif
ifeq ($(BOARD), fk33)
    BD_TCL   ?= $(CURDIR)/vivado/bd_fk33.tcl
    XDC_FILE ?= $(CURDIR)/vivado/sqrl_fk33.xdc
    MIG_PRJ  ?= /dev/null
endif

# Where the CVA6 source tree lives. third_party/cva6 is a git submodule.
CVA6_DIR ?= $(CURDIR)/third_party/cva6

BUILD_DIR := build
BD_NAME   := cva6_acorn

BIT := $(BUILD_DIR)/$(BD_NAME)/$(VARIANT).runs/impl_1/design_1_wrapper.bit

# Which CVA6 config to synthesise. Selects an entry in core/Flist.cva6.
TARGET_CFG ?= cv64a6_imafdc_sv39

# CVA6 clock frequency (MHz). Heavy configs can't close at 100 MHz; the rest
# of the design (MIG/HBM, XDMA, peripherals) stays at its native rate.
ifeq ($(TARGET_CFG),cv64a6_imafdc_sv39)
    CPU_FREQ_MHZ ?= 50
else
    CPU_FREQ_MHZ ?= 100
endif

.PHONY: bitstream program fw clean
.SECONDARY:

bitstream: $(BIT)

$(BIT): $(BD_TCL) vivado/vivado.tcl $(XDC_FILE) vivado/shims/common_cells/registers.svh rtl/cva6_acorn_wrapper.v rtl/cva6_acorn_core.sv rtl/axi_uart16550.v rtl/axi_sifive_test.v rtl/axi_ctrl_regs.v sw/bootrom/bootrom.memh
	rm -rf $(BUILD_DIR)/$(BD_NAME)
	mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && \
	  vivado -nolog -nojournal -mode batch \
	    -source ../vivado/vivado.tcl \
	    -tclargs $(BD_NAME) $(VARIANT) $(PART_NAME) $(DRAM_SIZE) $(BD_TCL) $(CVA6_DIR) $(MIG_PRJ) $(TARGET_CFG) $(XDC_FILE) $(CPU_FREQ_MHZ)

# Program over JTAG (Acorn: requires LiteX Acorn baseboard or external programmer.
# FK33: requires JTAG over its on-board USB or external JTAG cable.)
$(BUILD_DIR)/vivado-program.tcl:
	mkdir -p $(dir $@)
	wget -O $@ https://raw.githubusercontent.com/olofk/edalize/refs/tags/v0.6.1/edalize/templates/vivado/vivado-program.tcl.j2

program: $(BIT) $(BUILD_DIR)/vivado-program.tcl
	cd $(BUILD_DIR) && \
	  vivado -quiet -nolog -nojournal -notrace -mode batch \
	    -source vivado-program.tcl -tclargs $(PART_NAME) ../$(BIT)

fw: sw/bootrom/bootrom.memh sw/hello/hello.bin

sw/bootrom/bootrom.memh sw/hello/hello.bin:
	$(MAKE) -C sw

clean:
	rm -rf $(BUILD_DIR)
	$(MAKE) -C sw clean
