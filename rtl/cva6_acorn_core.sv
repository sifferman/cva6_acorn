// CVA6 wrapper for the Acorn block design.
//
// Exposes a plain-Verilog AXI4 master so Vivado IP Integrator can connect it
// to the SmartConnect without seeing any SystemVerilog struct types.

`include "axi/assign.svh"
`include "axi/typedef.svh"

// Inner SystemVerilog module. The plain-Verilog cva6_acorn_wrapper.v
// instantiates this one — that indirection is required because Vivado IP
// Integrator's `create_bd_cell -type module -reference` rejects .sv top files.
module cva6_acorn_core
  import ariane_pkg::*;
#(
    // Pulled in from the FPGA config package. Override at instantiation if
    // a different config is selected.
    parameter config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(
        cva6_config_pkg::cva6_cfg
    ),

    parameter int unsigned AxiAddrWidth = 64,
    parameter int unsigned AxiDataWidth = 64,
    parameter int unsigned AxiIdWidth   = 4,
    parameter int unsigned AxiUserWidth = 1
) (
    input  logic                       clk,
    input  logic                       rst_n,

    // Host-driven IRQ (PLIC source 1). Held high while host wants attention.
    input  logic                       host_irq,

    // AXI4 master ----------------------------------------------------------
    output logic [AxiIdWidth-1:0]      m_axi_awid,
    output logic [AxiAddrWidth-1:0]    m_axi_awaddr,
    output logic [7:0]                 m_axi_awlen,
    output logic [2:0]                 m_axi_awsize,
    output logic [1:0]                 m_axi_awburst,
    output logic                       m_axi_awlock,
    output logic [3:0]                 m_axi_awcache,
    output logic [2:0]                 m_axi_awprot,
    output logic [3:0]                 m_axi_awqos,
    output logic [3:0]                 m_axi_awregion,
    output logic                       m_axi_awvalid,
    input  logic                       m_axi_awready,

    output logic [AxiDataWidth-1:0]    m_axi_wdata,
    output logic [AxiDataWidth/8-1:0]  m_axi_wstrb,
    output logic                       m_axi_wlast,
    output logic                       m_axi_wvalid,
    input  logic                       m_axi_wready,

    input  logic [AxiIdWidth-1:0]      m_axi_bid,
    input  logic [1:0]                 m_axi_bresp,
    input  logic                       m_axi_bvalid,
    output logic                       m_axi_bready,

    output logic [AxiIdWidth-1:0]      m_axi_arid,
    output logic [AxiAddrWidth-1:0]    m_axi_araddr,
    output logic [7:0]                 m_axi_arlen,
    output logic [2:0]                 m_axi_arsize,
    output logic [1:0]                 m_axi_arburst,
    output logic                       m_axi_arlock,
    output logic [3:0]                 m_axi_arcache,
    output logic [2:0]                 m_axi_arprot,
    output logic [3:0]                 m_axi_arqos,
    output logic [3:0]                 m_axi_arregion,
    output logic                       m_axi_arvalid,
    input  logic                       m_axi_arready,

    input  logic [AxiIdWidth-1:0]      m_axi_rid,
    input  logic [AxiDataWidth-1:0]    m_axi_rdata,
    input  logic [1:0]                 m_axi_rresp,
    input  logic                       m_axi_rlast,
    input  logic                       m_axi_rvalid,
    output logic                       m_axi_rready
);

    // Reset vector: bootrom is mapped at 0x00010000.
    localparam logic [63:0] BootAddr = 64'h0000_0000_0001_0000;

    // CVA6's NoC-side AXI request/response structs.
    ariane_axi::req_t  ariane_req;
    ariane_axi::resp_t ariane_resp;

    // Interrupt inputs — milestone 1 uses only the external (host_irq) line.
    // ipi/timer come from the CLINT, which we don't instantiate yet.
    logic [1:0] irq;
    assign irq = {1'b0, host_irq};   // {S-mode, M-mode external}

    // Instantiate the cva6 core directly (rather than the corev_apu/src/ariane.sv
    // passthrough wrapper). Override the NoC AXI type parameters with
    // ariane_axi:: types so AXI_ASSIGN_FROM_REQ / TO_RESP work unchanged below.
    // We don't override rvfi_probes_*_t — those default to types derived from
    // CVA6Cfg inside cva6.sv, and we leave rvfi_probes_o unconnected.
    cva6 #(
        .CVA6Cfg              ( CVA6Cfg               ),
        .axi_ar_chan_t        ( ariane_axi::ar_chan_t ),
        .axi_aw_chan_t        ( ariane_axi::aw_chan_t ),
        .axi_w_chan_t         ( ariane_axi::w_chan_t  ),
        .noc_req_t            ( ariane_axi::req_t     ),
        .noc_resp_t           ( ariane_axi::resp_t    )
    ) i_cva6 (
        .clk_i        ( clk                ),
        .rst_ni       ( rst_n              ),
        .boot_addr_i  ( BootAddr[CVA6Cfg.VLEN-1:0] ),
        .hart_id_i    ( '0                 ),
        .irq_i        ( irq                ),
        .ipi_i        ( 1'b0               ),
        .time_irq_i   ( 1'b0               ),
        .rvfi_probes_o( /* unconnected */  ),
        .debug_req_i  ( 1'b0               ),
        .noc_req_o    ( ariane_req         ),
        .noc_resp_i   ( ariane_resp        )
    );

    // Convert ariane_axi struct <-> plain wires using a private SV interface
    // and the upstream AXI_ASSIGN macros.
    AXI_BUS #(
        .AXI_ADDR_WIDTH ( AxiAddrWidth ),
        .AXI_DATA_WIDTH ( AxiDataWidth ),
        .AXI_ID_WIDTH   ( AxiIdWidth   ),
        .AXI_USER_WIDTH ( AxiUserWidth )
    ) axi_intf();

    `AXI_ASSIGN_FROM_REQ(axi_intf, ariane_req)
    `AXI_ASSIGN_TO_RESP (ariane_resp, axi_intf)

    // Plain-Verilog port driving from the interface ----------------------------
    assign m_axi_awid     = axi_intf.aw_id;
    assign m_axi_awaddr   = axi_intf.aw_addr;
    assign m_axi_awlen    = axi_intf.aw_len;
    assign m_axi_awsize   = axi_intf.aw_size;
    assign m_axi_awburst  = axi_intf.aw_burst;
    assign m_axi_awlock   = axi_intf.aw_lock;
    assign m_axi_awcache  = axi_intf.aw_cache;
    assign m_axi_awprot   = axi_intf.aw_prot;
    assign m_axi_awqos    = axi_intf.aw_qos;
    assign m_axi_awregion = axi_intf.aw_region;
    assign m_axi_awvalid  = axi_intf.aw_valid;
    assign axi_intf.aw_ready = m_axi_awready;

    assign m_axi_wdata   = axi_intf.w_data;
    assign m_axi_wstrb   = axi_intf.w_strb;
    assign m_axi_wlast   = axi_intf.w_last;
    assign m_axi_wvalid  = axi_intf.w_valid;
    assign axi_intf.w_ready = m_axi_wready;

    assign axi_intf.b_id    = m_axi_bid;
    assign axi_intf.b_resp  = m_axi_bresp;
    assign axi_intf.b_valid = m_axi_bvalid;
    assign m_axi_bready  = axi_intf.b_ready;

    assign m_axi_arid     = axi_intf.ar_id;
    assign m_axi_araddr   = axi_intf.ar_addr;
    assign m_axi_arlen    = axi_intf.ar_len;
    assign m_axi_arsize   = axi_intf.ar_size;
    assign m_axi_arburst  = axi_intf.ar_burst;
    assign m_axi_arlock   = axi_intf.ar_lock;
    assign m_axi_arcache  = axi_intf.ar_cache;
    assign m_axi_arprot   = axi_intf.ar_prot;
    assign m_axi_arqos    = axi_intf.ar_qos;
    assign m_axi_arregion = axi_intf.ar_region;
    assign m_axi_arvalid  = axi_intf.ar_valid;
    assign axi_intf.ar_ready = m_axi_arready;

    assign axi_intf.r_id    = m_axi_rid;
    assign axi_intf.r_data  = m_axi_rdata;
    assign axi_intf.r_resp  = m_axi_rresp;
    assign axi_intf.r_last  = m_axi_rlast;
    assign axi_intf.r_valid = m_axi_rvalid;
    assign m_axi_rready  = axi_intf.r_ready;

endmodule
