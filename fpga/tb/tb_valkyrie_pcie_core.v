/**
 * tb_valkyrie_pcie_core.v - Self-checking conformance suite (Icarus Verilog)
 *
 * Checks the capture core against the contract everything else depends on:
 *   - the canonical BAR0 map (include/valkyrie.h) -- driver and RTL agree
 *   - full-offset address decoding (no aliasing onto live registers)
 *   - AXI-Stream handshake conformance and lossless 64-bit capture
 *   - ring record layout (32-byte header + payload) and byte accounting
 *   - the capture-latency instrumentation user space reads back
 *
 * Run:  make -C fpga/tb            (this suite)
 *       make -C fpga/tb latency    (real PCAP -> measured capture latency)
 */
`timescale 1ns / 1ps
`default_nettype none

module tb_valkyrie_pcie_core;

    localparam CLK_HALF = 5;       // 100 MHz
    localparam RING_SZ  = 4096;    // shrink the 2 MB rings so sim stays fast

    /* ---- BAR0 offsets: mirror include/valkyrie.h exactly. The driver
     * programs rings with these numbers, so a mismatch is silent corruption.
     */
    localparam [11:0] R_DMA_CTRL   = 12'h000;
    localparam [11:0] R_DMA_STATUS = 12'h004;
    localparam [11:0] R_IRQ_CTRL   = 12'h008;
    localparam [11:0] R_IRQ_STATUS = 12'h00C;
    localparam [11:0] R_RING_BASE  = 12'h010;   // + 8*i
    localparam [11:0] R_RING_SIZE  = 12'h050;   // + 4*i
    localparam [11:0] R_PKT_COUNT  = 12'h070;   // + 4*i
    localparam [11:0] R_BYTES_WR   = 12'h090;
    localparam [11:0] R_TS_LO      = 12'h0A0;
    localparam [11:0] R_TS_HI      = 12'h0A4;
    localparam [11:0] R_FEED_PORT  = 12'h0A8;
    localparam [11:0] R_LAT_LAST   = 12'h0B0;
    localparam [11:0] R_LAT_MIN    = 12'h0B4;
    localparam [11:0] R_LAT_MAX    = 12'h0B8;
    localparam [11:0] R_LAT_SUM_LO = 12'h0BC;
    localparam [11:0] R_LAT_SUM_HI = 12'h0C0;
    localparam [11:0] R_LAT_PKTS   = 12'h0C4;
    localparam [11:0] R_RING_OVF   = 12'h0C8;
    localparam [11:0] R_UNMAPPED   = 12'h0E0;

    localparam [63:0] TS_VALUE = 64'h0123_4567_89AB_CDEF;   // driven hw_timestamp
    /* Distinct byte lanes: payload byte i of a record must equal i, which
     * catches lane swaps, byte-endianness and offset errors in one sweep. */
    localparam [63:0] BEAT0    = 64'h0706_0504_0302_0100;
    localparam [63:0] BEAT1    = 64'h0F0E_0D0C_0B0A_0908;

    /* ---- DUT I/O ---- */
    reg         aclk = 0, aresetn = 0;
    reg  [31:0] awaddr;  reg awvalid; wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid; reg bready;
    reg  [31:0] araddr;  reg arvalid; wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;
    reg  [63:0] tdata;   reg [7:0] tkeep; reg tlast; reg tvalid; wire tready;
    reg         tuser;
    wire [3:0]  msi_irq;
    reg  [63:0] hw_timestamp = TS_VALUE;
    wire [3:0]  led;

    integer errors = 0;
    integer checks = 0;
    integer g;

    valkyrie_pcie_core #(
        .C_NUM_RINGS   (4),
        .C_RING_SIZE   (RING_SZ),
        .C_MSIX_VECTORS(4)
    ) dut (
        .s_axi_aclk    (aclk),     .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (awaddr),   .s_axi_awvalid (awvalid), .s_axi_awready(awready),
        .s_axi_wdata   (wdata),    .s_axi_wstrb   (wstrb),   .s_axi_wvalid (wvalid),
        .s_axi_wready  (wready),   .s_axi_bresp   (bresp),   .s_axi_bvalid (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),   .s_axi_arvalid (arvalid), .s_axi_arready(arready),
        .s_axi_rdata   (rdata),    .s_axi_rresp   (rresp),   .s_axi_rvalid (rvalid),
        .s_axi_rready  (rready),
        .s_axis_tdata  (tdata),    .s_axis_tkeep  (tkeep),   .s_axis_tlast (tlast),
        .s_axis_tvalid (tvalid),   .s_axis_tready (tready),  .s_axis_tuser (tuser),
        .msi_irq       (msi_irq),  .hw_timestamp  (hw_timestamp),
        .led           (led)
    );

    always #CLK_HALF aclk = ~aclk;

    /* ---- Checkers ---- */
    task check32(input [255:0] name, input [31:0] got, input [31:0] exp);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %0s -> got 0x%08x expected 0x%08x", name, got, exp);
        end else begin
            $display("  [ ok ] %0s = 0x%08x", name, got);
        end
    end
    endtask

    task check64(input [255:0] name, input [63:0] got, input [63:0] exp);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %0s -> got 0x%016x expected 0x%016x", name, got, exp);
        end else begin
            $display("  [ ok ] %0s = 0x%016x", name, got);
        end
    end
    endtask

    task check8(input [255:0] name, input [7:0] got, input [7:0] exp);
    begin
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("  [FAIL] %0s -> got 0x%02x expected 0x%02x", name, got, exp);
        end else begin
            $display("  [ ok ] %0s = 0x%02x", name, got);
        end
    end
    endtask

    /* ---- AXI-Lite master ---- */
    task axi_write(input [11:0] addr, input [31:0] data);
    begin
        @(negedge aclk);
        awaddr = addr; awvalid = 1'b1; wdata = data; wstrb = 4'hF; wvalid = 1'b1;
        @(posedge aclk); g = 0;
        while (!awready && g < 100) begin @(posedge aclk); g = g + 1; end
        @(posedge aclk); g = 0;
        while (!wready && g < 100) begin @(posedge aclk); g = g + 1; end
        @(negedge aclk); awvalid = 1'b0; wvalid = 1'b0;
        @(posedge aclk); g = 0;
        while (!bvalid && g < 100) begin @(posedge aclk); g = g + 1; end
        bready = 1'b1; @(posedge aclk); @(negedge aclk); bready = 1'b0;
    end
    endtask

    task axi_read(input [11:0] addr, output [31:0] data);
    begin
        @(negedge aclk);
        araddr = addr; arvalid = 1'b1;
        @(posedge aclk); g = 0;
        while (!arready && g < 100) begin @(posedge aclk); g = g + 1; end
        @(negedge aclk); arvalid = 1'b0;
        @(posedge aclk); g = 0;
        while (!rvalid && g < 100) begin @(posedge aclk); g = g + 1; end
        data = rdata; rready = 1'b1; @(posedge aclk); @(negedge aclk); rready = 1'b0;
    end
    endtask

    /* ---- AXI-Stream master: one beat per clock, no gaps, never drops a beat.
     * Data is presented on the falling edge and accepted by the DUT on the
     * rising edge, so consecutive calls stream back-to-back. ---- */
    task send_beat(input [63:0] d, input [7:0] k, input last);
    begin
        @(negedge aclk);
        tdata = d; tkeep = k; tlast = last; tvalid = 1'b1;
        @(posedge aclk);
        while (tready !== 1'b1) @(posedge aclk);
    end
    endtask

    task end_stream;
    begin
        @(negedge aclk);
        tvalid = 1'b0; tdata = 64'h0; tkeep = 8'h0; tlast = 1'b0;
        repeat (4) @(posedge aclk);
    end
    endtask

    /* Send an n-beat packet back-to-back, so capture latency == n cycles. */
    task send_nbeats(input integer n, input [63:0] seed);
        integer j;
        begin
            for (j = 0; j < n; j = j + 1)
                send_beat(seed + j, 8'hFF, (j == (n-1)) ? 1'b1 : 1'b0);
        end
    endtask

    /* ---- Read fields back out of the ring record header ---- */
    function [31:0] hdr32(input integer ring, input integer off);
        integer k;
        begin
            hdr32 = 32'h0;
            for (k = 0; k < 4; k = k + 1)
                hdr32 = hdr32 | ({24'h0, dut.mem[ring][off + k]} << (8*k));
        end
    endfunction

    function [63:0] hdr64(input integer ring, input integer off);
        integer k;
        begin
            hdr64 = 64'h0;
            for (k = 0; k < 8; k = k + 1)
                hdr64 = hdr64 | ({56'h0, dut.mem[ring][off + k]} << (8*k));
        end
    endfunction

    reg [31:0] rd;
    integer i;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        tvalid = 0; tlast = 0; tdata = 0; tkeep = 0; tuser = 0;
        awaddr = 0; wdata = 0; wstrb = 0; araddr = 0;

        $display("=== tb_valkyrie_pcie_core: directed conformance ===");

        /* Clear the ring model so "bytes not written" are provably zero. */
        for (i = 0; i < 4; i = i + 1)
            for (g = 0; g < RING_SZ; g = g + 1)
                dut.mem[i][g] = 8'h00;

        aresetn = 1'b0; repeat (5) @(posedge aclk);
        aresetn = 1'b1; repeat (3) @(posedge aclk);

        $display("\n[1] Reset defaults: canonical BAR0 map");
        axi_read(R_DMA_CTRL,   rd); check32("dma_ctrl   @0x000", rd, 32'h0);
        axi_read(R_DMA_STATUS, rd); check32("dma_status @0x004", rd, 32'h0);
        axi_read(R_IRQ_CTRL,   rd); check32("irq_ctrl   @0x008", rd, 32'h0);
        axi_read(R_IRQ_STATUS, rd); check32("irq_status @0x00C", rd, 32'h0);
        axi_read(R_FEED_PORT,  rd); check32("feed_port  @0xA8 ", rd, 32'd14317);
        axi_read(12'h010,      rd); check32("ring_base[0] @0x10", rd, 32'h0);
        axi_read(12'h018,      rd); check32("ring_base[1] @0x18", rd, 32'h0);
        axi_read(R_TS_LO,      rd); check32("hw_timestamp lo @0xA0", rd, TS_VALUE[31:0]);
        axi_read(R_TS_HI,      rd); check32("hw_timestamp hi @0xA4", rd, TS_VALUE[63:32]);
        axi_read(R_BYTES_WR,   rd); check32("bytes_written @0x090", rd, 32'h0);
        axi_read(R_LAT_PKTS,   rd); check32("lat_pkts      @0x0C4", rd, 32'h0);
        axi_read(R_RING_OVF,   rd); check32("ring_overflow @0x0C8", rd, 32'h0);
        axi_read(R_UNMAPPED,   rd); check32("unmapped      @0x0E0", rd, 32'hDEADBEEF);
        for (i = 0; i < 4; i = i + 1) begin
            axi_read(R_RING_SIZE + 4*i, rd);
            check32("ring_size[i]   @0x050+", rd, RING_SZ);
            axi_read(R_PKT_COUNT + 4*i, rd);
            check32("packet_count[i]@0x070+", rd, 32'h0);
        end
        check32("RTL record header size", dut.C_HDR_B32, 32);

        $display("\n[2] Full-offset decode: a stray write must not hit a live reg");
        axi_write(R_DMA_CTRL, 32'h1);
        axi_read(12'h040, rd); check32("0x40 != dma_ctrl (ring_base[6])", rd, 32'h0);
        axi_read(12'h020, rd); check32("0x20 != dma_ctrl (ring_base[2])", rd, 32'h0);
        axi_read(12'h0D0, rd); check32("0x0D0 unmapped", rd, 32'hDEADBEEF);
        axi_write(12'h040, 32'hDEAD_BEEF);
        axi_read(R_DMA_CTRL,  rd); check32("dma_ctrl intact after 0x40 write", rd, 32'h1);
        axi_read(R_FEED_PORT, rd); check32("feed_port intact", rd, 32'd14317);
        axi_write(R_FEED_PORT, 32'd12345);
        axi_read(R_FEED_PORT, rd); check32("feed_port rw", rd, 32'd12345);
        axi_write(R_FEED_PORT, 32'd14317);

        $display("\n[3] 64-bit ring_base / ring_size (the driver's programming path)");
        axi_write(R_RING_BASE,        32'hDEAD_B000);
        axi_write(R_RING_BASE + 12'h4, 32'h0000_0001);
        axi_read(R_RING_BASE,          rd); check32("ring_base[0] lo", rd, 32'hDEAD_B000);
        axi_read(R_RING_BASE + 12'h4,  rd); check32("ring_base[0] hi", rd, 32'h0000_0001);
        axi_write(R_RING_SIZE, 32'd8192);
        axi_read(R_RING_SIZE,  rd); check32("ring_size[0] rw", rd, 32'd8192);
        axi_write(R_RING_SIZE, RING_SZ);
        axi_write(R_RING_BASE, 32'h0);
        axi_write(R_RING_BASE + 12'h4, 32'h0);
        axi_read(R_RING_BASE, rd); check32("ring_base[0] restored", rd, 32'h0);

        $display("\n[4] DMA-enable gating of the AXI-Stream ingress");
        axi_write(R_DMA_CTRL, 32'h0);
        repeat (3) @(posedge aclk);
        checks = checks + 1;
        if (tready !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] tready asserted while dma_ctrl=0");
        end else $display("  [ ok ] tready low while dma_ctrl=0");
        axi_write(R_DMA_CTRL, 32'h1);
        repeat (3) @(posedge aclk);
        checks = checks + 1;
        if (tready !== 1'b1) begin
            errors = errors + 1;
            $display("  [FAIL] tready not asserted after dma_ctrl=1");
        end else $display("  [ ok ] tready high after dma_ctrl=1");
        axi_read(R_DMA_STATUS, rd); check32("dma_status running", rd, 32'h1);

        $display("\n[5] Packet capture accounting (2 beats = 16 bytes)");
        send_beat(BEAT0, 8'hFF, 1'b0);
        send_beat(BEAT1, 8'hFF, 1'b1);
        end_stream();
        axi_read(R_PKT_COUNT, rd); check32("packet_count[0]", rd, 32'd1);
        axi_read(R_BYTES_WR,  rd); check32("bytes_written (32+16)", rd, 32'd48);
        axi_read(R_LAT_PKTS,  rd); check32("lat_pkts", rd, 32'd1);
        axi_read(R_LAT_LAST,  rd); check32("latency == beats (2)", rd, 32'd2);
        check32("ring0 write pointer", dut.r_ring_wp[0], 32'd48);

        $display("\n[6] Ring record layout (valkyrie_pkt_meta_t)");
        check64("record timestamp_ns == hw_timestamp", hdr64(0, 0), TS_VALUE);
        check32("record packet_length",  hdr32(0, 8),  32'd16);
        check32("record captured_length",hdr32(0, 12), 32'd16);
        check32("record port_id", (hdr32(0, 16) & 32'h0000_FFFF), 32'd14317);
        check32("record flags (HW_TS)", (hdr32(0, 16) >> 16), 32'h0001);
        check32("record protocol (IPv4)", (hdr32(0, 20) & 32'h0000_FFFF), 32'h0800);
        check32("record hw_latency_cycles", hdr32(0, 24), 32'd2);
        for (i = 0; i < 16; i = i + 1)
            check8 ("payload byte lane (must equal index)", dut.mem[0][32+i], i[7:0]);

        $display("\n[7] tkeep: a short final beat is sized by its byte lanes");
        send_beat(64'hAABB_CCDD_EEFF_0011, 8'h0F, 1'b1);
        end_stream();
        axi_read(R_PKT_COUNT, rd); check32("packet_count[1] (round robin)", rd, 32'd1);
        axi_read(R_PKT_COUNT+12'h4, rd); check32("packet_count[1] rr", rd, 32'd1);
        axi_read(R_BYTES_WR,  rd); check32("bytes_written (48+32+4)", rd, 32'd84);
        check32("ring1 captured_length == 4", hdr32(1, 12), 32'd4);
        check32("ring1 latency == 1 beat",    hdr32(1, 24), 32'd1);
        check32("ring1 write pointer", dut.r_ring_wp[1], 32'd36);
        check8 ("ring1 byte 0", dut.mem[1][32], 8'h11);
        check8 ("ring1 byte 1", dut.mem[1][33], 8'h00);
        check8 ("ring1 byte 3", dut.mem[1][35], 8'hEE);
        check8 ("ring1 byte 4 untouched (keep=0x0F)", dut.mem[1][36], 8'h00);

        $display("\n[8] MSI-X: packet-ready interrupt and W1C");
        axi_write(R_IRQ_CTRL, 32'h1);
        send_beat(64'hDEAD_BEEF_CAFE_F00D, 8'hFF, 1'b1);
        end_stream();
        axi_read(R_IRQ_STATUS, rd);
        check32("irq_status[0] set on publish", (rd & 32'h1), 32'h1);
        checks = checks + 1;
        if (msi_irq[0] !== 1'b1) begin
            errors = errors + 1;
            $display("  [FAIL] msi_irq[0] not asserted");
        end else $display("  [ ok ] msi_irq[0] asserted");
        axi_write(R_IRQ_STATUS, 32'h1);          /* W1C */
        axi_read(R_IRQ_STATUS, rd);
        check32("irq_status cleared by W1C", (rd & 32'h1), 32'h0);
        checks = checks + 1;
        if (msi_irq[0] !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] msi_irq[0] still high after W1C");
        end else $display("  [ ok ] msi_irq[0] deasserted after W1C");

        $display("\n[9] Capture latency across a mixed 1/2/4-beat stream");
        send_nbeats(1, 64'h0100_0000_0000_0000);
        send_nbeats(2, 64'h0200_0000_0000_0000);
        send_nbeats(4, 64'h0400_0000_0000_0000);
        end_stream();
        axi_read(R_LAT_PKTS,   rd); check32("lat_pkts total",        rd, 32'd6);
        axi_read(R_LAT_LAST,   rd); check32("lat_last (4 beats)",   rd, 32'd4);
        axi_read(R_LAT_MIN,    rd); check32("lat_min (1 beat)",     rd, 32'd1);
        axi_read(R_LAT_MAX,    rd); check32("lat_max (4 beats)",    rd, 32'd4);
        axi_read(R_LAT_SUM_LO, rd); check32("lat_sum (2+1+1+1+2+4)",rd, 32'd11);
        axi_read(R_LAT_SUM_HI, rd); check32("lat_sum_hi",           rd, 32'h0);
        axi_read(R_BYTES_WR,   rd); check32("bytes_written total",  rd, 32'd276);
        axi_read(R_PKT_COUNT,       rd); check32("packet_count[0]", rd, 32'd2);
        axi_read(R_PKT_COUNT+12'h4, rd); check32("packet_count[1]", rd, 32'd2);
        axi_read(R_PKT_COUNT+12'h8, rd); check32("packet_count[2]", rd, 32'd1);
        axi_read(R_PKT_COUNT+12'hC, rd); check32("packet_count[3]", rd, 32'd1);
        axi_read(R_RING_OVF,   rd); check32("no ring overflow",     rd, 32'h0);
        checks = checks + 1;
        if (mon_handshake_fail !== 0) begin
            errors = errors + 1;
            $display("  [FAIL] tready stalled %0d times mid-packet (data loss)",
                     mon_handshake_fail);
        end else $display("  [ ok ] tready never stalled mid-packet");

        $display("\n[10] Software reset clears capture state");
        axi_write(R_DMA_CTRL, 32'h2);
        repeat (3) @(posedge aclk);
        checks = checks + 1;
        if (tready !== 1'b0) begin
            errors = errors + 1;
            $display("  [FAIL] tready high during soft reset");
        end else $display("  [ ok ] tready low during soft reset");
        axi_read(R_LAT_PKTS, rd); check32("lat_pkts cleared",         rd, 32'h0);
        axi_read(R_BYTES_WR, rd); check32("bytes_written cleared",    rd, 32'h0);
        axi_read(R_PKT_COUNT,rd); check32("packet_count[0] cleared",  rd, 32'h0);
        axi_read(R_LAT_MIN,  rd); check32("lat_min cleared",          rd, 32'h0);
        check32("ring0 write pointer cleared", dut.r_ring_wp[0], 32'h0);
        axi_write(R_DMA_CTRL, 32'h1);
        repeat (3) @(posedge aclk);
        send_nbeats(1, 64'h0F00_0000_0000_0000);
        end_stream();
        axi_read(R_LAT_PKTS, rd); check32("counting resumes after reset", rd, 32'd1);
        axi_read(R_BYTES_WR, rd); check32("bytes_written after resume",   rd, 32'd40);

        $display("\n=== RESULT: %0d checks, %0d failures ===", checks, errors);
        if (errors == 0) begin
            $display("*** PASS ***");
            $finish;
        end else begin
            $display("*** FAIL (%0d) ***", errors);
            $fatal(1);        /* nonzero exit so `make test` gates CI */
        end
    end

    /* ---- Protocol monitor: tready must never stall inside a packet ----
     * That is exactly the defect the old core had (it dropped the first beat
     * of every packet while changing state), so it is checked continuously
     * rather than sampled at a few points. ---- */
    reg     mon_in_pkt = 1'b0;
    integer mon_handshake_fail = 0;

    always @(posedge aclk) begin
        if (aresetn) begin
            if (mon_in_pkt && tvalid && !tready)
                mon_handshake_fail = mon_handshake_fail + 1;
            if (tvalid && tready) mon_in_pkt <= !tlast;
        end
    end

    initial begin
        #500000;
        $display("*** TIMEOUT ***");
        $finish;
    end

endmodule
`default_nettype wire
