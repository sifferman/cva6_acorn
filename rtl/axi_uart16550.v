// NS16550-compatible UART, headless capture variant — QEMU `virt` UART0
// (VIRT_UART0 @ 0x1000_0000, reg-shift 0, byte registers).
//
// The card has no physical serial line, so instead of driving a wire this
// peripheral *captures* transmitted bytes into a BRAM the host drains over
// XDMA. The guest sees a standard 16550 register map, so the identical binary
// that does 16550 MMIO under QEMU (write THR, poll LSR.THRE) works here.
//
// Single AXI4 slave with an internal address split (one BD interface, like the
// other peripherals — avoids fragile two-interface inference on a module ref):
//
//   local offset < DRAIN_BASE (0x1_0000) : guest 16550 registers (offset[2:0])
//   local offset >=DRAIN_BASE            : host TX-drain window
//       DRAIN_BASE + 0 (32b)  = tx_len   (payload byte count)
//       DRAIN_BASE + 8 ..     = payload bytes (linear)
//
// The drain window is card/host-only infrastructure; a portable binary never
// touches it (on QEMU it drives the real 16550, on the card offsets 0..7).
//
// 16550 register map (DLAB selects DLL/DLM):
//   0 R RBR / W THR / DLL    1 IER / DLM    2 R IIR / W FCR    3 LCR(DLAB=b7)
//   4 MCR                    5 R LSR        6 R MSR            7 SCR
//
// Transmit-only: LSR.DR held 0, RBR reads 0. RX (host->guest input) lands in
// the next pass with the PLIC IRQ wiring.

