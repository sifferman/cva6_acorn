// 16-byte AXI4 control register file.
//
// Register map (host-visible offsets, all 32-bit):
//   0x00 CTRL    bit0 = CVA6_RST_N (1 = release CVA6 from reset)
//   0x04 DOORBELL bit0 = HOST_IRQ (1 -> raises external IRQ to CVA6 PLIC)
//   0x08 STATUS  written by CVA6 -> raises usr_irq to host XDMA
//   0x0C SCRATCH free for host/firmware to use
//
// All other addresses read as zero.
//
// Plain Verilog (.v) — see note in axi_bram_init.v.

module axi_ctrl_regs #(
    parameter ADDR_WIDTH = 64,
    parameter DATA_WIDTH = 64,
    parameter ID_WIDTH   = 4
) (
    input  wire                      axi_clk,
    input  wire                      axi_resetn,

    // CVA6 reset (released by host write to CTRL[0]).
    output wire                      cva6_rst_n,
    // Host -> CVA6 doorbell IRQ (level).
    output wire                      host_irq,
    // CVA6 -> host doorbell IRQ (level), drives XDMA usr_irq_req.
    output wire                      host_irq_out,

    input  wire [ID_WIDTH-1:0]       s_axi_awid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [7:0]                s_axi_awlen,
    input  wire [2:0]                s_axi_awsize,
    input  wire [1:0]                s_axi_awburst,
    input  wire                      s_axi_awlock,
    input  wire [3:0]                s_axi_awcache,
    input  wire [2:0]                s_axi_awprot,
    input  wire [3:0]                s_axi_awqos,
    input  wire [3:0]                s_axi_awregion,
    input  wire                      s_axi_awvalid,
    output wire                      s_axi_awready,

    input  wire [DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0]   s_axi_wstrb,
    input  wire                      s_axi_wlast,
    input  wire                      s_axi_wvalid,
    output wire                      s_axi_wready,

    output wire [ID_WIDTH-1:0]       s_axi_bid,
    output wire [1:0]                s_axi_bresp,
    output wire                      s_axi_bvalid,
    input  wire                      s_axi_bready,

    input  wire [ID_WIDTH-1:0]       s_axi_arid,
    input  wire [ADDR_WIDTH-1:0]     s_axi_araddr,
    input  wire [7:0]                s_axi_arlen,
    input  wire [2:0]                s_axi_arsize,
    input  wire [1:0]                s_axi_arburst,
    input  wire                      s_axi_arlock,
    input  wire [3:0]                s_axi_arcache,
    input  wire [2:0]                s_axi_arprot,
    input  wire [3:0]                s_axi_arqos,
    input  wire [3:0]                s_axi_arregion,
    input  wire                      s_axi_arvalid,
    output wire                      s_axi_arready,

    output wire [ID_WIDTH-1:0]       s_axi_rid,
    output wire [DATA_WIDTH-1:0]     s_axi_rdata,
    output wire [1:0]                s_axi_rresp,
    output wire                      s_axi_rlast,
    output wire                      s_axi_rvalid,
    input  wire                      s_axi_rready
);

    // --- Registers ------------------------------------------------------------
    reg [31:0] reg_ctrl_q,     reg_ctrl_d;
    reg [31:0] reg_doorbell_q, reg_doorbell_d;
    reg [31:0] reg_status_q,   reg_status_d;
    reg [31:0] reg_scratch_q,  reg_scratch_d;

    assign cva6_rst_n   = reg_ctrl_q[0] & axi_resetn;
    assign host_irq     = reg_doorbell_q[0];
    assign host_irq_out = |reg_status_q;

    function automatic [31:0] write_strobe;
        input [31:0] cur;
        input [31:0] din;
        input [3:0]  strb;
        integer i;
        begin
            for (i = 0; i < 4; i = i + 1)
                write_strobe[8*i +: 8] = strb[i] ? din[8*i +: 8] : cur[8*i +: 8];
        end
    endfunction

    function automatic [31:0] read_reg;
        input [3:0] off;
        begin
            case (off & 4'hC)
                4'h0:    read_reg = reg_ctrl_q;
                4'h4:    read_reg = reg_doorbell_q;
                4'h8:    read_reg = reg_status_q;
                4'hC:    read_reg = reg_scratch_q;
                default: read_reg = 32'h0;
            endcase
        end
    endfunction

    // --- Write channel --------------------------------------------------------
    reg [3:0]            w_off_q,   w_off_d;
    reg                  aw_seen_q, aw_seen_d;
    reg [ID_WIDTH-1:0]   aw_id_q,   aw_id_d;
    reg                  bvalid_q,  bvalid_d;
    reg [ID_WIDTH-1:0]   bid_q,     bid_d;
    reg [1:0]            bresp_q,   bresp_d;

    reg [31:0] w_din;
    reg [3:0]  w_strb;

    always @* begin
        reg_ctrl_d     = reg_ctrl_q;
        reg_doorbell_d = reg_doorbell_q;
        reg_status_d   = reg_status_q;
        reg_scratch_d  = reg_scratch_q;

        w_off_d   = w_off_q;
        aw_seen_d = aw_seen_q;
        aw_id_d   = aw_id_q;
        bvalid_d  = bvalid_q;
        bid_d     = bid_q;
        bresp_d   = bresp_q;

        w_din  = s_axi_wdata[8*w_off_q +: 32];
        w_strb = s_axi_wstrb[w_off_q +: 4];

        if (s_axi_awvalid && s_axi_awready) begin
            aw_seen_d = 1'b1;
            aw_id_d   = s_axi_awid;
            w_off_d   = s_axi_awaddr[3:0];
        end

        if (s_axi_wvalid && s_axi_wready) begin
            case (w_off_q & 4'hC)
                4'h0: reg_ctrl_d     = write_strobe(reg_ctrl_q,     w_din, w_strb);
                4'h4: reg_doorbell_d = write_strobe(reg_doorbell_q, w_din, w_strb);
                4'h8: reg_status_d   = write_strobe(reg_status_q,   w_din, w_strb);
                4'hC: reg_scratch_d  = write_strobe(reg_scratch_q,  w_din, w_strb);
            endcase
            if (s_axi_wlast && !bvalid_q) begin
                bvalid_d = 1'b1;
                bid_d    = aw_id_q;
                bresp_d  = 2'b00;
            end
        end

        if (bvalid_q && s_axi_bready) begin
            bvalid_d  = 1'b0;
            aw_seen_d = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            reg_ctrl_q     <= 32'h0;     // hold CVA6 in reset until host releases
            reg_doorbell_q <= 32'h0;
            reg_status_q   <= 32'h0;
            reg_scratch_q  <= 32'h0;
            w_off_q        <= 4'h0;
            aw_seen_q      <= 1'b0;
            aw_id_q        <= {ID_WIDTH{1'b0}};
            bvalid_q       <= 1'b0;
            bid_q          <= {ID_WIDTH{1'b0}};
            bresp_q        <= 2'b00;
        end else begin
            reg_ctrl_q     <= reg_ctrl_d;
            reg_doorbell_q <= reg_doorbell_d;
            reg_status_q   <= reg_status_d;
            reg_scratch_q  <= reg_scratch_d;
            w_off_q        <= w_off_d;
            aw_seen_q      <= aw_seen_d;
            aw_id_q        <= aw_id_d;
            bvalid_q       <= bvalid_d;
            bid_q          <= bid_d;
            bresp_q        <= bresp_d;
        end
    end

    assign s_axi_awready = !aw_seen_q;
    assign s_axi_wready  = aw_seen_q && !bvalid_q;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_bid     = bid_q;
    assign s_axi_bresp   = bresp_q;

    // --- Read channel ---------------------------------------------------------
    reg [8:0]            r_count_q, r_count_d;
    reg [3:0]            r_off_q,   r_off_d;
    reg [ID_WIDTH-1:0]   r_id_q,    r_id_d;
    reg                  rvalid_q,  rvalid_d;
    reg [DATA_WIDTH-1:0] rdata_q,   rdata_d;
    reg [ID_WIDTH-1:0]   rid_q,     rid_d;
    reg                  rlast_q,   rlast_d;
    reg [1:0]            rresp_q,   rresp_d;

    always @* begin
        r_count_d = r_count_q;
        r_off_d   = r_off_q;
        r_id_d    = r_id_q;
        rvalid_d  = rvalid_q;
        rdata_d   = rdata_q;
        rid_d     = rid_q;
        rlast_d   = rlast_q;
        rresp_d   = rresp_q;

        if (s_axi_arvalid && s_axi_arready) begin
            r_count_d = s_axi_arlen + 9'd1;
            r_off_d   = s_axi_araddr[3:0];
            r_id_d    = s_axi_arid;
        end
        if (r_count_q != 0 && (!rvalid_q || s_axi_rready)) begin
            rvalid_d  = 1'b1;
            rdata_d   = {32'h0, read_reg(r_off_q)};
            rid_d     = r_id_q;
            rlast_d   = (r_count_q == 9'd1);
            rresp_d   = 2'b00;
            r_off_d   = r_off_q + 4'h4;
            r_count_d = r_count_q - 9'd1;
        end else if (rvalid_q && s_axi_rready) begin
            rvalid_d = 1'b0;
            rlast_d  = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            r_count_q <= 9'd0;
            r_off_q   <= 4'h0;
            r_id_q    <= {ID_WIDTH{1'b0}};
            rvalid_q  <= 1'b0;
            rdata_q   <= {DATA_WIDTH{1'b0}};
            rid_q     <= {ID_WIDTH{1'b0}};
            rlast_q   <= 1'b0;
            rresp_q   <= 2'b00;
        end else begin
            r_count_q <= r_count_d;
            r_off_q   <= r_off_d;
            r_id_q    <= r_id_d;
            rvalid_q  <= rvalid_d;
            rdata_q   <= rdata_d;
            rid_q     <= rid_d;
            rlast_q   <= rlast_d;
            rresp_q   <= rresp_d;
        end
    end

    assign s_axi_arready = (r_count_q == 0);
    assign s_axi_rvalid  = rvalid_q;
    assign s_axi_rdata   = rdata_q;
    assign s_axi_rid     = rid_q;
    assign s_axi_rlast   = rlast_q;
    assign s_axi_rresp   = rresp_q;

endmodule
