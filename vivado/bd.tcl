
# Block design: XDMA + DDR3 + CVA6 + bootrom + console + ctrl regs
#
# Address map (unified — both XDMA host master and CVA6 see the same map):
#   0x0001_0000 .. 0x0001_0FFF   bootrom        (4 KB BRAM, CVA6 reset vector)
#   0x4000_0000 .. 0x4000_FFFF   console buffer (host-readable)
#   0x6000_0000 .. 0x6000_000F   control regs   (reset, doorbell, status)
#   0x8000_0000 .. 0xBFFF_FFFF   DDR3           (1 GB on cle215+)

##############
# PCIe / XDMA
##############

create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_0
set_property -dict [list \
    CONFIG.pl_link_cap_max_link_width {X4} \
    CONFIG.pl_link_cap_max_link_speed {5.0_GT/s} \
    CONFIG.ref_clk_freq {100_MHz} \
    CONFIG.axisten_freq {125} \
    CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
] [get_bd_cells xdma_0]

# PCIe reset
create_bd_port -dir I -type rst pcie_x4_rst_n
connect_bd_net [get_bd_ports pcie_x4_rst_n] [get_bd_pins xdma_0/sys_rst_n]

# PCIe ref clock
create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 util_ds_buf_pcie
create_bd_port -dir I -type clk -freq_hz 100000000 pcie_x4_clk_p
create_bd_port -dir I -type clk -freq_hz 100000000 pcie_x4_clk_n
set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} [get_bd_cells util_ds_buf_pcie]
connect_bd_net [get_bd_ports pcie_x4_clk_p] [get_bd_pins util_ds_buf_pcie/IBUF_DS_P]
connect_bd_net [get_bd_ports pcie_x4_clk_n] [get_bd_pins util_ds_buf_pcie/IBUF_DS_N]
connect_bd_net [get_bd_pins util_ds_buf_pcie/IBUF_OUT] [get_bd_pins xdma_0/sys_clk]

# PCIe data
create_bd_port -dir I -from 3 -to 0 -type data pcie_x4_rx_p
create_bd_port -dir I -from 3 -to 0 -type data pcie_x4_rx_n
create_bd_port -dir O -from 3 -to 0 -type data pcie_x4_tx_p
create_bd_port -dir O -from 3 -to 0 -type data pcie_x4_tx_n
connect_bd_net [get_bd_ports pcie_x4_rx_p] [get_bd_pins xdma_0/pci_exp_rxp]
connect_bd_net [get_bd_ports pcie_x4_rx_n] [get_bd_pins xdma_0/pci_exp_rxn]
connect_bd_net [get_bd_ports pcie_x4_tx_p] [get_bd_pins xdma_0/pci_exp_txp]
connect_bd_net [get_bd_ports pcie_x4_tx_n] [get_bd_pins xdma_0/pci_exp_txn]

##############
# DDR3 / MIG
##############

create_bd_cell -type ip -vlnv xilinx.com:ip:mig_7series:4.2 mig_7series_0
set_property CONFIG.XML_INPUT_FILE $mig_prj [get_bd_cells mig_7series_0]
make_bd_intf_pins_external [get_bd_intf_pins mig_7series_0/DDR3]
make_bd_intf_pins_external [get_bd_intf_pins mig_7series_0/SYS_CLK]
set_property NAME DDR_CLK [get_bd_intf_ports /SYS_CLK_0]

# MIG resets tied high (we issue resets through util_vector_logic from ui rst)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_high
set_property CONFIG.CONST_VAL {1} [get_bd_cells xlconstant_high]
connect_bd_net [get_bd_pins xlconstant_high/dout] \
               [get_bd_pins mig_7series_0/aresetn] \
               [get_bd_pins mig_7series_0/sys_rst]

# Active-low system reset derived from MIG's ui_clk_sync_rst
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 ui_rstn_inv
set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] [get_bd_cells ui_rstn_inv]
connect_bd_net [get_bd_pins ui_rstn_inv/Op1] [get_bd_pins mig_7series_0/ui_clk_sync_rst]

