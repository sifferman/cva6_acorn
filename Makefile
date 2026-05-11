# cva6_xdma — CVA6 on Acorn FPGA via XDMA
#
# Targets:
#   make bitstream            # Build the FPGA bitstream
#   make program              # Program the FPGA over JTAG (then reboot host)
#   make fw                   # Build hello-world firmware + bootrom hex
#   make clean                # Remove build artifacts
#
# The Acorn variant defaults to cle215+ (xc7a200t, 1GB DRAM).
# Override on the command line, e.g.: make VARIANT=cle215

VARIANT ?= cle215+

ifeq ($(filter $(VARIANT),cle101 cle215 cle215+),)
    $(error Invalid VARIANT '$(VARIANT)'. Must be one of: cle101, cle215, cle215+)
endif

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

# Where the CVA6 source tree lives. References/cva6 is a working tree the
# user already has; replace with a proper submodule path later if desired.
CVA6_DIR ?= $(CURDIR)/references/cva6

# Reuse the MIG project from the proven vivado_acorn reference.
MIG_PRJ ?= $(CURDIR)/references/vivado_acorn/mig_$(VARIANT).prj

BUILD_DIR := build
BD_NAME   := cva6_acorn

BIT := $(BUILD_DIR)/$(BD_NAME)/acorn_$(VARIANT).runs/impl_1/design_1_wrapper.bit

# Which CVA6 config to synthesise. Selects an entry in core/Flist.cva6.
TARGET_CFG ?= cv32a6_ima_sv32_fpga

.PHONY: bitstream program fw clean
.SECONDARY:

bitstream: $(BIT)

$(BIT): vivado/bd.tcl vivado/vivado.tcl vivado/acorn.xdc vivado/shims/common_cells/registers.svh rtl/cva6_acorn_wrapper.v rtl/cva6_acorn_core.sv sw/bootrom/bootrom.memh
	rm -rf $(BUILD_DIR)/$(BD_NAME)
	mkdir -p $(BUILD_DIR)
	cd $(BUILD_DIR) && \
	  vivado -nolog -nojournal -mode batch \
	    -source ../vivado/vivado.tcl \
	    -tclargs $(BD_NAME) $(VARIANT) $(PART_NAME) $(DRAM_SIZE) ../vivado/bd.tcl $(CVA6_DIR) $(MIG_PRJ) $(TARGET_CFG)

# Program over JTAG (requires LiteX Acorn baseboard or external programmer).
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
