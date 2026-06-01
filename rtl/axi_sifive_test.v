// SiFive Test finisher — QEMU `virt` compatible (VIRT_TEST @ 0x0010_0000).
//
// A baremetal binary signals completion by writing a 32-bit word here:
//   0x0000_5555  FINISH_PASS   (exit code 0)
//   <code>_3333  FINISH_FAIL   (exit code = bits [31:16])
//   0x0000_7777  FINISH_RESET  (request reset)
// This matches QEMU's hw/misc/sifive_test.c, so the same binary that calls
// `*(volatile uint32_t*)0x100000 = 0x5555;` to exit under QEMU also exits here.
//
// On a recognised PASS/FAIL the finisher latches the result, raises a level
// IRQ to the host (wired to the XDMA usr_irq), and the host reads back the
// latched word at offset 0 to learn pass/fail + exit code.
//
// 64-bit AXI4 slave, single-beat, mirrors the handshake style of
// axi_ctrl_regs.v / axi_console_buffer.v. The finisher register lives at
// offset 0 (byte lane 0 on the 64-bit bus); a 32-bit `sw` to the base hits it.

module axi_sifive_test #(
    parameter ADDR_WIDTH = 64,
    parameter DATA_WIDTH = 64,
    parameter ID_WIDTH   = 4
) (
    input  wire                      axi_clk,
    input  wire                      axi_resetn,

    // Latched finisher state.
    output wire                      test_done,   // level: PASS or FAIL seen
    output wire                      test_pass,   // valid when test_done
    output wire                      test_irq,    // -> XDMA usr_irq (== test_done)
    output wire                      test_reset,  // pulse: FINISH_RESET written

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
    localparam [15:0] CMD_PASS  = 16'h5555;
    localparam [15:0] CMD_FAIL  = 16'h3333;
    localparam [15:0] CMD_RESET = 16'h7777;

    // result_q: the latched finisher word the host reads back (0 until done).
    reg [31:0] result_q,  result_d;
    reg        done_q,    done_d;
    reg        pass_q,    pass_d;
    reg        reset_q,   reset_d;

    assign test_done  = done_q;
    assign test_pass  = pass_q;
    assign test_irq   = done_q;
    assign test_reset = reset_q;

    // --- Write channel (single-beat) -----------------------------------------
    reg               aw_seen_d, aw_seen_q;
    reg [ID_WIDTH-1:0] aw_id_d,  aw_id_q;
    reg               bvalid_d,  bvalid_q;
    reg [ID_WIDTH-1:0] bid_d,    bid_q;

    // The finisher reg sits at offset 0 -> byte lane 0 on the 64-bit bus.
    wire [15:0] cmd     = s_axi_wdata[15:0];
    wire        we_word = s_axi_wvalid && s_axi_wready && s_axi_wstrb[0];

    always @* begin
        result_d  = result_q;
        done_d    = done_q;
        pass_d    = pass_q;
        reset_d   = 1'b0;            // pulse
        aw_seen_d = aw_seen_q;
        aw_id_d   = aw_id_q;
        bvalid_d  = bvalid_q;
        bid_d     = bid_q;

        if (s_axi_awvalid && s_axi_awready) begin
            aw_seen_d = 1'b1;
            aw_id_d   = s_axi_awid;
        end

        if (we_word) begin
            case (cmd)
                CMD_PASS: begin result_d = s_axi_wdata[31:0]; done_d = 1'b1; pass_d = 1'b1; end
                CMD_FAIL: begin result_d = s_axi_wdata[31:0]; done_d = 1'b1; pass_d = 1'b0; end
                // RESET clears the latched result so the host can wipe residue
                // between runs without a PCIe reset.
                CMD_RESET: begin result_d = 32'h0; done_d = 1'b0; pass_d = 1'b0; reset_d = 1'b1; end
                default: /* ignore unknown commands */ ;
            endcase
            if (s_axi_wlast && !bvalid_q) begin
                bvalid_d = 1'b1;
                bid_d    = aw_id_q;
            end
        end

        if (bvalid_q && s_axi_bready) begin
            bvalid_d  = 1'b0;
            aw_seen_d = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            result_q  <= 32'h0;
            done_q    <= 1'b0;
            pass_q    <= 1'b0;
            reset_q   <= 1'b0;
            aw_seen_q <= 1'b0;
            aw_id_q   <= {ID_WIDTH{1'b0}};
            bvalid_q  <= 1'b0;
            bid_q     <= {ID_WIDTH{1'b0}};
        end else begin
            result_q  <= result_d;
            done_q    <= done_d;
            pass_q    <= pass_d;
            reset_q   <= reset_d;
            aw_seen_q <= aw_seen_d;
            aw_id_q   <= aw_id_d;
            bvalid_q  <= bvalid_d;
            bid_q     <= bid_d;
        end
    end

    assign s_axi_awready = !aw_seen_q;
    assign s_axi_wready  = aw_seen_q && !bvalid_q;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_bid     = bid_q;
    assign s_axi_bresp   = 2'b00;

    // --- Read channel (single-beat; returns latched result in lane 0) ---------
    reg                  rvalid_d,  rvalid_q;
    reg [DATA_WIDTH-1:0] rdata_d,   rdata_q;
    reg [ID_WIDTH-1:0]   rid_d,     rid_q;
    reg                  busy_d,    busy_q;

    always @* begin
        rvalid_d = rvalid_q;
        rdata_d  = rdata_q;
        rid_d    = rid_q;
        busy_d   = busy_q;

        if (s_axi_arvalid && s_axi_arready) begin
            busy_d  = 1'b1;
            rid_d   = s_axi_arid;
            rdata_d = {32'h0, result_q};
        end
        if (busy_q && (!rvalid_q || s_axi_rready)) begin
            rvalid_d = 1'b1;
            busy_d   = 1'b0;
        end else if (rvalid_q && s_axi_rready) begin
            rvalid_d = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            rvalid_q <= 1'b0;
            rdata_q  <= {DATA_WIDTH{1'b0}};
            rid_q    <= {ID_WIDTH{1'b0}};
            busy_q   <= 1'b0;
        end else begin
            rvalid_q <= rvalid_d;
            rdata_q  <= rdata_d;
            rid_q    <= rid_d;
            busy_q   <= busy_d;
        end
    end

    assign s_axi_arready = !busy_q && !rvalid_q;
    assign s_axi_rvalid  = rvalid_q;
    assign s_axi_rdata   = rdata_q;
    assign s_axi_rid     = rid_q;
    assign s_axi_rlast   = 1'b1;
    assign s_axi_rresp   = 2'b00;

endmodule
