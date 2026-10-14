/**
 * tb_capture_latency.v - Measure the capture path's latency on real market data.
 *
 * "Latency" here is the FPGA's ingress -> ring-publish delay: from the first
 * byte of a frame being accepted on the AXI-Stream to the completed record
 * being visible to the host, expressed in core clock cycles. User space turns
 * it into nanoseconds with the core frequency and adds
 * (CLOCK_MONOTONIC - timestamp_ns) for true wire-to-strategy latency.
 *
 * The test drives hw_timestamp as a free-running 10 ns/cycle clock (the MAC's
 * wire clock) and then walks the captured records to verify, per packet:
 *   - the stamped timestamp_ns is exactly the wire time at the frame's SOF
 *     (so latency is anchored to arrival, not fabricated)
 *   - captured_length matches the stimulus byte count
 *   - hw_latency_cycles matches the frame's own beat count exactly
 * ...and that the BAR0 aggregate registers (what the driver's
 * VALKYRIE_IOCTL_GET_LATENCY returns) agree with that per-record data.
 *
 * Exits nonzero if any packet is mis-stamped or the p99 budget is exceeded.
 *
 *   python3 pcap2axis.py pcap_data/db-samples.pcap stim.axis 2000
 *   vvp latency.vvp +axis=stim.axis [+budget=<cycles>]
 */
`timescale 1ns / 1ps
`default_nettype none

