// ============================================================================
//  tb_packets.v -- verification of hdmi_packets.v
//
//  Every expectation below is derived from the HDMI specification text quoted
//  in hdmi_packets.v's header comment, not from the RTL:
//
//    Table 5-10  ACR header            = 01 00 00
//    Table 5-11  ACR subpacket         = SB0=00, CTS little-endian, N little-endian
//    Table 5-12  Audio Sample header   = 02, {000,layout,sp3..sp0}, {B.3..B.0,flat}
//    Table 5-13  Audio Sample subpkt   = 0, L[7:0], L[15:8], 0, R[7:0], R[15:8], B3
//               (16-bit sample MSB-aligned in IEC 60958 slots 12..27)
//               B3 = {PR,CR,UR,VR,PL,CL,UL,VL}, V = 0 (valid), P = even
//               parity over sample, V, U, C
//    Table 5-14  InfoFrame header      = {1,type}, version, {000,length}
//    Table 5-15  InfoFrame contents    = PB0=checksum, PB1..PB27 = data bytes
//    Table 7-3   ACR N / CTS for 48kHz
//    Table 7-6   layout 0 = 2 channels, one sample frame per subpacket
//
//  Packets are header[23:0] + body[223:0], subpacket k in body[56k +: 56],
//  SB0 in each subpacket's bits [7:0] (the Table 5-11 transcription in
//  hdmi_packets.v pins that down).
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_packets;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    task expect_eq;
        input [8*24-1:0] name;
        input [63:0]     got;
        input [63:0]     want;
        begin
            checks = checks + 1;
            if (got !== want) begin
                $display("FAIL: %0s = %016h, want %016h", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Helpers: pull subpacket b (0..3) out of a packet body, and subpacket
    // byte i (0..6) out of a subpacket.
    // -----------------------------------------------------------------------
    function [55:0] blk;
        input [223:0] bus;
        input integer  b;
        begin
            blk = bus[b*56 +: 56];
        end
    endfunction

    function [7:0] sb;
        input [55:0] sub;
        input integer  i;
        begin
            sb = sub[i*8 +: 8];
        end
    endfunction

    // -----------------------------------------------------------------------
    // hdmi_acr_packet
    // -----------------------------------------------------------------------
    wire [23:0]  acr_h1;
    wire [223:0] acr_b1;
    hdmi_acr_packet u_acr1 (
        .header(acr_h1), .body(acr_b1)
    );

    // Table 7-3, 25.2/1.001 MHz column.
    wire [23:0]  acr_h2;
    wire [223:0] acr_b2;
    hdmi_acr_packet #(.ACR_N(20'd6864), .ACR_CTS(20'd28125)) u_acr2 (
        .header(acr_h2), .body(acr_b2)
    );

    // Third instance with both 20-bit high nibbles non-zero.  Both real modes
    // have N and CTS below 65536, so without this the [19:16] fields would
    // never be exercised.
    wire [23:0]  acr_h3;
    wire [223:0] acr_b3;
    hdmi_acr_packet #(.ACR_N(20'h12345), .ACR_CTS(20'hABCDE)) u_acr3 (
        .header(acr_h3), .body(acr_b3)
    );

    // -----------------------------------------------------------------------
    // hdmi_audio_sample_packet
    // -----------------------------------------------------------------------
    reg  [3:0]  sample_present = 4'b1111;
    reg  [7:0]  frame_index = 8'd0;
    localparam [15:0] left0 = 16'h1234,  right0 = 16'h5678;
    localparam [15:0] left1 = 16'h9ABC,  right1 = 16'hDEF0;
    localparam [15:0] left2 = 16'h1357,  right2 = 16'h2468;
    localparam [15:0] left3 = 16'hBEEF,  right3 = 16'hCAFE;
    wire [23:0]  aspy_h;
    wire [223:0] aspy_b;
    hdmi_audio_sample_packet u_aspy (
        .sample_present(sample_present), .frame_index(frame_index),
        .left({left3, left2, left1, left0}),
        .right({right3, right2, right1, right0}),
        .header(aspy_h), .body(aspy_b)
    );

    // IEC 60958 consumer channel status the module defaults to: no
    // copyright (bit 2), 48 kHz (bit 25), 16-bit words (bit 33).
    function cs_bit;
        input integer f;
        begin
            cs_bit = (f == 2) || (f == 25) || (f == 33);
        end
    endfunction

    // Expected B3 byte {PR,CR,UR,VR,PL,CL,UL,VL} with U = V = 0 and even
    // parity over the 16 sample bits plus C.
    function [7:0] b3;
        input [15:0] l;
        input [15:0] r;
        input        c;
        begin
            b3 = {^r ^ c, c, 2'b00, ^l ^ c, c, 2'b00};
        end
    endfunction

    // -----------------------------------------------------------------------
    // hdmi_infoframe, an AVI InfoFrame whose 13 data bytes are 01..0D
    // -----------------------------------------------------------------------
    // PB1..PB13 = 01 02 ... 0D, so IF_DATA[103:0] = 0D0C0B0A090807060504030201.
    localparam [215:0] AVI_DATA = {112'd0, 104'h0D0C0B0A090807060504030201};
    wire [23:0]  if_h;
    wire [223:0] if_b;
    hdmi_infoframe #(
        .IF_TYPE(7'h02), .IF_VERSION(8'h02), .IF_LENGTH(5'd13),
        .IF_DATA(AVI_DATA)
    ) u_if (
        .header(if_h), .body(if_b)
    );

    integer i;
    reg [7:0] sum8;
    reg [7:0] hdr_byte0, hdr_byte1, hdr_byte2;

    initial begin
        // ===================================================================
        // Test 1: ACR packet, default 27 MHz parameters (N=6144, CTS=27000)
        // ===================================================================
        // CTS 27000 = 0x06978 (CTS[15:8]=0x69, CTS[19:16]=0),
        // N   6144 = 0x01800 -> SB0..SB6 = 00 00 69 78 00 18 00
        expect_eq("ACR27 header", acr_h1, 24'h000001);
        for (i = 0; i < 4; i = i + 1)
            expect_eq("ACR27 subpacket", blk(acr_b1, i), 56'h00_18_00_78_69_00_00);
        // "The four Subpackets each contain the same subpacket": the loop
        // above checks all four.

        // ===================================================================
        // Test 2: ACR packet, 25.2/1.001 MHz (N=6864, CTS=28125)
        // ===================================================================
        // CTS 28125 = 0x06DDD (CTS[15:8]=0x6D, CTS[19:16]=0),
        // N   6864 = 0x01AD0 -> SB0..SB6 = 00 00 6D DD 00 1A D0
        expect_eq("ACR25 header", acr_h2, 24'h000001);
        for (i = 0; i < 4; i = i + 1)
            expect_eq("ACR25 subpacket", blk(acr_b2, i), 56'hD0_1A_00_DD_6D_00_00);

        // A value with non-zero high nibbles, so that the CTS[19:16] and
        // N[19:16] fields that are zero for both real modes are still covered.
        // CTS 0xABCDE (CTS[19:16]=0xA, CTS[15:8]=0xBC, CTS[7:0]=0xDE),
        // N   0x12345 -> SB0..SB6 = 00 0A BC DE 01 23 45
        expect_eq("ACRwide header", acr_h3, 24'h000001);
        for (i = 0; i < 4; i = i + 1)
            expect_eq("ACRwide subpacket", blk(acr_b3, i), 56'h45_23_01_DE_BC_0A_00);

        // ===================================================================
        // Test 3: Audio Sample Packet header and subpacket packing
        // ===================================================================
        sample_present = 4'b1111;
        frame_index    = 8'd0;
        #1;
        // HB0 = 0x02 (Audio Sample), HB1 = 0x0F (layout 0, four frames)
        expect_eq("ASP HB0", aspy_h[7:0],   8'h02);
        expect_eq("ASP HB1", aspy_h[15:8],  8'h0F);
        // Subpacket 0 holds block frame 0: B.0 = 1, flat = 0
        expect_eq("ASP HB2 block start", aspy_h[23:16], 8'h10);

        // 16-bit samples sit in L.12..L.27 / R.12..R.27: SB1/SB2 and SB4/SB5.
        expect_eq("ASP sub0 SB0 = 0",            sb(blk(aspy_b, 0), 0), 8'h00);
        expect_eq("ASP sub0 SB1 = left0[7:0]",   sb(blk(aspy_b, 0), 1), 8'h34);
        expect_eq("ASP sub0 SB2 = left0[15:8]",  sb(blk(aspy_b, 0), 2), 8'h12);
        expect_eq("ASP sub0 SB3 = 0",            sb(blk(aspy_b, 0), 3), 8'h00);
        expect_eq("ASP sub0 SB4 = right0[7:0]",  sb(blk(aspy_b, 0), 4), 8'h78);
        expect_eq("ASP sub0 SB5 = right0[15:8]", sb(blk(aspy_b, 0), 5), 8'h56);
        // Frame 0: C = 0.  0x1234 has 5 ones -> PL = 1; 0x5678 has 8 -> PR = 0.
        expect_eq("ASP sub0 SB6 frame 0",        sb(blk(aspy_b, 0), 6), 8'h08);

        // One stereo frame per subpacket.
        expect_eq("ASP sub1 SB1 = left1[7:0]",   sb(blk(aspy_b, 1), 1), 8'hBC);
        expect_eq("ASP sub1 SB2 = left1[15:8]",  sb(blk(aspy_b, 1), 2), 8'h9A);
        expect_eq("ASP sub1 SB4 = right1[7:0]",  sb(blk(aspy_b, 1), 4), 8'hF0);
        expect_eq("ASP sub2 SB1 = left2[7:0]",   sb(blk(aspy_b, 2), 1), 8'h57);
        expect_eq("ASP sub3 SB1 = left3[7:0]",   sb(blk(aspy_b, 3), 1), 8'hEF);
        expect_eq("ASP sub3 SB5 = right3[15:8]", sb(blk(aspy_b, 3), 5), 8'hCA);
        // Frame 2 carries channel status bit 2 = 1.
        expect_eq("ASP sub2 SB6 frame 2 (C=1)",  sb(blk(aspy_b, 2), 6),
                  b3(left2, right2, 1'b1));
        expect_eq("ASP sub1 SB6 frame 1 (C=0)",  sb(blk(aspy_b, 1), 6),
                  b3(left1, right1, 1'b0));

        // ===================================================================
        // Test 4: channel status follows the frame's position in the block
        // ===================================================================
        for (i = 0; i < 192; i = i + 1) begin
            frame_index = i;
            #1;
            expect_eq("ASP SB6 tracks channel status", sb(blk(aspy_b, 0), 6),
                      b3(left0, right0, cs_bit(i)));
        end

        // ===================================================================
        // Test 5: B.X marks the subpacket holding block frame 0, and absent
        // subpackets are neither flagged nor filled
        // ===================================================================
        frame_index = 8'd190;         // subpackets hold frames 190,191,0,1
        #1;
        expect_eq("ASP B.2 at block wrap", aspy_h[23:16], 8'h40);
        frame_index = 8'd189;         // frames 189,190,191,0
        #1;
        expect_eq("ASP B.3 at block wrap", aspy_h[23:16], 8'h80);
        sample_present = 4'b0111;     // subpacket 3 absent
        #1;
        expect_eq("ASP HB1 three frames", aspy_h[15:8], 8'h07);
        expect_eq("ASP no B.3 when absent", aspy_h[23:16], 8'h00);
        expect_eq("ASP absent subpacket is zero", blk(aspy_b, 3), 56'd0);
        sample_present = 4'b0001;
        frame_index    = 8'd0;
        #1;
        expect_eq("ASP HB1 one frame", aspy_h[15:8], 8'h01);
        expect_eq("ASP B.0 one frame", aspy_h[23:16], 8'h10);

        // ===================================================================
        // Test 6: InfoFrame header, checksum and byte placement
        // ===================================================================
        // {000, 13, 2, 1, 0000010} = 0D 02 82
        expect_eq("AVI header", if_h, 24'h0D0282);
        // Header sums to 0x91, data 01..0D sums to 0x5B, so the checksum
        // must be 0x100 - 0xEC = 0x14 for the total to be zero.
        expect_eq("AVI PB0 checksum", sb(blk(if_b, 0), 0), 8'h14);
        // Subpacket 0 is PB0..PB6 -> checksum, then data bytes 1..6
        expect_eq("AVI PB1", sb(blk(if_b, 0), 1), 8'h01);
        expect_eq("AVI PB6", sb(blk(if_b, 0), 6), 8'h06);
        // Subpacket 1 is PB7..PB13 -> data bytes 7..13
        expect_eq("AVI PB7",  sb(blk(if_b, 1), 0), 8'h07);
        expect_eq("AVI PB13", sb(blk(if_b, 1), 6), 8'h0D);
        // Bytes past the 13-byte length are not transmitted, so they are zero.
        expect_eq("AVI PB14", sb(blk(if_b, 2), 0), 8'h00);

        // The spec's actual rule: header + all valid data bytes + checksum
        // sums to zero.  PB1..PB6 live in subpacket 0 and PB7..PB13 in
        // subpacket 1, so the data has to be walked across both.
        sum8 = if_h[7:0] + if_h[15:8] + if_h[23:16];   // header
        for (i = 0; i < 6; i = i + 1)                  // PB1..PB6
            sum8 = sum8 + sb(blk(if_b, 0), i + 1);
        for (i = 0; i < 7; i = i + 1)                  // PB7..PB13
            sum8 = sum8 + sb(blk(if_b, 1), i);
        sum8 = sum8 + sb(blk(if_b, 0), 0);            // PB0, the checksum
        expect_eq("AVI zero-sum checksum rule", sum8, 8'h00);

        $display("");
        if (errors == 0) $display("tb_packets: PASS (%0d checks)", checks);
        else             $display("tb_packets: FAIL (%0d errors, %0d checks)", errors, checks);
        if (errors == 0) $finish;
        else             $finish(1);
    end

endmodule

`default_nettype wire