##############
# AXI Clock Converter (XDMA axi_aclk @125 MHz <-> ui_clk)
##############

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 xdma_axi_cc
connect_bd_intf_net [get_bd_intf_pins xdma_0/M_AXI] [get_bd_intf_pins xdma_axi_cc/S_AXI]
connect_bd_net [get_bd_pins xdma_0/axi_aclk]    [get_bd_pins xdma_axi_cc/s_axi_aclk]
connect_bd_net [get_bd_pins xdma_0/axi_aresetn] [get_bd_pins xdma_axi_cc/s_axi_aresetn]
connect_bd_net [get_bd_pins mig_7series_0/ui_clk] [get_bd_pins xdma_axi_cc/m_axi_aclk]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins xdma_axi_cc/m_axi_aresetn]

##############
# CVA6 clock — config-dependent MMCM off the MIG's 100 MHz ui_clk so heavy
# CVA6 configs (e.g. cv64a6_imafdc_sv39) can run slower without dragging
# down the MIG, XDMA, and peripherals.
##############

create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 cpu_clk_gen
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ               {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ $cpu_freq_mhz \
    CONFIG.RESET_PORT                 {resetn} \
    CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
    CONFIG.USE_LOCKED                 {true} \
] [get_bd_cells cpu_clk_gen]
connect_bd_net [get_bd_pins mig_7series_0/ui_clk] [get_bd_pins cpu_clk_gen/clk_in1]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins cpu_clk_gen/resetn]

# Reset synchroniser for the cpu_clk domain.
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 cpu_rstgen
connect_bd_net [get_bd_pins cpu_clk_gen/clk_out1] [get_bd_pins cpu_rstgen/slowest_sync_clk]
connect_bd_net [get_bd_pins cpu_clk_gen/locked]   [get_bd_pins cpu_rstgen/dcm_locked]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins cpu_rstgen/ext_reset_in]

##############
# CVA6 wrapper (RTL module)
##############

create_bd_cell -type module -reference cva6_acorn_wrapper cva6_0
connect_bd_net [get_bd_pins cpu_clk_gen/clk_out1] [get_bd_pins cva6_0/clk]
# rst_n comes from ctrl_regs (host-controlled, AND-ed with cpu_clk domain reset). Wired below.

# AXI clock converter: CVA6 master on cpu_clk -> SmartConnect on ui_clk.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 cva6_axi_cc
connect_bd_intf_net [get_bd_intf_pins cva6_0/m_axi] [get_bd_intf_pins cva6_axi_cc/S_AXI]
connect_bd_net [get_bd_pins cpu_clk_gen/clk_out1]    [get_bd_pins cva6_axi_cc/s_axi_aclk]
connect_bd_net [get_bd_pins cpu_rstgen/peripheral_aresetn] [get_bd_pins cva6_axi_cc/s_axi_aresetn]
connect_bd_net [get_bd_pins mig_7series_0/ui_clk]    [get_bd_pins cva6_axi_cc/m_axi_aclk]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]         [get_bd_pins cva6_axi_cc/m_axi_aresetn]

##############
# AXI SmartConnect — 2 masters (XDMA, CVA6), 4 slaves
##############

create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc
set_property -dict [list \
    CONFIG.NUM_SI {2} \
    CONFIG.NUM_MI {4} \
    CONFIG.NUM_CLKS {1} \
] [get_bd_cells axi_smc]
connect_bd_net [get_bd_pins mig_7series_0/ui_clk] [get_bd_pins axi_smc/aclk]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins axi_smc/aresetn]

connect_bd_intf_net [get_bd_intf_pins xdma_axi_cc/M_AXI]  [get_bd_intf_pins axi_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins cva6_axi_cc/M_AXI]  [get_bd_intf_pins axi_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M00_AXI]    [get_bd_intf_pins mig_7series_0/S_AXI]

##############
# Bootrom (axi_bram_init) — 4 KB at 0x10000
##############

create_bd_cell -type module -reference axi_bram_init bootrom_0
set_property -dict [list \
    CONFIG.MEM_INIT_FILE {bootrom.memh} \
    CONFIG.DEPTH_WORDS {1024} \
] [get_bd_cells bootrom_0]
connect_bd_net [get_bd_pins mig_7series_0/ui_clk] [get_bd_pins bootrom_0/axi_clk]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins bootrom_0/axi_resetn]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M01_AXI] [get_bd_intf_pins bootrom_0/s_axi]

##############
# Console buffer — 64 KB at 0x40000000, host polls
##############

