/**
 * valkyrie_pcie_core.v - Valkyrie PCIe DMA Engine (RTL)
 * Synthesizable FPGA core for HFT market data capture.
 *
 * Captures a 64-bit AXI-Stream of market data into C_NUM_RINGS circular ring
 * buffers and stamps every packet with the hardware arrival timestamp, so the
 * host can compute true wire-to-strategy latency.
 *
 * Ring record layout (must match include/valkyrie.h: valkyrie_pkt_meta_t):
 *   [0x00] hw_timestamp       u64  latched on the first beat of the frame
 *   [0x08] packet_length      u32  on-wire frame length
 *   [0x0C] captured_length    u32  bytes actually stored
 *   [0x10] port_id / flags / protocol / _rsvd        4 x u16
 *   [0x18] hw_latency_cycles  u32  first beat -> ring publish, in core clocks
 *   [0x1C] _rsvd2             u32
 *   [0x20] payload
 * Records are contiguous and the write pointer wraps (C_RING_SIZE must be a
 * power of two); user space walks them as { header, payload } pairs.
 *
 * Register map: the canonical BAR0 map in include/valkyrie.h. No register
 * offset is decoded here from a private copy -- keep both files in step.
 */
`timescale 1ns / 1ps
`default_nettype none

// Must match VALKYRIE_PKT_HDR_SIZE in include/valkyrie.h (the tb asserts it).
`ifndef VALKYRIE_HDR_BYTES
 `define VALKYRIE_HDR_BYTES 32