module axi_uart16550 #(
    parameter ADDR_WIDTH  = 64,
    parameter DATA_WIDTH  = 64,
    parameter ID_WIDTH    = 4,
    parameter DEPTH_WORDS = 8192          // 64 KB TX capture buffer
) (
    input  wire                      axi_clk,
    input  wire                      axi_resetn,

    // Transmit interrupt to PLIC (THRE). Unused until PLIC lands; held low.
    output wire                      uart_irq,

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
    localparam MAX_BYTES      = DEPTH_WORDS * BYTES_PER_WORD;
    localparam DRAIN_BIT      = 16;       // local offset bit selecting drain window

    (* ram_style = "block" *)
    reg [DATA_WIDTH-1:0] mem [0:DEPTH_WORDS-1];

    // 16550 shadow registers (only DLAB / scratch / fifo-enable affect reads).
    reg [7:0] reg_ier_q, reg_lcr_q, reg_mcr_q, reg_scr_q, reg_fcr_q;
    reg [7:0] reg_dll_q, reg_dlm_q;
    wire dlab = reg_lcr_q[7];

    // Captured byte count (payload bytes written so far).
    reg [IDX_BITS+SUBWORD_BITS:0] tx_len_q;
    wire [31:0] tx_len32 = {{(32-(IDX_BITS+SUBWORD_BITS+1)){1'b0}}, tx_len_q};

    assign uart_irq = 1'b0;   // TX-only build raises no interrupt yet

    // =========================================================================
    // Write channel (single-beat). 16550 register writes only; drain window is
    // read-only (writes accepted and discarded so a stray write can't hang).
    // =========================================================================
    reg                aw_seen_d,  aw_seen_q;
    reg [2:0]          aw_off_d,   aw_off_q;     // 16550 register index 0..7
    reg                aw_drain_d, aw_drain_q;   // targeted the drain window
    reg [ID_WIDTH-1:0] aw_id_d,    aw_id_q;
    reg                bvalid_d,   bvalid_q;
    reg [ID_WIDTH-1:0] bid_d,      bid_q;

    wire [7:0] tx_byte      = s_axi_wdata[8*aw_off_q +: 8];
    wire       tx_lane_strb = s_axi_wstrb[aw_off_q];
    wire       wfire        = s_axi_wvalid && s_axi_wready;
    wire       reg_we       = wfire && !aw_drain_q && tx_lane_strb;
    wire       do_tx        = reg_we && (aw_off_q == 3'd0) && !dlab
                              && (tx_len_q < MAX_BYTES);

    always @* begin
        aw_seen_d  = aw_seen_q;
        aw_off_d   = aw_off_q;
        aw_drain_d = aw_drain_q;
        aw_id_d    = aw_id_q;
        bvalid_d   = bvalid_q;
        bid_d      = bid_q;

        if (s_axi_awvalid && s_axi_awready) begin
            aw_seen_d  = 1'b1;
            aw_id_d    = s_axi_awid;
            aw_off_d   = s_axi_awaddr[2:0];
            aw_drain_d = s_axi_awaddr[DRAIN_BIT];
        end
        if (wfire && s_axi_wlast && !bvalid_q) begin
            bvalid_d = 1'b1;
            bid_d    = aw_id_q;
        end
        if (bvalid_q && s_axi_bready) begin
            bvalid_d  = 1'b0;
            aw_seen_d = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            reg_ier_q <= 8'h0; reg_lcr_q <= 8'h0; reg_mcr_q <= 8'h0;
            reg_scr_q <= 8'h0; reg_fcr_q <= 8'h0; reg_dll_q <= 8'h0;
            reg_dlm_q <= 8'h0; tx_len_q  <= 0;
        end else begin
            if (reg_we) begin
                case (aw_off_q)
                    3'd0: if (dlab) reg_dll_q <= tx_byte;     // else THR -> capture
                    3'd1: if (dlab) reg_dlm_q <= tx_byte; else reg_ier_q <= tx_byte;
                    3'd2: reg_fcr_q <= tx_byte;
                    3'd3: reg_lcr_q <= tx_byte;
                    3'd4: reg_mcr_q <= tx_byte;
                    3'd7: reg_scr_q <= tx_byte;
                    default: ;                                 // LSR/MSR read-only
                endcase
            end
            if (do_tx) tx_len_q <= tx_len_q + 1'b1;
        end
    end

    // Payload byte append: byte position tx_len_q -> word index, byte lane.
    wire [IDX_BITS-1:0]     tx_word = tx_len_q[IDX_BITS+SUBWORD_BITS-1:SUBWORD_BITS];
    wire [SUBWORD_BITS-1:0] tx_lane = tx_len_q[SUBWORD_BITS-1:0];
    always @(posedge axi_clk) begin
        if (do_tx) mem[tx_word][8*tx_lane +: 8] <= tx_byte;
    end

    assign s_axi_awready = !aw_seen_q;
    assign s_axi_wready  = aw_seen_q && !bvalid_q;
    assign s_axi_bvalid  = bvalid_q;
    assign s_axi_bid     = bid_q;
    assign s_axi_bresp   = 2'b00;

    // =========================================================================
    // Read channel. Three modes, decided at AR:
    //   REG     : assembled 16550 register word (single beat)
    //   LEN     : tx_len            (drain offset 0..7, single beat)
    //   PAYLOAD : BRAM linear burst (drain offset >= 8)
    // =========================================================================
    localparam [1:0] M_REG = 2'd0, M_LEN = 2'd1, M_PAY = 2'd2;

    // Assembled 16550 register word: each byte lane returns its register, so a
    // byte read at any offset gets the right register from its lane.
    wire [7:0]  lsr = 8'h60;                         // THRE | TEMT, DR=0
    wire [7:0]  iir = reg_fcr_q[0] ? 8'hC1 : 8'h01;  // no interrupt pending
    wire [63:0] reg_word = {
        reg_scr_q,                                   // 7 SCR
        8'h00,                                       // 6 MSR
        lsr,                                         // 5 LSR
        reg_mcr_q,                                   // 4 MCR
        reg_lcr_q,                                   // 3 LCR
        iir,                                         // 2 IIR
        dlab ? reg_dlm_q : reg_ier_q,                // 1 DLM/IER
        dlab ? reg_dll_q : 8'h00                     // 0 DLL/RBR(empty)
    };

    reg [8:0]            count_d, count_q;
    reg [1:0]            mode_d,  mode_q;
    reg [IDX_BITS-1:0]   idx_d,   idx_q;
    reg [ID_WIDTH-1:0]   r_id_d,  r_id_q;
    reg                  rvalid_d, rvalid_q;
    reg                  rlast_d,  rlast_q;
    reg [DATA_WIDTH-1:0] rdata_q;

    wire read_fire = (count_q != 0) && (!rvalid_q || s_axi_rready);
    // payload byte address within drain window = local[15:0] - 8.
    wire [15:0] pay_off = s_axi_araddr[15:0] - 16'd8;

    always @* begin
        count_d  = count_q;
        mode_d   = mode_q;
        idx_d    = idx_q;
        r_id_d   = r_id_q;
        rvalid_d = rvalid_q;
        rlast_d  = rlast_q;
        if (s_axi_arvalid && s_axi_arready) begin
            count_d = s_axi_arlen + 9'd1;
            r_id_d  = s_axi_arid;
            if (!s_axi_araddr[DRAIN_BIT])      mode_d = M_REG;
            else if (s_axi_araddr[15:0] < 8)   mode_d = M_LEN;
            else begin
                mode_d = M_PAY;
                idx_d  = pay_off[SUBWORD_BITS+IDX_BITS-1:SUBWORD_BITS];
            end
        end
        if (read_fire) begin
            rvalid_d = 1'b1;
            rlast_d  = (count_q == 9'd1);
            idx_d    = idx_q + 1'b1;
            count_d  = count_q - 9'd1;
        end else if (rvalid_q && s_axi_rready) begin
            rvalid_d = 1'b0;
            rlast_d  = 1'b0;
        end
    end

    always @(posedge axi_clk) begin
        if (!axi_resetn) begin
            count_q <= 9'd0; mode_q <= M_REG; idx_q <= {IDX_BITS{1'b0}};
            r_id_q  <= {ID_WIDTH{1'b0}}; rvalid_q <= 1'b0; rlast_q <= 1'b0;
            rdata_q <= {DATA_WIDTH{1'b0}};
        end else begin
            count_q <= count_d; mode_q <= mode_d; idx_q <= idx_d;
            r_id_q  <= r_id_d;  rvalid_q <= rvalid_d; rlast_q <= rlast_d;
            if (read_fire) begin
                case (mode_q)
                    M_LEN:   rdata_q <= {{(DATA_WIDTH-32){1'b0}}, tx_len32};
                    M_PAY:   rdata_q <= mem[idx_q];
                    default: rdata_q <= reg_word;
                endcase
            end
        end
    end

    assign s_axi_arready = (count_q == 0);
    assign s_axi_rvalid  = rvalid_q;
    assign s_axi_rdata   = rdata_q;
    assign s_axi_rid     = r_id_q;
    assign s_axi_rlast   = rlast_q;
    assign s_axi_rresp   = 2'b00;

endmodule
