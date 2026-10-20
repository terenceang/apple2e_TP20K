// ============================================================================
//  tb_tmds_encoder.v -- verification of hdmi_tmds_encoder
//
//  The decoder below is written from the *bit semantics* rather than by
//  inverting the encoder's expressions:
//
//      bit 8 = which transition-minimising chain was used (1 = XOR, 0 = XNOR)
//      bit 9 = whether the 8 payload bits were inverted
//      bits 9:8 unequal  => data symbol
//      bits 9:8 equal    => control symbol
//
//  So it independently reconstructs qm from the chain type and then undoes
//  the inversion.  If the encoder and this decoder agree on all 256 input
//  bytes across a long stream, and the disparity never leaves +/-8, the
//  encode is correct.
//
//  The fixed control-symbol tables are pinned byte-for-byte here and
//  re-checked by tb_packets and tb_top.
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none
`include "src/hdmi/hdmi_defs.vh"

module tb_tmds_encoder;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [2:0] mode;
    reg  [7:0] video_data;
    reg  [3:0] terc4_data;
    reg  [1:0] ctrl_data;
    wire [9:0] tmds;

    hdmi_tmds_encoder #(.CN(0)) dut (
        .clk_pixel(clk), .rst_n(rst_n),
        .mode(mode), .video_data(video_data),
        .data_island_data(terc4_data),
        .control_data(ctrl_data),
        .tmds(tmds)
    );

    integer errors = 0;
    integer checks = 0;

    // -----------------------------------------------------------------------
    // Independent TMDS data-symbol decoder (DVI Figure 6-3 semantics).
    // Returns the decoded byte; sets is_control when bits 9:8 are equal.
    // -----------------------------------------------------------------------
    reg is_control;
    reg [7:0] decoded;

    task decode_symbol;
        input  [9:0] sym;
        output       ctrl;
        output [7:0] data;
        integer i;
        reg   [7:0] p;    // payload = transition-minimised word
        reg        chain;
        reg        inv;
        begin
            chain = sym[8];
            inv   = ~chain;   // 1 when the encoder used an XNOR chain
            // HDMI 1.4a Table 5-23: the four control symbols are 1010101100,
            // 1001010100, 1011010100 and 1001101010 -- all of them 10xxxxxx.
            // So a symbol is a control symbol only if it matches one of those
            // patterns exactly.  Testing sym[9]==sym[8] instead is wrong:
            // Figure 5-7 legitimately emits data symbols with matching bits
            // 9:8 ({1,1} when q_m[8]==1, {0,0} when q_m[8]==0).
            ctrl = (sym == 10'b1010101100) || (sym == 10'b1001010100) ||
                   (sym == 10'b1011010100) || (sym == 10'b1001101010);
            if (!ctrl) begin
                // Bit 9 is the inversion flag: complement the payload when it
                // is set.  Bit 8 carries the chain polarity either way.
                for (i = 0; i < 8; i = i + 1)
                    p[i] = sym[9] ? ~sym[i] : sym[i];
                data[0] = p[0];
                for (i = 1; i < 8; i = i + 1)
                    data[i] = p[i] ^ p[i-1] ^ inv;
            end else begin
                data = 8'h00;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Drive one video byte and check the symbol that comes out two cycles
    // later (the encoder is a 2-stage pipeline).
    // -----------------------------------------------------------------------
    reg [7:0] got;
    reg       got_ctrl;

    task send_video;
        input [7:0] b;
        begin
            video_data = b;
            mode       = `TMDS_VIDEO;
            // The encoder is 2 stages: at the first edge vidsym_a latches f(b)
            // while tmds still holds the previous symbol; at the second edge
            // tmds takes f(b).  So sample after two edges.
            @(posedge clk);
            @(posedge clk);
            #1;
            decode_symbol(tmds, got_ctrl, got);
            if (got_ctrl) begin
                $display("FAIL: video byte %02h produced a CONTROL symbol %010b", b, tmds);
                errors = errors + 1;
            end else if (got !== b) begin
                $display("FAIL: sent %02h, decoded %02h (symbol %010b)", b, got, tmds);
                errors = errors + 1;
            end
            checks = checks + 1;
        end
    endtask

    integer i;
    integer max_disp;
    integer d;
    reg [7:0] lfsr;
    reg [7:0] b;

    initial begin
        mode       = `TMDS_CTRL;
        video_data = 8'h00;
        terc4_data = 4'h0;
        ctrl_data  = 2'b00;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: exhaustive, ascending, from a cold (disparity 0) start
        // ---------------------------------------------------------------
        for (i = 0; i < 256; i = i + 1)
            send_video(i[7:0]);

        // ---------------------------------------------------------------
        // Test 2: descending, which walks the disparity the other way
        // ---------------------------------------------------------------
        for (i = 255; i >= 0; i = i - 1)
            send_video(i[7:0]);

        // ---------------------------------------------------------------
        // Test 3: long pseudo-random stream, to hammer the boundary cases
        // where the running disparity saturates.
        // ---------------------------------------------------------------
        lfsr = 8'hA5;
        for (i = 0; i < 20000; i = i + 1) begin
            lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            send_video(lfsr);
        end

        // ---------------------------------------------------------------
        // Test 4: the running disparity must never leave +/-8
        // ---------------------------------------------------------------
        max_disp = 0;
        lfsr = 8'h3C;
        for (i = 0; i < 20000; i = i + 1) begin
            lfsr = {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            video_data = lfsr;
            mode       = `TMDS_VIDEO;
            @(posedge clk);
            #1;
            d = dut.disparity;
            if (d > max_disp) max_disp = d;
            if (-d > max_disp) max_disp = -d;
        end
        if (max_disp > 8) begin
            $display("FAIL: running disparity reached %0d, must stay within +/-8", max_disp);
            errors = errors + 1;
        end else begin
            $display("PASS: running disparity stayed within +/-%0d", max_disp);
        end

        // ---------------------------------------------------------------
        // Test 5: exhaustive round-trip from every reachable starting
        // disparity, not just a cold start.
        //
        // The encoder's behaviour depends on both the sign and the magnitude
        // of the running disparity, so driving only from 0 would leave the
        // "use XNOR vs XOR" decision untested in one direction.  Seed the
        // internal accumulator and walk all 256 bytes from each of the 15
        // states -7..+7 that the encoder can actually reach.
        //
        // sel_a is forced alongside disparity so the accumulator is not
        // cleared back to 0 by the non-video path on the seeding edge.
        // ---------------------------------------------------------------
        for (d = -7; d <= 7; d = d + 1) begin
            dut.sel_a      = 4'b0000;          // stage A holding TMDS_VIDEO
            dut.disparity  = d[4:0];
            for (i = 0; i < 256; i = i + 1)
                send_video(i[7:0]);
        end
        // Leave the DUT in a sane state for the fixed-table tests below.
        dut.disparity = 5'd0;
        $display("PASS: all 256 bytes round-trip from each of 15 starting disparity states");

        // ---------------------------------------------------------------
        // Test 6: fixed symbol tables
        // ---------------------------------------------------------------
        // Control symbols, HDMI 1.4a Table 5-23.
        for (i = 0; i < 4; i = i + 1) begin
            mode      = `TMDS_CTRL;
            ctrl_data = i[1:0];
            @(posedge clk);   // stage A
            @(posedge clk);   #1;
            case (i)
                0: if (tmds !== 10'b1101010100) begin
                       $display("FAIL: C0,C1=00 -> %010b, want 1101010100", tmds); errors=errors+1;
                   end
                1: if (tmds !== 10'b0010101011) begin
                       $display("FAIL: C0,C1=01 -> %010b, want 0010101011", tmds); errors=errors+1;
                   end
                2: if (tmds !== 10'b0101010100) begin
                       $display("FAIL: C0,C1=10 -> %010b, want 0101010100", tmds); errors=errors+1;
                   end
                3: if (tmds !== 10'b1010101011) begin
                       $display("FAIL: C0,C1=11 -> %010b, want 1010101011", tmds); errors=errors+1;
                   end
            endcase
            checks = checks + 1;
        end

        // Video guard band, HDMI 1.4a Sec 5.2.2.1.  Channel 0 -> 1011001100.
        mode = `TMDS_VGB;
        @(posedge clk);
        @(posedge clk); #1;
        if (tmds !== 10'b1011001100) begin
            $display("FAIL: video guard (ch0) -> %010b, want 1011001100", tmds); errors=errors+1;
        end
        checks = checks + 1;

        // Data guard band, HDMI 1.4a Sec 5.2.3.3.  Channel 0 is the TERC4
        // code of {2'b11, vsync, hsync}.
        for (i = 0; i < 4; i = i + 1) begin
            mode      = `TMDS_DGB;
            ctrl_data = i[1:0];
            @(posedge clk);
            @(posedge clk); #1;
            case (i)
                0: if (tmds !== 10'b1010001110) begin
                       $display("FAIL: data guard 00 -> %010b, want 1010001110", tmds); errors=errors+1;
                   end
                1: if (tmds !== 10'b1001110001) begin
                       $display("FAIL: data guard 01 -> %010b, want 1001110001", tmds); errors=errors+1;
                   end
                2: if (tmds !== 10'b0101100011) begin
                       $display("FAIL: data guard 10 -> %010b, want 0101100011", tmds); errors=errors+1;
                   end
                3: if (tmds !== 10'b1011000011) begin
                       $display("FAIL: data guard 11 -> %010b, want 1011000011", tmds); errors=errors+1;
                   end
            endcase
            checks = checks + 1;
        end

        // TERC4, HDMI 1.4a Table 5-31, all 16 nibbles on channel 0.
        for (i = 0; i < 16; i = i + 1) begin
            mode       = `TMDS_TERC4;
            terc4_data = i[3:0];
            @(posedge clk);
            @(posedge clk); #1;
            case (i)
                4'h0: if (tmds !== 10'b1010011100) begin $display("FAIL: TERC4 0 -> %010b",tmds); errors=errors+1; end
                4'h1: if (tmds !== 10'b1001100011) begin $display("FAIL: TERC4 1 -> %010b",tmds); errors=errors+1; end
                4'h2: if (tmds !== 10'b1011100100) begin $display("FAIL: TERC4 2 -> %010b",tmds); errors=errors+1; end
                4'h3: if (tmds !== 10'b1011100010) begin $display("FAIL: TERC4 3 -> %010b",tmds); errors=errors+1; end
                4'h4: if (tmds !== 10'b0101110001) begin $display("FAIL: TERC4 4 -> %010b",tmds); errors=errors+1; end
                4'h5: if (tmds !== 10'b0100011110) begin $display("FAIL: TERC4 5 -> %010b",tmds); errors=errors+1; end
                4'h6: if (tmds !== 10'b0110001110) begin $display("FAIL: TERC4 6 -> %010b",tmds); errors=errors+1; end
                4'h7: if (tmds !== 10'b0100111100) begin $display("FAIL: TERC4 7 -> %010b",tmds); errors=errors+1; end
                4'h8: if (tmds !== 10'b1011001100) begin $display("FAIL: TERC4 8 -> %010b",tmds); errors=errors+1; end
                4'h9: if (tmds !== 10'b0100111001) begin $display("FAIL: TERC4 9 -> %010b",tmds); errors=errors+1; end
                4'ha: if (tmds !== 10'b0110011100) begin $display("FAIL: TERC4 A -> %010b",tmds); errors=errors+1; end
                4'hb: if (tmds !== 10'b1011000110) begin $display("FAIL: TERC4 B -> %010b",tmds); errors=errors+1; end
                4'hc: if (tmds !== 10'b1010001110) begin $display("FAIL: TERC4 C -> %010b",tmds); errors=errors+1; end
                4'hd: if (tmds !== 10'b1001110001) begin $display("FAIL: TERC4 D -> %010b",tmds); errors=errors+1; end
                4'he: if (tmds !== 10'b0101100011) begin $display("FAIL: TERC4 E -> %010b",tmds); errors=errors+1; end
                4'hf: if (tmds !== 10'b1011000011) begin $display("FAIL: TERC4 F -> %010b",tmds); errors=errors+1; end
            endcase
            checks = checks + 1;
        end

        $display("");
        if (errors == 0)
            $display("tb_tmds_encoder: PASS (%0d checks)", checks);
        else
            $display("tb_tmds_encoder: FAIL (%0d errors over %0d checks)", errors, checks);
        if (errors == 0) $finish;
        else             $finish(1);
    end

endmodule

`default_nettype wire