`endif

module valkyrie_pcie_core #(
    parameter C_NUM_RINGS    = 4,
    parameter C_RING_SIZE    = 2*1024*1024,   // bytes per ring, power of two
    parameter C_MSIX_VECTORS = 4
)(
    input  wire s_axi_aclk,
    input  wire s_axi_aresetn,
    input  wire [31:0] s_axi_awaddr,
    input  wire s_axi_awvalid,
    output reg s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0] s_axi_wstrb,
    input  wire s_axi_wvalid,
    output reg s_axi_wready,
    output reg [1:0] s_axi_bresp,
    output reg s_axi_bvalid,
    input  wire s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire s_axi_arvalid,
    output reg s_axi_arready,
    output reg [31:0] s_axi_rdata,
    output reg [1:0] s_axi_rresp,
    output reg s_axi_rvalid,
    input  wire s_axi_rready,
    input  wire [63:0] s_axis_tdata,
    input  wire [7:0] s_axis_tkeep,
    input  wire s_axis_tlast,
    input  wire s_axis_tvalid,
    output wire s_axis_tready,
    input  wire s_axis_tuser,
    output wire [C_MSIX_VECTORS-1:0] msi_irq,
    input  wire [63:0] hw_timestamp,
    output wire [3:0] led
);

    // ── Register file (BAR0) ──
    reg [31:0] r_dma_ctrl, r_irq_ctrl, r_irq_status;
    reg [31:0] r_feed_port;
    reg [31:0] r_ring_size  [C_NUM_RINGS-1:0];
    reg [63:0] r_ring_base  [C_NUM_RINGS-1:0];
    reg [31:0] r_pkt_count  [C_NUM_RINGS-1:0];   // per-ring, wraps
    reg [63:0] r_bytes_written;                  // all rings, unwrapped
    reg [31:0] r_ring_ovf;                       // sticky overflow counter
    reg        r_dma_err;                        // sticky tuser / framing error

    // ── Capture-latency instrumentation ──
    reg [31:0] r_lat_last, r_lat_min, r_lat_max, r_lat_pkts;
    reg [63:0] r_lat_sum;

    // ── Ring state ──
    reg [31:0] r_ring_wp [C_NUM_RINGS-1:0];      // byte offset within the ring

    // Ring storage model: in the real design the DMA master writes these bytes
    // into host memory at r_ring_base; here they live in block RAM so the
    // capture path is fully simulatable. The (unmodelled) DMA master is what
    // reads it back out, so inside this module it is write-only -- hence the
    // lint waiver.
    /* verilator lint_off UNUSEDSIGNAL */
    reg [7:0] mem [0:C_NUM_RINGS-1][0:C_RING_SIZE-1];
    /* verilator lint_on UNUSEDSIGNAL */

    wire dma_enable = r_dma_ctrl[0];

    /* C_NUM_RINGS must be a power of two: the round-robin ring counter simply
     * wraps in its own width. */
    localparam integer C_RING_W = (C_NUM_RINGS <= 2) ? 1 : $clog2(C_NUM_RINGS);
    localparam [31:0] C_RING_MASK = C_RING_SIZE - 1;
    localparam [31:0] C_RING_B32  = C_RING_SIZE;
    localparam [31:0] C_HDR_B32   = `VALKYRIE_HDR_BYTES;
    localparam [63:0] C_HDR_B64   = `VALKYRIE_HDR_BYTES;
    localparam integer C_HDR_BYTES_I = `VALKYRIE_HDR_BYTES;

    reg [1:0]  wstate, rstate, axstate;
    reg [31:0] waddr, raddr;
    reg [C_RING_W-1:0] r_active_ring;

    integer i, b;

    /* Byte-strobed write: AXI-Lite only updates the lanes wstrb selects. The
     * old core ignored wstrb, so a byte write clobbered the whole word. */
    function [31:0] wr_bytes(input [31:0] cur, input [3:0] strb,
                             input [31:0] nv);
        integer q;
        begin
            wr_bytes = cur;
            for (q = 0; q < 4; q = q + 1)
                if (strb[q]) wr_bytes[8*q +: 8] = nv[8*q +: 8];
        end
    endfunction

    /* Register-file indices, derived combinationally from the latched address.
     * Doing this with blocking assignments inside the clocked blocks is both a
     * lint (BLKSEQ) and a synthesis smell. */
    wire [31:0] w_ring_idx = (waddr - 32'h010) >> 3;
    wire [31:0] w_size_idx = (waddr - 32'h050) >> 2;
    wire [31:0] r_ring_idx = (raddr - 32'h010) >> 3;
    wire [31:0] r_size_idx = (raddr - 32'h050) >> 2;
    wire [31:0] r_cnt_idx  = (raddr - 32'h070) >> 2;

    // ── Capture FSM ──
    localparam [1:0] S_IDLE = 2'd0, S_DATA = 2'd1, S_PUB = 2'd2;

    reg [31:0] pkt_len;          // captured bytes of the packet in flight
    reg [31:0] pkt_age;          // cycles elapsed since its first beat
    reg [63:0] pkt_ts;           // arrival stamp latched on the first beat
    reg [31:0] rec_base;         // ring offset of the record being built
    reg [C_RING_W-1:0] pkt_ring;

    wire        beat_fire = s_axis_tvalid && s_axis_tready;
    wire [3:0]  keep_cnt  = {3'b0, s_axis_tkeep[0]} + {3'b0, s_axis_tkeep[1]} +
                            {3'b0, s_axis_tkeep[2]} + {3'b0, s_axis_tkeep[3]} +
                            {3'b0, s_axis_tkeep[4]} + {3'b0, s_axis_tkeep[5]} +
                            {3'b0, s_axis_tkeep[6]} + {3'b0, s_axis_tkeep[7]};

    // Live packet record header, little-endian, 32 bytes.
    reg [255:0] hdr;
    always @(*) begin
        hdr[63:0]    = pkt_ts;              // [0x00] arrival timestamp
        hdr[95:64]   = pkt_len;             // [0x08] on-wire length
        hdr[127:96]  = pkt_len;             // [0x0C] captured length
        hdr[143:128] = r_feed_port[15:0];   // [0x10] port_id
        hdr[159:144] = 16'h0001;            // [0x12] PKT_FLAG_HW_TIMESTAMP
        hdr[175:160] = 16'h0800;            // [0x14] protocol (IPv4)
        hdr[191:176] = 16'h0;               // [0x16] _rsvd
        hdr[223:192] = pkt_age;             // [0x18] hw_latency_cycles
        hdr[255:224] = 32'h0;               // [0x1C] _rsvd2
    end

    // Status is purely combinational: no other block may drive it.
    reg [31:0] r_dma_status;
    always @(*) begin
        r_dma_status = {29'b0,
                        (r_ring_ovf != 0) || r_dma_err,   // b2 error
                        (axstate == S_DATA),              // b1 busy
                        dma_enable};                      // b0 running
    end

    // ── AXI-Lite write ──
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            wstate <= 2'd0; s_axi_awready <= 1'b0; s_axi_wready <= 1'b0;
            s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
            r_dma_ctrl <= 32'h0; r_irq_ctrl <= 32'h0;
            r_feed_port <= 32'd14317;
            for (i = 0; i < C_NUM_RINGS; i = i + 1) begin
                r_ring_base[i] <= 64'h0;
                r_ring_size[i] <= C_RING_B32;
            end
        end else begin
            case (wstate)
            2'd0: if (s_axi_awvalid) begin
                waddr <= s_axi_awaddr; s_axi_awready <= 1'b1; wstate <= 2'd1;
            end
            2'd1: begin
                s_axi_awready <= 1'b0; s_axi_wready <= 1'b1;
                if (s_axi_wvalid) begin
                    // Decode the full BAR offset. Decoding only addr[5:0]
                    // aliased real registers onto 0x00 (0x40 -> dma_ctrl), so a
                    // driver typo silently corrupted DMA control.
                    if      (waddr == 32'h000)
                        r_dma_ctrl  <= wr_bytes(r_dma_ctrl,  s_axi_wstrb, s_axi_wdata);
                    else if (waddr == 32'h008)
                        r_irq_ctrl  <= wr_bytes(r_irq_ctrl,  s_axi_wstrb, s_axi_wdata);
                    else if (waddr == 32'h0A8)
                        r_feed_port <= wr_bytes(r_feed_port, s_axi_wstrb, s_axi_wdata);
                    else if (waddr >= 32'h010 && waddr <= 32'h04F) begin
                        if (w_ring_idx < C_NUM_RINGS) begin
                            if (!waddr[2])
                                r_ring_base[w_ring_idx][31:0] <=
                                    wr_bytes(r_ring_base[w_ring_idx][31:0],
                                             s_axi_wstrb, s_axi_wdata);
                            else
                                r_ring_base[w_ring_idx][63:32] <=
                                    wr_bytes(r_ring_base[w_ring_idx][63:32],
                                             s_axi_wstrb, s_axi_wdata);
                        end
                    end
                    else if (waddr >= 32'h050 && waddr <= 32'h06F) begin
                        if (w_size_idx < C_NUM_RINGS)
                            r_ring_size[w_size_idx] <=
                                wr_bytes(r_ring_size[w_size_idx],
                                         s_axi_wstrb, s_axi_wdata);
                    end
                    wstate <= 2'd2;
                end
            end
            2'd2: begin
                s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b1;
                if (s_axi_bready) begin
                    s_axi_bvalid <= 1'b0; wstate <= 2'd0;
                end
            end
            default: wstate <= 2'd0;
            endcase
        end
    end


    // ── AXI-Lite read ──
    // Offsets mirror the canonical map in include/valkyrie.h.
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            rstate <= 2'd0; s_axi_arready <= 1'b0;
            s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'h0; s_axi_rresp <= 2'b00;
        end else begin
            case (rstate)
            2'd0: if (s_axi_arvalid) begin
                raddr <= s_axi_araddr; s_axi_arready <= 1'b1; rstate <= 2'd1;
            end
            2'd1: begin
                s_axi_arready <= 1'b0;
                if      (raddr == 32'h000) s_axi_rdata <= r_dma_ctrl;
                else if (raddr == 32'h004) s_axi_rdata <= r_dma_status;
                else if (raddr == 32'h008) s_axi_rdata <= r_irq_ctrl;
                else if (raddr == 32'h00C) s_axi_rdata <= r_irq_status;
                else if (raddr == 32'h090) s_axi_rdata <= r_bytes_written[31:0];
                else if (raddr == 32'h094) s_axi_rdata <= r_bytes_written[63:32];
                else if (raddr == 32'h0A0) s_axi_rdata <= hw_timestamp[31:0];
                else if (raddr == 32'h0A4) s_axi_rdata <= hw_timestamp[63:32];
                else if (raddr == 32'h0A8) s_axi_rdata <= r_feed_port;
                else if (raddr == 32'h0B0) s_axi_rdata <= r_lat_last;
                else if (raddr == 32'h0B4) s_axi_rdata <= r_lat_min;
                else if (raddr == 32'h0B8) s_axi_rdata <= r_lat_max;
                else if (raddr == 32'h0BC) s_axi_rdata <= r_lat_sum[31:0];
                else if (raddr == 32'h0C0) s_axi_rdata <= r_lat_sum[63:32];
                else if (raddr == 32'h0C4) s_axi_rdata <= r_lat_pkts;
                else if (raddr == 32'h0C8) s_axi_rdata <= r_ring_ovf;
                else if (raddr >= 32'h010 && raddr <= 32'h04F) begin
                    s_axi_rdata <= 32'h0;
                    if (r_ring_idx < C_NUM_RINGS)
                        s_axi_rdata <= raddr[2] ? r_ring_base[r_ring_idx][63:32]
                                                : r_ring_base[r_ring_idx][31:0];
                end
                else if (raddr >= 32'h050 && raddr <= 32'h06F)
                    s_axi_rdata <= (r_size_idx < C_NUM_RINGS)
                                 ? r_ring_size[r_size_idx] : 32'h0;
                else if (raddr >= 32'h070 && raddr <= 32'h08F)
                    s_axi_rdata <= (r_cnt_idx < C_NUM_RINGS)
                                 ? r_pkt_count[r_cnt_idx] : 32'h0;
                else s_axi_rdata <= 32'hDEADBEEF;
                s_axi_rvalid <= 1'b1; rstate <= 2'd2;
            end
            2'd2: begin
                if (s_axi_rready) begin
                    s_axi_rvalid <= 1'b0; rstate <= 2'd0;
                end
            end
            default: rstate <= 2'd0;
            endcase
        end
    end

    // ── IRQ status: set by the capture engine, cleared by W1C / soft reset ──
    // Must be its own always block: the previous design drove this register
    // from both the AXI-Lite write FSM and the stream FSM, so a W1C could be
    // silently undone (or vice versa) depending on statement order.
    wire irq_w1c     = (wstate == 2'd1) && s_axi_wvalid && (waddr == 32'h00C);
    wire pkt_publish = (axstate == S_PUB);

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) r_irq_status <= 32'h0;
        else if (r_dma_ctrl[1]) r_irq_status <= 32'h0;      // soft reset
        else begin
            if (irq_w1c) r_irq_status <= r_irq_status & ~s_axi_wdata;
            if (pkt_publish && r_irq_ctrl[0]) r_irq_status[0] <= 1'b1;
        end
    end

    // ── AXI-Stream ingress -> ring records ──
    // tready is held high for every cycle of a packet, so a conformant master
    // never has an accepted beat discarded (the old core dropped the first
    // beat of every packet while it changed state).
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn || r_dma_ctrl[1]) begin
            axstate <= S_IDLE;
            pkt_len <= 32'h0; pkt_age <= 32'h0;
            pkt_ts  <= 64'h0; rec_base <= 32'h0;
            pkt_ring <= {C_RING_W{1'b0}}; r_active_ring <= {C_RING_W{1'b0}};
            r_bytes_written <= 64'h0;
            r_ring_ovf <= 32'h0; r_dma_err <= 1'b0;
            r_lat_last <= 32'h0; r_lat_min  <= 32'h0; r_lat_max <= 32'h0;
            r_lat_sum  <= 64'h0; r_lat_pkts <= 32'h0;
            for (i = 0; i < C_NUM_RINGS; i = i + 1) begin
                r_ring_wp[i]   <= 32'h0;
                r_pkt_count[i] <= 32'h0;
            end
        end else begin
            case (axstate)
            // ── idle: the next beat opens a new record ──
            S_IDLE: begin
                if (beat_fire) begin
                    pkt_ts   <= hw_timestamp;         // wire arrival stamp
                    pkt_ring <= r_active_ring;
                    rec_base <= r_ring_wp[r_active_ring];
                    pkt_age  <= 32'd1;
                    pkt_len  <= {28'b0, keep_cnt};
                    if (s_axis_tuser) r_dma_err <= 1'b1;
                    if (C_HDR_B32 + {28'b0, keep_cnt} + r_ring_wp[r_active_ring]
                        > C_RING_B32)
                        r_ring_ovf <= r_ring_ovf + 32'd1;
                    for (b = 0; b < 8; b = b + 1)
                        if (s_axis_tkeep[b])
                            mem[r_active_ring]
                               [(r_ring_wp[r_active_ring] + C_HDR_B32 + b[31:0])
                                & C_RING_MASK] <= s_axis_tdata[b*8 +: 8];
                    axstate <= s_axis_tlast ? S_PUB : S_DATA;
                end
            end
            // ── streaming: keep accepting, count real bytes via tkeep ──
            S_DATA: begin
                pkt_age <= pkt_age + 32'd1;           // cycles since first beat
                if (beat_fire) begin
                    if (s_axis_tuser) r_dma_err <= 1'b1;
                    for (b = 0; b < 8; b = b + 1)
                        if (s_axis_tkeep[b])
                            mem[pkt_ring]
                               [(rec_base + C_HDR_B32 + pkt_len + b[31:0])
                                & C_RING_MASK] <= s_axis_tdata[b*8 +: 8];
                    pkt_len <= pkt_len + {28'b0, keep_cnt};
                    if (s_axis_tlast) axstate <= S_PUB;
                end
            end
            // ── publish: stamp the record header, advance the ring ──
            S_PUB: begin
                for (b = 0; b < C_HDR_BYTES_I; b = b + 1)
                    mem[pkt_ring][(rec_base + b[31:0]) & C_RING_MASK]
                        <= hdr[b*8 +: 8];
                r_ring_wp[pkt_ring]   <= (rec_base + C_HDR_B32 + pkt_len)
                                         & C_RING_MASK;
                r_bytes_written       <= r_bytes_written + C_HDR_B64
                                         + {32'b0, pkt_len};
                r_pkt_count[pkt_ring] <= r_pkt_count[pkt_ring] + 32'd1;
                r_lat_last            <= pkt_age;
                r_lat_sum             <= r_lat_sum + {32'b0, pkt_age};
                if (r_lat_pkts == 32'h0 || pkt_age < r_lat_min)
                    r_lat_min <= pkt_age;
                if (pkt_age > r_lat_max) r_lat_max <= pkt_age;
                r_lat_pkts            <= r_lat_pkts + 32'd1;
                r_active_ring         <= r_active_ring + 1'b1;  /* wraps */
                axstate               <= S_IDLE;
            end
            default: axstate <= S_IDLE;
            endcase
        end
    end

    // tready is combinational on purpose: a *registered* tready stayed high for
    // one extra cycle after the core left S_IDLE, so a conformant master saw a
    // beat "accepted" during the publish cycle and then lost it. Held high only
    // while the core is genuinely listening (idle or streaming), it can never
    // drop mid-packet, which is exactly the invariant the testbench monitors.
    assign s_axis_tready = dma_enable && !r_dma_ctrl[1] &&
                           (axstate == S_IDLE || axstate == S_DATA);

    // ── MSI-X vectors ──
    genvar gi;
    generate
        for (gi = 0; gi < C_MSIX_VECTORS; gi = gi + 1) begin : g_msix
            if (gi == 0) begin : g_vec0
                assign msi_irq[gi] = r_irq_status[0];
            end else if (gi == 1) begin : g_vec1
                assign msi_irq[gi] = r_irq_status[0] & r_irq_ctrl[1];
            end else begin : g_vecn
                assign msi_irq[gi] = 1'b0;
            end
        end
    endgenerate

    // ── LEDs ──
    assign led = {dma_enable, (r_ring_ovf != 0), r_irq_status[0],
                  (r_lat_pkts != 32'h0)};

endmodule
`default_nettype wire
