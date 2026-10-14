/**
 * tb_pcap_replay.v - Replay real market data (PCAP -> AXI-Stream) into the RTL.
 *
 * Stimulus comes from fpga/tb/pcap2axis.py:
 *     python3 pcap2axis.py pcap_data/db-samples.pcap stim.axis 2000
 *     cd fpga/tb && iverilog -g2012 -o replay.vvp tb_pcap_replay.v ../rtl/valkyrie_pcie_core.v
 *     vvp replay.vvp +axis=stim.axis
 *
 * What it checks against real market data:
 *   - no accepted beat is ever dropped (tready never stalls inside a packet)
 *   - every captured byte is accounted for, record header included
 *   - each ring holds a well-formed record stream (32-byte headers)
 *
 * A conformant AXI-Stream master advances only when tready is asserted.
 * Backpressure *between* packets is legal and counted separately; backpressure
 * *inside* a packet means the core lost data and fails the run. Exits nonzero
 * on any non-conformance so `make rtl-replay` gates CI.
 */
`timescale 1ns / 1ps
`default_nettype none

module tb_pcap_replay;

    localparam CLK_HALF = 5;
    localparam RING_SZ  = 1 << 19;     // 512 KB per ring: holds the stimulus
    localparam HDR      = 32;          // record header bytes (valkyrie_pkt_meta_t)
    localparam WAIT_MAX = 64;          // legal backpressure bound between packets

    /* ---- BAR0 offsets: mirror include/valkyrie.h ---- */
    localparam [11:0] R_DMA_CTRL  = 12'h000;
    localparam [11:0] R_PKT_COUNT = 12'h070;   // + 4*i
    localparam [11:0] R_BYTES_WR  = 12'h090;
    localparam [11:0] R_LAT_PKTS  = 12'h0C4;
    localparam [11:0] R_RING_OVF  = 12'h0C8;

    reg         aclk = 0, aresetn = 0;
    reg  [31:0] awaddr;  reg awvalid; wire awready;
    reg  [31:0] wdata;   reg [3:0] wstrb; reg wvalid; wire wready;
    wire [1:0]  bresp;   wire bvalid; reg bready;
    reg  [31:0] araddr;  reg arvalid; wire arready;
    wire [31:0] rdata;   wire [1:0] rresp; wire rvalid; reg rready;
    reg  [63:0] tdata;   reg [7:0] tkeep; reg tlast; reg tvalid; wire tready;
    reg         tuser;
    wire [3:0]  msi_irq;
    reg  [63:0] hw_timestamp = 64'h0;
    wire [3:0]  led;

    valkyrie_pcie_core #(.C_NUM_RINGS(4), .C_RING_SIZE(RING_SZ), .C_MSIX_VECTORS(4)) dut (
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(tdata), .s_axis_tkeep(tkeep), .s_axis_tlast(tlast),
        .s_axis_tvalid(tvalid), .s_axis_tready(tready), .s_axis_tuser(tuser),
        .msi_irq(msi_irq), .hw_timestamp(hw_timestamp), .led(led)
    );

    always #CLK_HALF aclk = ~aclk;

    /* Model of the MAC's free-running nanosecond clock: the core must latch
     * this value as the packet arrives, and user space diffs it against
     * CLOCK_MONOTONIC to get wire-to-strategy latency. */
    always @(posedge aclk) hw_timestamp <= hw_timestamp + 64'd1;

    integer g;
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

    /* Read a little-endian field out of a ring record header. */
    function [31:0] hdr32(input integer ring, input integer off);
        integer k;
        begin
            hdr32 = 32'h0;
            for (k = 0; k < 4; k = k + 1)
                hdr32 = hdr32 | ({24'h0, dut.mem[ring][off + k]} << (8*k));
        end
    endfunction

    reg [63:0] td; reg [7:0] tk; reg tl;
    reg [1023:0] path;
    reg [31:0] rd, rd_hi;
    integer fd, code, w, k, j, r;
    integer beats_in, beats_accepted, stalls_mid, stalls_back;
    integer pkts_in, bytes_in, pkt_bytes, in_pkt, prev_last;
    integer ring_bytes[0:3], ring_recs[0:3];
    integer off, recs, sumcap, cap, nxt, tot_cap, tot_recs;
    integer errors, bad;
    reg [63:0] bytes_written;
    reg [63:0] cks;
    reg [63:0] ring_cks[0:3];        // checksum of the stimulus, per ring
    reg [31:0] lat_pkts, ovf;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        tvalid = 0; tlast = 0; tdata = 0; tkeep = 0; tuser = 0;
        awaddr = 0; wdata = 0; wstrb = 0; araddr = 0;
        beats_in = 0; beats_accepted = 0; stalls_mid = 0; stalls_back = 0;
        pkts_in = 0; bytes_in = 0; pkt_bytes = 0; prev_last = 1;
        errors = 0;
        for (r = 0; r < 4; r = r + 1) begin
            ring_bytes[r] = 0; ring_recs[r] = 0; ring_cks[r] = 64'h0;
        end
        path = "stim.axis";

        if (!$value$plusargs("axis=%s", path)) $display("[replay] using default stim.axis");
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("[replay] cannot open %0s", path); $finish; end

        $display("\n=== tb_pcap_replay: %0s ===", path);
        aresetn = 1'b0; repeat (5) @(posedge aclk); aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        axi_write(R_DMA_CTRL, 32'h1);            /* enable DMA */
        repeat (2) @(posedge aclk);

        code = $fscanf(fd, "%h %h %b\n", td, tk, tl);
        while (code == 3) begin
            @(negedge aclk);
            tdata = td; tkeep = tk; tlast = tl; tvalid = 1'b1;
            beats_in = beats_in + 1;
            in_pkt   = !prev_last;               // stall here is inside a packet?
            for (k = 0; k < 8; k = k + 1) begin
                if (tk[k]) begin
                    bytes_in  = bytes_in + 1;
                    pkt_bytes = pkt_bytes + 1;
                    /* packet index -> the ring it will land in (round robin) */
                    ring_cks[pkts_in % 4] = ring_cks[pkts_in % 4]
                                          + {56'h0, td[8*k +: 8]};
                end
            end

            @(posedge aclk); w = 0;
            while (tready !== 1'b1 && w < WAIT_MAX) begin @(posedge aclk); w = w + 1; end
            if (tready === 1'b1) begin
                beats_accepted = beats_accepted + 1;
                if (w != 0) begin
                    if (in_pkt) begin
                        stalls_mid = stalls_mid + 1;
                        if (stalls_mid == 1)
                            $display("[replay] STALL INSIDE PACKET at beat %0d: core dropped a beat",
                                     beats_in);
                    end else stalls_back = stalls_back + 1;   /* legal backpressure */
                end
            end else begin
                stalls_mid = stalls_mid + 1;
                $display("[replay] DEADLOCK at beat %0d: tready low for %0d cycles",
                         beats_in, WAIT_MAX);
                while (tready !== 1'b1) @(posedge aclk);
            end
            prev_last = tl;

            if (tl) begin
                ring_bytes[pkts_in % 4] = ring_bytes[pkts_in % 4] + pkt_bytes;
                ring_recs [pkts_in % 4] = ring_recs [pkts_in % 4] + 1;
                pkts_in   = pkts_in + 1;
                pkt_bytes = 0;
            end
            code = $fscanf(fd, "%h %h %b\n", td, tk, tl);
        end
        $fclose(fd);
        @(negedge aclk); tvalid = 1'b0;
        repeat (8) @(posedge aclk);

        /* ---- read back the DUT's own accounting ---- */
        axi_read(R_BYTES_WR, rd);
        axi_read(R_BYTES_WR + 12'h4, rd_hi);
        bytes_written = {rd_hi, rd};
        axi_read(R_LAT_PKTS, lat_pkts);
        axi_read(R_RING_OVF, ovf);

        /* ---- walk every ring and verify the record stream ---- */
        tot_cap = 0; tot_recs = 0; bad = 0;
        for (r = 0; r < 4; r = r + 1) begin
            off = 0; recs = 0; sumcap = 0; cks = 64'h0;
            axi_read(R_PKT_COUNT + 4*r, rd);
            if (rd !== ring_recs[r]) begin
                errors = errors + 1;
                $display("  [FAIL] ring %0d packet_count reg=%0d expected %0d",
                         r, rd, ring_recs[r]);
            end
            while (off < dut.r_ring_wp[r]) begin
                if (off + HDR > RING_SZ) begin
                    bad = bad + 1; off = RING_SZ;
                end else begin
                    cap = hdr32(r, off + 12);
                    if (cap > (RING_SZ - HDR)) bad = bad + 1;
                    if ((hdr32(r, off + 16) >> 16) !== 32'h1) bad = bad + 1;
                    if (hdr32(r, off + 24) === 32'h0)         bad = bad + 1;
                    for (j = 0; j < cap; j = j + 1)
                        cks = cks + {56'h0, dut.mem[r][off + HDR + j]};
                    sumcap = sumcap + cap;
                    recs = recs + 1;
                    nxt = HDR + cap;
                    if (nxt < HDR) nxt = HDR;
                    off = off + nxt;
                end
            end
            if (sumcap !== ring_bytes[r]) begin
                errors = errors + 1;
                $display("  [FAIL] ring %0d payload bytes: walked %0d expected %0d",
                         r, sumcap, ring_bytes[r]);
            end
            if (recs !== ring_recs[r]) begin
                errors = errors + 1;
                $display("  [FAIL] ring %0d records: walked %0d expected %0d",
                         r, recs, ring_recs[r]);
            end
            if (cks !== ring_cks[r]) begin
                errors = errors + 1;
                $display("  [FAIL] ring %0d payload checksum 0x%016x != stimulus 0x%016x",
                         r, cks, ring_cks[r]);
            end
            tot_cap  = tot_cap + sumcap;
            tot_recs = tot_recs + recs;
        end

        $display("\n--- replay report ---");
        $display("  beats in file       : %0d", beats_in);
        $display("  beats accepted      : %0d", beats_accepted);
        $display("  backpressure cycles : %0d  (legal, between packets)", stalls_back);
        $display("  stalls inside packet: %0d  (must be 0)", stalls_mid);
        $display("  packets in file     : %0d", pkts_in);
        $display("  payload bytes       : %0d", bytes_in);
        $display("  records walked      : %0d", tot_recs);
        $display("  payload bytes in ring: %0d  (%0s)",
                 tot_cap, (tot_cap === bytes_in) ? "byte-for-byte accounted" : "MISMATCH");
        $display("  bytes_written reg   : %0d  (expected %0d = payload + %0d hdr x %0d pkts)",
                 bytes_written, bytes_in + HDR*pkts_in, HDR, pkts_in);
        $display("  lat_pkts reg        : %0d", lat_pkts);
        $display("  ring_overflows      : %0d", ovf);
        $display("  malformed records   : %0d", bad);

        if (tot_recs !== pkts_in) begin
            errors = errors + 1;
            $display("  [FAIL] record count %0d != packets %0d", tot_recs, pkts_in);
        end
        if (tot_cap !== bytes_in) begin
            errors = errors + 1;
            $display("  [FAIL] captured bytes lost or duplicated");
        end
        if (bytes_written !== (bytes_in + HDR*pkts_in)) begin
            errors = errors + 1;
            $display("  [FAIL] bytes_written register disagrees with the ring");
        end
        if (lat_pkts !== pkts_in) begin
            errors = errors + 1;
            $display("  [FAIL] latency samples %0d != packets %0d", lat_pkts, pkts_in);
        end
        if (beats_accepted !== beats_in) begin
            errors = errors + 1;
            $display("  [FAIL] accepted %0d of %0d beats", beats_accepted, beats_in);
        end
        if (bad != 0) begin
            errors = errors + 1;
            $display("  [FAIL] %0d malformed record headers", bad);
        end
        if (stalls_mid != 0) begin
            errors = errors + 1;
            $display("  [FAIL] %0d stalls inside a packet => data loss", stalls_mid);
        end

        if (errors != 0) begin
            $display("\n*** NON-CONFORMANT: capture path loses/truncates market data ***");
            $fatal(1);        /* nonzero exit so `make rtl-replay` gates CI */
        end
        $display("\n*** CONFORMANT ***");
        $finish;
    end

    initial begin
        #5000000;
        $display("*** TIMEOUT ***");
        $finish;
    end

endmodule
`default_nettype wire
