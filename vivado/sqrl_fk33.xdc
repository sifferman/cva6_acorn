# SQRL Forest Kitten 33 (xcvu33p-fsvh2104-2-e) constraints for cva6_xdma.
#
# Pin assignments lifted from SQRL_FK33/board_files/sqrl_fk33/1.1/sqrl_fk33.xdc
# and SQRL_FK33/projects/fk33_example.xdc. Top-level port names match the
# externalised pins of bd_fk33.tcl.

###############################################################################
# PCIe — Gen3 x4 (FK33 is wired x16; we use lanes 0..3)
###############################################################################

# Reference clock (100 MHz from PCIe slot, diff pair on bank GTY 227)
set_property PACKAGE_PIN AD9 [get_ports {pcie_refclk_clk_p[0]}]
set_property PACKAGE_PIN AD8 [get_ports {pcie_refclk_clk_n[0]}]
create_clock -period 10.000 -name pcie_refclk [get_ports {pcie_refclk_clk_p[0]}]

# PERST_N from the slot
set_property -dict {PACKAGE_PIN BE24 IOSTANDARD LVCMOS18} [get_ports pcie_perstn]

# CLKREQ# (tied constant high in the BD; the slot needs this driven)
set_property -dict {PACKAGE_PIN BE25 IOSTANDARD LVCMOS18} [get_ports pcie_clkreq]

# MGT lanes 0..3
set_property PACKAGE_PIN AL2 [get_ports {pcie_rxp[0]}]
set_property PACKAGE_PIN AL1 [get_ports {pcie_rxn[0]}]
set_property PACKAGE_PIN  Y5 [get_ports {pcie_txp[0]}]
set_property PACKAGE_PIN  Y4 [get_ports {pcie_txn[0]}]

set_property PACKAGE_PIN AM4 [get_ports {pcie_rxp[1]}]
set_property PACKAGE_PIN AM3 [get_ports {pcie_rxn[1]}]
set_property PACKAGE_PIN AA7 [get_ports {pcie_txp[1]}]
set_property PACKAGE_PIN AA6 [get_ports {pcie_txn[1]}]

set_property PACKAGE_PIN AK4 [get_ports {pcie_rxp[2]}]
set_property PACKAGE_PIN AK3 [get_ports {pcie_rxn[2]}]
set_property PACKAGE_PIN AB5 [get_ports {pcie_txp[2]}]
set_property PACKAGE_PIN AB4 [get_ports {pcie_txn[2]}]

set_property PACKAGE_PIN AN2 [get_ports {pcie_rxp[3]}]
set_property PACKAGE_PIN AN1 [get_ports {pcie_rxn[3]}]
set_property PACKAGE_PIN AC7 [get_ports {pcie_txp[3]}]
set_property PACKAGE_PIN AC6 [get_ports {pcie_txn[3]}]

###############################################################################
# Local I2C — controls on-board PMIC (HBM rails, VCCAUX_IO, etc.)
###############################################################################

set_property -dict {PACKAGE_PIN BB24 IOSTANDARD LVCMOS18} [get_ports iic_scl_io]
set_property -dict {PACKAGE_PIN BA24 IOSTANDARD LVCMOS18} [get_ports iic_sda_io]

###############################################################################
# LEDs (4 green + 3 RGB)
###############################################################################

set_property -dict {PACKAGE_PIN BD25 IOSTANDARD LVCMOS18} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN BE26 IOSTANDARD LVCMOS18} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN BD23 IOSTANDARD LVCMOS18} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN BF26 IOSTANDARD LVCMOS18} [get_ports {led[3]}]
set_property -dict {PACKAGE_PIN BC25 IOSTANDARD LVCMOS18} [get_ports {led[4]}]
set_property -dict {PACKAGE_PIN BB26 IOSTANDARD LVCMOS18} [get_ports {led[5]}]
set_property -dict {PACKAGE_PIN BB25 IOSTANDARD LVCMOS18} [get_ports {led[6]}]

###############################################################################
# Bitstream configuration (mirrors SQRL FK33 reference — fast SPIx4 boot so
# the FPGA finishes config before PCIe enumeration window closes)
###############################################################################

set_property BITSTREAM.CONFIG.CONFIGRATE   127.5  [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4      [current_design]
set_property CONFIG_MODE                   SPIx4  [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES   [current_design]
set_property BITSTREAM.GENERAL.COMPRESS    TRUE   [current_design]