create_bd_cell -type module -reference axi_console_buffer console_0
connect_bd_net [get_bd_pins mig_7series_0/ui_clk] [get_bd_pins console_0/axi_clk]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins console_0/axi_resetn]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M02_AXI] [get_bd_intf_pins console_0/s_axi]

##############
# Control registers — reset, doorbell, status (16 B at 0x60000000)
##############

create_bd_cell -type module -reference axi_ctrl_regs ctrl_0
connect_bd_net [get_bd_pins mig_7series_0/ui_clk] [get_bd_pins ctrl_0/axi_clk]
connect_bd_net [get_bd_pins ui_rstn_inv/Res]      [get_bd_pins ctrl_0/axi_resetn]
connect_bd_intf_net [get_bd_intf_pins axi_smc/M03_AXI] [get_bd_intf_pins ctrl_0/s_axi]

# CVA6 reset = (host-controlled ctrl_regs/cva6_rst_n) AND (cpu_clk-domain
# synchronised system reset). Both are active-low; util_vector_logic AND
# asserts the CVA6 reset if either source asserts.
create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 cva6_rst_and
set_property -dict [list CONFIG.C_OPERATION {and} CONFIG.C_SIZE {1}] [get_bd_cells cva6_rst_and]
connect_bd_net [get_bd_pins ctrl_0/cva6_rst_n]              [get_bd_pins cva6_rst_and/Op1]
connect_bd_net [get_bd_pins cpu_rstgen/peripheral_aresetn]  [get_bd_pins cva6_rst_and/Op2]
connect_bd_net [get_bd_pins cva6_rst_and/Res]               [get_bd_pins cva6_0/rst_n]

# Host-to-CVA6 IRQ doorbell (level): ctrl_regs/host_irq drives PLIC src 1 in cva6_0.
connect_bd_net [get_bd_pins ctrl_0/host_irq] [get_bd_pins cva6_0/host_irq]

# CVA6-to-host IRQ: any time CVA6 writes the status register, ctrl_0 raises usr_irq.
connect_bd_net [get_bd_pins ctrl_0/host_irq_out] [get_bd_pins xdma_0/usr_irq_req]

##############
# Address map
##############

# XDMA host master sees full unified map.
create_bd_addr_seg -range 4K   -offset 0x00010000 \
    [get_bd_addr_spaces {/xdma_0/M_AXI}] \
    [get_bd_addr_segs {/bootrom_0/s_axi/reg0}] SEG_bootrom_xdma
create_bd_addr_seg -range 64K  -offset 0x40000000 \
    [get_bd_addr_spaces {/xdma_0/M_AXI}] \
    [get_bd_addr_segs {/console_0/s_axi/reg0}] SEG_console_xdma
create_bd_addr_seg -range 4K   -offset 0x60000000 \
    [get_bd_addr_spaces {/xdma_0/M_AXI}] \
    [get_bd_addr_segs {/ctrl_0/s_axi/reg0}] SEG_ctrl_xdma
create_bd_addr_seg -range $dram_size -offset 0x80000000 \
    [get_bd_addr_spaces {/xdma_0/M_AXI}] \
    [get_bd_addr_segs {/mig_7series_0/memmap/memaddr}] SEG_dram_xdma

# CVA6 master sees the same map.
create_bd_addr_seg -range 4K   -offset 0x00010000 \
    [get_bd_addr_spaces {/cva6_0/m_axi}] \
    [get_bd_addr_segs {/bootrom_0/s_axi/reg0}] SEG_bootrom_cva6
create_bd_addr_seg -range 64K  -offset 0x40000000 \
    [get_bd_addr_spaces {/cva6_0/m_axi}] \
    [get_bd_addr_segs {/console_0/s_axi/reg0}] SEG_console_cva6
create_bd_addr_seg -range 4K   -offset 0x60000000 \
    [get_bd_addr_spaces {/cva6_0/m_axi}] \
    [get_bd_addr_segs {/ctrl_0/s_axi/reg0}] SEG_ctrl_cva6
create_bd_addr_seg -range $dram_size -offset 0x80000000 \
    [get_bd_addr_spaces {/cva6_0/m_axi}] \
    [get_bd_addr_segs {/mig_7series_0/memmap/memaddr}] SEG_dram_cva6

assign_bd_address
validate_bd_design
