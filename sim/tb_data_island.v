// ============================================================================
//  tb_data_island.v -- end-to-end check of the data island
//
//  Builds the real transmitter chain (hdmi_data_island + three TMDS encoders)
//  and then does what a sink does: watch the three TMDS lanes, recognise the
//  guard band, TERC4-decode the 32-pixel body, reassemble BCH blocks 0..3 and
//  "BCH block 4" (the header), and verify:
//
//    * the island is 2 + 32*N + 2 symbols with the right guard band patterns
//    * each channel-0 guard band word is the 0xC..0xF TERC4 code for {V,H}
//    * channels 1 and 2 send the fixed 0100110011 guard band pattern
//    * the 24 header bits and the 224 subpacket bits recovered from the
//      encoded stream match what was handed to the framer
//    * every BCH block, header included, has a zero syndrome -- i.e. the
//      parity actually travels on the wire and is the right parity
//
//  The syndrome check is the important one: it is what proves the island bit
//  mapping (Figure 5-4) is right rather than merely self-consistent.
// ============================================================================
`timescale 1ns / 1ps
`default_nettype none

module tb_data_island;

    localparam MAX_PACKETS = 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst_n = 1'b0;
    reg hsync = 1'b0;
    reg vsync = 1'b0;

    reg         pkt_valid = 1'b0;
    reg  [23:0] pkt_header = 24'd0;
    reg  [223:0] pkt_body = 224'd0;
    wire [4:0]  pkt_count;
    reg         island_start = 1'b0;

    wire        island_mode;
    wire [2:0]  tmds_mode;
    wire [3:0]  ch0_data, ch1_data, ch2_data;

    wire [9:0] tmds0, tmds1, tmds2;

    hdmi_data_island #(.MAX_PACKETS(MAX_PACKETS)) u_island (
        .clk_pixel   (clk),
        .rst_n       (rst_n),
        .hsync       (hsync),
        .vsync       (vsync),
        .pkt_valid   (pkt_valid),
        .pkt_header  (pkt_header),
        .pkt_body    (pkt_body),
        .pkt_count   (pkt_count),
        .island_start(island_start),
        .island_mode (island_mode),
        .tmds_mode   (tmds_mode),
        .ch0_data    (ch0_data),
        .ch1_data    (ch1_data),
        .ch2_data    (ch2_data)
    );

    // The encoders are driven as hdmi_tx drives them: island data, and sync
    // as ch0's control input, which selects the ch0 guard band word.
    wire [1:0] ctrl_bits = {vsync, hsync};

    hdmi_tmds_encoder #(.CN(0)) u_enc0 (.clk_pixel(clk), .rst_n(rst_n),
        .mode(tmds_mode), .video_data(8'd0), .data_island_data(ch0_data),
        .control_data(ctrl_bits), .tmds(tmds0));
    hdmi_tmds_encoder #(.CN(1)) u_enc1 (.clk_pixel(clk), .rst_n(rst_n),
        .mode(tmds_mode), .video_data(8'd0), .data_island_data(ch1_data),
        .control_data(2'b00), .tmds(tmds1));
    hdmi_tmds_encoder #(.CN(2)) u_enc2 (.clk_pixel(clk), .rst_n(rst_n),
        .mode(tmds_mode), .video_data(8'd0), .data_island_data(ch2_data),
        .control_data(2'b00), .tmds(tmds2));

    // -----------------------------------------------------------------------
    // Sink-side model
    // -----------------------------------------------------------------------
    integer checks = 0;
    integer errors = 0;

    task check;
        input        cond;
        input [300:0] name;
        begin
            checks = checks + 1;
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL @%0t: %0s", $time, name);
            end
        end
    endtask

    `include "sim/include/hdmi_ref.vh"

    // TERC4 value, x when the symbol is not a TERC4 code.
    function [3:0] terc4_decode;
        input [9:0] s;
        reg   [4:0] v;
        begin
            v = terc4_dec(s);
            terc4_decode = v[4] ? v[3:0] : 4'hx;
        end
    endfunction

    reg [1023:0] nm;

    // Capture the island off the encoder outputs.
    reg [9:0] cap0 [0:255];
    reg [9:0] cap1 [0:255];
    reg [9:0] cap2 [0:255];
    integer   ncap;
    integer   watching;
    integer   body_seen;
    integer   lead_seen;
    integer   trail_seen;
    integer   done_waiting;

    // Assembled blocks for the packet currently being checked.
    reg [63:0] blk [0:3];
    reg [31:0] hblk;
    reg [23:0] got_header;
    reg [223:0] got_body;

    // -----------------------------------------------------------------------
    // Drive one packet into a slot.
    // -----------------------------------------------------------------------
    task send_packet;
        input [23:0]  hdr;
        input [223:0] bdy;
        begin
            @(negedge clk);
            pkt_valid  = 1'b1;
            pkt_header = hdr;
            pkt_body   = bdy;
            @(negedge clk);
            pkt_valid  = 1'b0;
            pkt_header = 24'd0;
            pkt_body   = 224'd0;
        end
    endtask

    // Expected values for the island currently in flight.
    reg [23:0] exp_header [0:MAX_PACKETS-1];
    reg [223:0] exp_body  [0:MAX_PACKETS-1];
    integer    n_pkt;

    // Build a distinguishable 56-byte subpacket: byte i = i*16 + slot*4 + byte.
    function [55:0] mk_sub;
        input integer slot;
        input integer byte;
        integer i;
        reg [7:0] b;
        begin
            b = (slot * 64) + (byte * 4) + 7;
            for (i = 0; i < 7; i = i + 1) begin
                mk_sub[i*8 +: 8] = b + i;
                b = b + 1;
            end
        end
    endfunction

    // -----------------------------------------------------------------------
    // Monitor: recognise the island and decode it.
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            watching    = 0;
            ncap        = 0;
            body_seen   = 0;
            lead_seen   = 0;
            trail_seen  = 0;
        end else begin
            if (island_mode && !watching) begin
                watching = 1;
                ncap     = 0;
                lead_seen = 0; body_seen = 0; trail_seen = 0;
            end

            if (watching) begin
                if (island_mode) begin
                    if (ncap < 256) begin
                        cap0[ncap] = tmds0;
                        cap1[ncap] = tmds1;
                        cap2[ncap] = tmds2;
                        ncap = ncap + 1;
                    end
                end else begin
                    watching = 0;
                end
            end
        end
    end

    // -----------------------------------------------------------------------
    // Verification, run once the island has been captured.
    // -----------------------------------------------------------------------
    task verify_island;
        integer np, expect_len, pix, i, slot, b;
        reg [3:0] d0, d1, d2;
        reg [7:0] syn;
        begin
            np         = n_pkt;
            expect_len = 4 + 32 * np;

            check(ncap == expect_len, "island length");
            $display("  island: %0d packets, %0d symbols captured (expected %0d)",
                     np, ncap, expect_len);

            // ---- guard bands -------------------------------------------
            // Leading 2 and trailing 2 symbols.
            for (i = 0; i < 2; i = i + 1) begin
                nm = "leading guard band ch0 is a 0xC..0xF TERC4 word";
                check((terc4_decode(cap0[i]) >= 4'hc), nm);
                nm = "leading guard band ch0 matches {V,H}";
                check(cap0[i] == dgb_code({vsync, hsync}), nm);
                nm = "leading guard band ch1 fixed pattern";
                check(cap1[i] == 10'b0100110011, nm);
                nm = "leading guard band ch2 fixed pattern";
                check(cap2[i] == 10'b0100110011, nm);
            end
            for (i = 0; i < 2; i = i + 1) begin
                nm = "trailing guard band ch0 matches {V,H}";
                check(cap0[expect_len-2+i] == dgb_code({vsync, hsync}), nm);
                nm = "trailing guard band ch1 fixed pattern";
                check(cap1[expect_len-2+i] == 10'b0100110011, nm);
                nm = "trailing guard band ch2 fixed pattern";
                check(cap2[expect_len-2+i] == 10'b0100110011, nm);
            end

            // ---- body -------------------------------------------------
            for (np = 0; np < n_pkt; np = np + 1) begin
                hblk = 32'd0;
                for (b = 0; b < 4; b = b + 1) blk[b] = 64'd0;

                for (i = 0; i < 32; i = i + 1) begin
                    pix = 2 + 32 * np + i;
                    d0 = terc4_decode(cap0[pix]);
                    d1 = terc4_decode(cap1[pix]);
                    d2 = terc4_decode(cap2[pix]);

                    nm = "ch0 D2 decodes during island body";
                    check(d0 !== 4'hx, nm);

                    // Figure 5-3 island framing bit: 0 only on the first
                    // body character of the island.
                    nm = "ch0 D3 island framing bit";
                    check(d0[3] === ((np != 0) || (i != 0)), nm);

                    // BCH block 4: header bits then header parity, on ch0 D2.
                    hblk[i] = d0[2];

                    // BCH block k: even bits on ch1 Dk, odd bits on ch2 Dk.
                    for (b = 0; b < 4; b = b + 1) begin
                        blk[b][2*i]   = d1[b];
                        blk[b][2*i+1] = d2[b];
                    end
                end

                // ---- header -----------------------------------------
                nm = "header BCH block has zero syndrome";
                check(bch(hblk, 32) == 8'd0, nm);
                got_header = hblk[23:0];
                nm = "header bytes recovered correctly";
                check(got_header == exp_header[np], nm);
                if (got_header !== exp_header[np])
                    $display("     got %06x expected %06x", got_header, exp_header[np]);

                // ---- subpackets -------------------------------------
                for (b = 0; b < 4; b = b + 1) begin
                    nm = "subpacket BCH block has zero syndrome";
                    check(bch(blk[b], 64) == 8'd0, nm);
                    got_body[56*b +: 56] = blk[b][55:0];
                    nm = "subpacket payload";
                    check(got_body[56*b +: 56] == exp_body[np][56*b +: 56], nm);
                end
            end
        end
    endtask

    // The channel 0 guard band symbol for a given {V,H} control pair.
    function [9:0] dgb_code;
        input [1:0] vh;
        begin
            case (vh)
                2'b00:   dgb_code = 10'b1010001110;
                2'b01:   dgb_code = 10'b1001110001;
                2'b10:   dgb_code = 10'b0101100011;
                default: dgb_code = 10'b1011000011;
            endcase
        end
    endfunction

    // -----------------------------------------------------------------------
    // Main sequence
    // -----------------------------------------------------------------------
    integer trial;
    integer np;
    integer p;
    reg [23:0] h;

    initial begin
        hsync = 1'b0;
        vsync = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        for (trial = 0; trial < 4; trial = trial + 1) begin
            // Vary both the packet count and the sync level so the channel 0
            // guard band word is exercised across all four values.
            case (trial)
                0: begin np = 1; hsync = 1'b0; vsync = 1'b0; end
                1: begin np = 2; hsync = 1'b1; vsync = 1'b0; end
                2: begin np = 3; hsync = 1'b1; vsync = 1'b1; end
                default: begin np = 3; hsync = 1'b0; vsync = 1'b1; end
            endcase

            n_pkt = np;
            for (p = 0; p < np; p = p + 1) begin
                h = 24'h0000 | (p * 24'h010203);
                exp_header[p] = h;
                exp_body[p] = {mk_sub(p * 4 + 3, 0), mk_sub(p * 4 + 2, 0),
                               mk_sub(p * 4 + 1, 0), mk_sub(p * 4 + 0, 0)};
                send_packet(h, exp_body[p]);
            end

            check(pkt_count == np, "pkt_count matches packets latched");

            @(negedge clk);
            island_start = 1'b1;
            @(negedge clk);
            island_start = 1'b0;

            // Let the island run out.
            wait (island_mode == 1'b1);
            wait (island_mode == 1'b0);
            @(posedge clk);

            $display("  trial %0d: %0d packets, sync={V,H}=%b%b",
                     trial, np, vsync, hsync);
            verify_island;
        end

        $display("");
        if (errors == 0)
            $display("tb_data_island: PASS (%0d checks)", checks);
        else
            $display("tb_data_island: FAIL (%0d of %0d checks failed)",
                     errors, checks);
        if (errors != 0) $finish(1);
        $finish;
    end

    // Safety net.
    initial begin
        #200000;
        $display("tb_data_island: FAIL (timeout)");
        $finish(1);
    end

endmodule

`default_nettype wire
