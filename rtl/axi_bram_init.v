// 4 KB AXI4 read-only BRAM initialised from a $readmemh file.
// Used as the CVA6 bootrom at 0x10000.
//
// Notes:
//   - Read-only: writes accepted but ignored, BRESP = OKAY.
//   - Single-beat or burst reads up to AxiLen+1; data is read combinationally
//     from the BRAM register file (registered output, 1-cycle latency).
//   - Word width matches the bus (64 bits). The bootrom .memh file is generated
//     at the 64-bit word granularity.

module axi_bram_init #(
    parameter ADDR_WIDTH    = 64,
    parameter DATA_WIDTH    = 64,
    parameter ID_WIDTH      = 4,
    parameter DEPTH_WORDS   = 1024,            // 1024 * 8 B = 8 KB
    parameter MEM_INIT_FILE = "bootrom.memh"
) (
    input  wire                      axi_clk,
    input  wire                      axi_resetn,

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

    localparam BYTES_PER_WORD = DATA_WIDTH / 8;
    localparam IDX_BITS       = $clog2(DEPTH_WORDS);
    localparam SUBWORD_BITS   = $clog2(BYTES_PER_WORD);

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH_WORDS-1];

    initial begin
        $readmemh(MEM_INIT_FILE, mem);
    end

    // --- Write channel: accept and discard (read-only ROM) --------------------
    reg                  aw_seen_d,     aw_seen_q;
    reg                  w_last_seen_d, w_last_seen_q;
    reg [ID_WIDTH-1:0]   aw_id_d,       aw_id_q;
    reg                  bvalid_d,      bvalid_q;
    reg [ID_WIDTH-1:0]   bid_d,         bid_q;
    reg [1:0]            bresp_d,       bresp_q;

    always @* begin
        aw_seen_d     = aw_seen_q;
        w_last_seen_d = w_last_seen_q;
        aw_id_d       = aw_id_q;
        bvalid_d      = bvalid_q;
        bid_d         = bid_q;
        bresp_d       = bresp_q;

        if (s_axi_awvalid && s_axi_awready) begin
            aw_seen_d = 1'b1;
            aw_id_d   = s_axi_awid;
        end
        if (s_axi_wvalid && s_axi_wready && s_axi_wlast) begin
            w_last_seen_d = 1'b1;
        end
        if (aw_seen_q && w_last_seen_q && !bvalid_q) begin
            bvalid_d = 1'b1;
            bid_d    = aw_id_q;
            bresp_d  = 2'b00;
        end
        if (bvalid_q && s_axi_bready) begin
            bvalid_d      = 1'b0;
            aw_seen_d     = 1'b0;
            w_last_seen_d = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            aw_seen_q     <= 1'b0;
            w_last_seen_q <= 1'b0;
            aw_id_q       <= {ID_WIDTH{1'b0}};
            bvalid_q      <= 1'b0;
            bid_q         <= {ID_WIDTH{1'b0}};
            bresp_q       <= 2'b00;
        end else begin
            aw_seen_q     <= aw_seen_d;
            w_last_seen_q <= w_last_seen_d;
            aw_id_q       <= aw_id_d;
            bvalid_q      <= bvalid_d;
            bid_q         <= bid_d;
            bresp_q       <= bresp_d;
        end
    end

    assign s_axi_awready = !aw_seen_q;
    assign s_axi_wready  = aw_seen_q && !w_last_seen_q;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_bid     = bid_q;
    assign s_axi_bresp   = bresp_q;

    // --- Read channel ---------------------------------------------------------
    reg [8:0]            r_count_d, r_count_q;
    reg [IDX_BITS-1:0]   r_idx_d,   r_idx_q;
    reg [ID_WIDTH-1:0]   r_id_d,    r_id_q;
    reg                  rvalid_d,  rvalid_q;
    reg [DATA_WIDTH-1:0] rdata_d,   rdata_q;
    reg [ID_WIDTH-1:0]   rid_d,     rid_q;
    reg                  rlast_d,   rlast_q;
    reg [1:0]            rresp_d,   rresp_q;

    always @* begin
        r_count_d = r_count_q;
        r_idx_d   = r_idx_q;
        r_id_d    = r_id_q;
        rvalid_d  = rvalid_q;
        rdata_d   = rdata_q;
        rid_d     = rid_q;
        rlast_d   = rlast_q;
        rresp_d   = rresp_q;

        if (s_axi_arvalid && s_axi_arready) begin
            r_count_d = s_axi_arlen + 9'd1;
            r_idx_d   = s_axi_araddr[SUBWORD_BITS+IDX_BITS-1 : SUBWORD_BITS];
            r_id_d    = s_axi_arid;
        end

        if (r_count_q != 0 && (!rvalid_q || s_axi_rready)) begin
            rvalid_d  = 1'b1;
            rdata_d   = mem[r_idx_q];
            rid_d     = r_id_q;
            rlast_d   = (r_count_q == 9'd1);
            rresp_d   = 2'b00;
            r_idx_d   = r_idx_q + 1'b1;
            r_count_d = r_count_q - 9'd1;
        end else if (rvalid_q && s_axi_rready) begin
            rvalid_d = 1'b0;
            rlast_d  = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            r_count_q <= 9'd0;
            r_idx_q   <= {IDX_BITS{1'b0}};
            r_id_q    <= {ID_WIDTH{1'b0}};
            rvalid_q  <= 1'b0;
            rdata_q   <= {DATA_WIDTH{1'b0}};
            rid_q     <= {ID_WIDTH{1'b0}};
            rlast_q   <= 1'b0;
            rresp_q   <= 2'b00;
        end else begin
            r_count_q <= r_count_d;
            r_idx_q   <= r_idx_d;
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