module tb_capture_latency;

    localparam CLK_HALF = 5;           // 100 MHz sim clock
    localparam NS_PER_CYCLE = 10;      // modelled wire clock step
    localparam CORE_HZ = 250_000_000;  // core clock the user space assumes
    localparam RING_SZ = 1 << 19;      // 512 KB per ring: holds the stimulus
    localparam HDR = 32;               // record header bytes
    localparam MAXPKT = 4096;          // packets we can remember
    localparam MAXLAT = 8192;          // latency histogram depth (cycles)

    localparam [11:0] R_DMA_CTRL  = 12'h000;
    localparam [11:0] R_PKT_COUNT = 12'h070;
    localparam [11:0] R_LAT_LAST  = 12'h0B0;
    localparam [11:0] R_LAT_MIN   = 12'h0B4;
    localparam [11:0] R_LAT_MAX   = 12'h0B8;
    localparam [11:0] R_LAT_SUM_LO= 12'h0BC;
    localparam [11:0] R_LAT_SUM_HI= 12'h0C0;
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
    /* The MAC's wire clock: free-running, ns resolution (10 ns per cycle). */
    always @(posedge aclk) hw_timestamp <= hw_timestamp + NS_PER_CYCLE;

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

    localparam [31:0] NS_PER_CORE_CYCLE = 1000000000 / CORE_HZ;

    reg [63:0] td; reg [7:0] tk; reg tl;
    reg [1023:0] path;
    reg [31:0] rd, rd_hi;
    integer fd, code, w, k, j, r, off, lat;
    integer beats_in, beats_accepted, pkts_in, bytes_in, pkt_beats, pkt_bytes, prev_last;
    integer errors, bad, mism_ts, mism_cap, mism_lat;
    integer budget, p50, p99, cum, thresh;
    integer lat_min, lat_max, lat_total;
    integer ring_off[0:3];
    integer hist[0:MAXLAT-1];
    reg [63:0] exp_ts[0:MAXPKT-1];       // wire time at each packet's SOF
    integer  exp_beats[0:MAXPKT-1];
    integer  exp_bytes[0:MAXPKT-1];
    reg [63:0] lat_sum;
    reg [31:0] lat_pkts_reg, ovf, lat_last_reg, lat_min_reg, lat_max_reg;

    initial begin
        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        tvalid = 0; tlast = 0; tdata = 0; tkeep = 0; tuser = 0;
        awaddr = 0; wdata = 0; wstrb = 0; araddr = 0;
        beats_in = 0; beats_accepted = 0; pkts_in = 0; bytes_in = 0;
        pkt_beats = 0; pkt_bytes = 0; prev_last = 1;
        errors = 0; bad = 0;
        budget = 512;    /* default p99 budget: 512 cycles = 2048 ns @250 MHz */

        if (!$value$plusargs("budget=%d", budget))
            $display("[lat] using default p99 budget = %0d cycles", budget);
        path = "stim.axis";
        if (!$value$plusargs("axis=%s", path)) $display("[lat] using default stim.axis");
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("[lat] cannot open %0s", path); $finish; end

        $display("\n=== tb_capture_latency: %0s ===", path);
        aresetn = 1'b0; repeat (5) @(posedge aclk); aresetn = 1'b1;
        repeat (2) @(posedge aclk);
        for (r = 0; r < 4; r = r + 1) ring_off[r] = 0;
        for (k = 0; k < MAXLAT; k = k + 1) hist[k] = 0;

        axi_write(R_DMA_CTRL, 32'h1);           /* enable capture */
        repeat (2) @(posedge aclk);

        code = $fscanf(fd, "%h %h %b\n", td, tk, tl);
        while (code == 3) begin
            @(negedge aclk);
            tdata = td; tkeep = tk; tlast = tl; tvalid = 1'b1;
            beats_in  = beats_in + 1;
            pkt_beats = pkt_beats + 1;
            for (k = 0; k < 8; k = k + 1)
                if (tk[k]) begin
                    bytes_in  = bytes_in + 1;
                    pkt_bytes = pkt_bytes + 1;
                end

            @(posedge aclk); w = 0;
            while (tready !== 1'b1 && w < 64) begin @(posedge aclk); w = w + 1; end
            if (tready !== 1'b1) begin
                $display("[lat] DEADLOCK at beat %0d", beats_in);
                while (tready !== 1'b1) @(posedge aclk);
            end
            beats_accepted = beats_accepted + 1;

            /* First beat of a packet: the core latched hw_timestamp on this
             * very edge, so the value still visible here is the anchor the
             * record must carry. */
            if (prev_last) begin
                if (pkts_in < MAXPKT) exp_ts[pkts_in] = hw_timestamp;
                else begin
                    errors = errors + 1;
                    $display("[lat] more than MAXPKT=%0d packets", MAXPKT);
                end
            end
            prev_last = tl;

            if (tl) begin
                if (pkts_in < MAXPKT) begin
                    exp_beats[pkts_in] = pkt_beats;
                    exp_bytes[pkts_in] = pkt_bytes;
                end
                pkts_in   = pkts_in + 1;
                pkt_beats = 0;
                pkt_bytes = 0;
            end
            code = $fscanf(fd, "%h %h %b\n", td, tk, tl);
        end
        $fclose(fd);
        @(negedge aclk); tvalid = 1'b0;
        repeat (8) @(posedge aclk);

        /* ---- BAR0 aggregates: exactly what VALKYRIE_IOCTL_GET_LATENCY returns ---- */
        axi_read(R_LAT_PKTS,   lat_pkts_reg);
        axi_read(R_LAT_LAST,   lat_last_reg);
        axi_read(R_LAT_MIN,    lat_min_reg);
        axi_read(R_LAT_MAX,    lat_max_reg);
        axi_read(R_LAT_SUM_LO, rd);
        axi_read(R_LAT_SUM_HI, rd_hi);
        lat_sum = {rd_hi, rd};
        axi_read(R_RING_OVF,   ovf);
        axi_read(R_PKT_COUNT,  rd);

        /* ---- verify every record against the wire-truth we recorded ---- */
        mism_ts = 0; mism_cap = 0; mism_lat = 0;
        lat_min = 0; lat_max = 0; lat_total = 0;
        for (k = 0; k < pkts_in && k < MAXPKT; k = k + 1) begin
            r   = k % 4;
            off = ring_off[r];
            ring_off[r] = off + HDR + exp_bytes[k];

            if (hdr64(r, off) !== exp_ts[k]) begin
                mism_ts = mism_ts + 1;
                if (mism_ts == 1)
                    $display("  [FAIL] packet %0d stamped 0x%016x, wire time was 0x%016x",
                             k, hdr64(r, off), exp_ts[k]);
            end
            if (hdr32(r, off + 12) !== exp_bytes[k]) begin
                mism_cap = mism_cap + 1;
                if (mism_cap == 1)
                    $display("  [FAIL] packet %0d captured %0d bytes, stimulus had %0d",
                             k, hdr32(r, off + 12), exp_bytes[k]);
            end
            lat = hdr32(r, off + 24);
            if (lat !== exp_beats[k]) begin
                mism_lat = mism_lat + 1;
                if (mism_lat == 1)
                    $display("  [FAIL] packet %0d latency %0d cycles, %0d beats streamed",
                             k, lat, exp_beats[k]);
            end
            if (k == 0 || lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;
            lat_total = lat_total + lat;
            if (lat < MAXLAT) hist[lat] = hist[lat] + 1;
            else              hist[MAXLAT-1] = hist[MAXLAT-1] + 1;
        end

        /* ---- percentiles: smallest latency covering the given share ---- */
        p50 = 0; p99 = 0; cum = 0;
        thresh = (pkts_in + 1) / 2;
        for (lat = 0; lat < MAXLAT; lat = lat + 1) begin
            cum = cum + hist[lat];
            if (p50 == 0 && cum >= thresh)              p50 = lat;
            if (p99 == 0 && cum >= ((pkts_in*99)+99)/100) p99 = lat;
        end

        $display("\n--- capture latency: ingress -> ring publish ---");
        $display("  packets            : %0d", pkts_in);
        $display("  payload bytes      : %0d", bytes_in);
        $display("  beats accepted     : %0d of %0d", beats_accepted, beats_in);
        $display("  core clock (model) : %0.0f MHz, %0d ns/cycle",
                 250.0, NS_PER_CORE_CYCLE);
        $display("  latency [cycles]   : min %0d  p50 %0d  p99 %0d  max %0d",
                 lat_min, p50, p99, lat_max);
        $display("  latency [ns]       : min %0d  p50 %0d  p99 %0d  max %0d",
                 lat_min*NS_PER_CORE_CYCLE, p50*NS_PER_CORE_CYCLE,
                 p99*NS_PER_CORE_CYCLE, lat_max*NS_PER_CORE_CYCLE);
        $display("  p99 budget [cycles]: %0d", budget);
        $display("  ring overflows     : %0d", ovf);
        $display("  BAR0 lat regs      : last %0d  min %0d  max %0d  pkts %0d  sum %0d",
                 lat_last_reg, lat_min_reg, lat_max_reg, lat_pkts_reg, lat_sum);
        $display("  mis-stamped        : %0d", mism_ts);
        $display("  mis-sized          : %0d", mism_cap);
        $display("  latency mismatches : %0d", mism_lat);

        if (ovf != 0) begin
            errors = errors + 1;
            $display("  [FAIL] records wrapped (%0d overflows): the walk is not valid", ovf);
        end
        if (mism_ts != 0) begin
            errors = errors + 1;
            $display("  [FAIL] %0d records carry the wrong arrival timestamp", mism_ts);
        end
        if (mism_cap != 0) begin
            errors = errors + 1;
            $display("  [FAIL] %0d records have the wrong captured length", mism_cap);
        end
        if (mism_lat != 0) begin
            errors = errors + 1;
            $display("  [FAIL] %0d records disagree with the measured cycle latency", mism_lat);
        end
        if (lat_pkts_reg !== pkts_in) begin
            errors = errors + 1;
            $display("  [FAIL] BAR0 lat_pkts=%0d, captured %0d", lat_pkts_reg, pkts_in);
        end
        if (lat_last_reg !== exp_beats[pkts_in-1]) begin
            errors = errors + 1;
            $display("  [FAIL] BAR0 lat_last=%0d, last packet had %0d beats",
                     lat_last_reg, exp_beats[pkts_in-1]);
        end
        if (lat_min_reg !== lat_min || lat_max_reg !== lat_max) begin
            errors = errors + 1;
            $display("  [FAIL] BAR0 min/max %0d/%0d != walked %0d/%0d",
                     lat_min_reg, lat_max_reg, lat_min, lat_max);
        end
        if (lat_sum !== lat_total) begin
            errors = errors + 1;
            $display("  [FAIL] BAR0 sum %0d != walked sum %0d", lat_sum, lat_total);
        end
        if (p99 > budget) begin
            errors = errors + 1;
            $display("  [FAIL] p99 %0d cycles exceeds the %0d-cycle budget", p99, budget);
        end

        if (errors != 0) begin
            $display("\n*** LATENCY TEST FAILED (%0d) ***", errors);
            $fatal(1);       /* nonzero exit so `make rtl-latency` gates CI */
        end
        $display("\n*** LATENCY TEST PASSED: every frame stamped at arrival, p99 %0d cycles (%0d ns) ***",
                 p99, p99*NS_PER_CORE_CYCLE);
        $finish;
    end

    initial begin
        #5000000;
        $display("*** TIMEOUT ***");
        $finish;
    end

endmodule
`default_nettype wire
