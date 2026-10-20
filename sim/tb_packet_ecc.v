// ============================================================================
//  tb_packet_ecc.v -- verification of hdmi_packet_ecc
//
//  The reference ECC here is an independent transcription of the BCH
//  generator in HDMI 1.4a Figure 5-5:
//
//      ecc = 0
//      for each payload bit, least significant first:
//          ecc = (ecc >> 1) ^ ((ecc[0] ^ bit) ? 8'h83 : 8'h00)
//
//  Known-good cross-check: an AVI InfoFrame header of 82 02 0D yields
//  ECC 0xE4 (the vector published with Mike Field's "Minimal HDMI").
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_packet_ecc;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg         island_start;
    reg         island_active;
    reg         hsync, vsync;
    reg  [23:0] header;
    reg  [223:0] body;
    wire [3:0]  ch0_data, ch1_data, ch2_data;

    hdmi_packet_ecc dut (
        .clk_pixel(clk), .rst_n(rst_n),
        .island_start(island_start),
        .island_active(island_active),
        .hsync(hsync), .vsync(vsync),
        .header(header),
        .body(body),
        .ch0_data(ch0_data), .ch1_data(ch1_data), .ch2_data(ch2_data)
    );

    integer errors = 0;

    // Reference generator, byte 0 first, LSB first.
    `include "sim/include/hdmi_ref.vh"

    task run_island;
        input [23:0] h;
        input [55:0] s0, s1, s2, s3;
        integer i;
        begin
            header        = h;
            body          = {s3, s2, s1, s0};
            island_start  = 1'b1;
            island_active = 1'b0;
            @(posedge clk);
            #1;
            island_start = 1'b0;
            for (i = 0; i < 32; i = i + 1) begin
                island_active = 1'b1;
                @(posedge clk);
                #1;
            end
            island_active = 1'b0;
        end
    endtask

    // Expected payload and parity for each of the four BCH blocks.
    reg [55:0] pl [0:3];
    reg [7:0]  pr [0:3];
    reg [7:0]  eh;
    integer    b;

    // Expected bit of BCH block `idx`: payload for 0..55, parity for 56..63.
    function blk_bit;
        input [55:0] payload;
        input [7:0]  parity;
        input integer idx;
        begin
            blk_bit = (idx < 56) ? payload[idx] : parity[idx - 56];
        end
    endfunction

    reg [7:0]  want;
    reg [7:0]  e;
    reg [55:0] payload;
    integer k;
    reg [63:0] got0;
    reg [23:0] hbytes;

    initial begin
        island_start  = 1'b0;
        island_active = 1'b0;
        header        = 24'h0;
        body = 224'd0;

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // ---------------------------------------------------------------
        // Test 1: the published golden vector, AVI InfoFrame header 82 02 0D
        // ---------------------------------------------------------------
        // hbytes holds the three header bytes: byte 0 first, LSB-first
        // within each byte, which is the order Figure 5-5 specifies.
        hbytes = 24'h0D0282;   // AVI InfoFrame: 82 02 0D
        want = bch(hbytes, 24);
        if (want !== 8'hE4) begin
            $display("FAIL: reference generator disagrees with published vector (got %02h, want E4)", want);
            errors = errors + 1;
        end else begin
            $display("PASS: reference BCH generator reproduces the 82 02 0D -> E4 vector");
        end

        // Now the DUT: after stepping 24 header pixels, BCH block 4 must carry
        // that ECC byte in bits [31:24] with the header in bits [23:0].
        run_island(24'h0D0282, 56'd0, 56'd0, 56'd0, 56'd0);
        if (dut.bch4 !== {8'hE4, 24'h0D0282}) begin
            $display("FAIL: BCH block 4 = %08h, want E40D0282", dut.bch4);
            errors = errors + 1;
        end else begin
            $display("PASS: DUT header ECC for 82 02 0D is E4");
        end

        // ---------------------------------------------------------------
        // Test 2: a subpacket's ECC byte, and that the payload is untouched
        // ---------------------------------------------------------------
        payload = 56'h0123456789ABCD;
        e = bch(payload, 56);

        run_island(24'h008200, payload, 56'd0, 56'd0, 56'd0);
        // Subpacket 0 spans pixels 0..27, stepping two payload bits per
        // pixel.  After 28 active pixels the register must hold the ECC.
        if (dut.g_block[0].ecc !== e) begin
            $display("FAIL: sub0 ECC = %02h, want %02h", dut.g_block[0].ecc, e);
            errors = errors + 1;
        end else begin
            $display("PASS: subpacket ECC = %02h for payload %014h", e, payload);
        end
        if (dut.g_block[0].bch[55:0] !== payload) begin
            $display("FAIL: sub0 payload bits [55:0] were modified");
            errors = errors + 1;
        end

        // ---------------------------------------------------------------
        // Test 3: the ECC register must be re-zeroed at each island start,
        // otherwise one island's parity would bleed into the next.
        // ---------------------------------------------------------------
        run_island(24'h0D0282, 56'd0, 56'd0, 56'd0, 56'd0);
        // Re-start an island: the registers must be zeroed at that edge,
        // before any new payload is stepped in.
        island_start  = 1'b1;
        island_active = 1'b0;
        @(posedge clk);
        #1;
        island_start = 1'b0;
        if (dut.ecc_hdr !== 8'h00 || dut.g_block[0].ecc !== 8'h00) begin
            $display("FAIL: ECC registers not cleared on island_start (hdr=%02h s0=%02h)",
                     dut.ecc_hdr, dut.g_block[0].ecc);
            errors = errors + 1;
        end else begin
            $display("PASS: ECC registers cleared on island_start");
        end

        // ---------------------------------------------------------------
        // Test 4: the per-pixel bit assignment of HDMI 1.3 Figure 5-4.
        //
        //   ch0 D0 = HSYNC, D1 = VSYNC, D2 = BCH block 4 (the 24 header bits
        //            over pixels 0..23, then its 8 parity bits over 24..31),
        //            D3 = 0 here (hdmi_data_island drives the framing bit)
        //   ch1 Dk / ch2 Dk = BCH block k, even-indexed block bits on ch1 and
        //            odd-indexed ones on ch2
        //
        // Every one of the 32 pixels x 3 channels x 4 bits is checked against
        // the source payload, including the parity pixels, so this also proves
        // the parity really is transmitted rather than merely accumulated.
        // ---------------------------------------------------------------
        hsync = 1'b1;
        vsync = 1'b0;
        header = 24'h820200;
        body   = {56'h33333333333333, 56'h22222222222222,
                  56'h11111111111111, 56'h0123456789ABCD};

        for (b = 0; b < 4; b = b + 1) begin
            pl[b] = body[56*b +: 56];
            pr[b] = bch(pl[b], 56);
        end
        eh     = bch(header, 24);

        island_start  = 1'b1;
        island_active = 1'b0;
        @(posedge clk);
        #1;
        island_start  = 1'b0;
        island_active = 1'b1;

        // The counter reads k at the top of each pass, so pixel k is the one
        // checked before the edge that advances it.
        want = errors[7:0];
        for (k = 0; k < 32; k = k + 1) begin
            if (ch0_data[0] !== 1'b1) begin
                $display("FAIL pixel %0d: ch0 D0 should carry HSYNC=1", k);
                errors = errors + 1;
            end
            if (ch0_data[1] !== 1'b0) begin
                $display("FAIL pixel %0d: ch0 D1 should carry VSYNC=0", k);
                errors = errors + 1;
            end
            if (ch0_data[3] !== 1'b0) begin
                $display("FAIL pixel %0d: ch0 D3 is 'x' in Figure 5-4, must be 0", k);
                errors = errors + 1;
            end
            if (k < 24) begin
                if (ch0_data[2] !== header[k]) begin
                    $display("FAIL pixel %0d: ch0 D2 should be header bit %0d, got %b",
                             k, k, ch0_data[2]);
                    errors = errors + 1;
                end
            end else begin
                if (ch0_data[2] !== eh[k - 24]) begin
                    $display("FAIL pixel %0d: ch0 D2 should be header parity bit %0d, got %b",
                             k, k - 24, ch0_data[2]);
                    errors = errors + 1;
                end
            end
            for (b = 0; b < 4; b = b + 1) begin
                if (ch1_data[b] !== blk_bit(pl[b], pr[b], 2*k)) begin
                    $display("FAIL pixel %0d: ch1 D%0d should be block %0d bit %0d, got %b",
                             k, b, b, 2*k, ch1_data[b]);
                    errors = errors + 1;
                end
                if (ch2_data[b] !== blk_bit(pl[b], pr[b], 2*k + 1)) begin
                    $display("FAIL pixel %0d: ch2 D%0d should be block %0d bit %0d, got %b",
                             k, b, b, 2*k + 1, ch2_data[b]);
                    errors = errors + 1;
                end
            end
            @(posedge clk);
            #1;
        end
        island_active = 1'b0;
        if (errors[7:0] == want)
            $display("PASS: island bit assignment matches Figure 5-4 over all 32 pixels");
        else
            $display("FAIL: island bit assignment, %0d checks wrong",
                     errors[7:0] - want);

        hsync = 1'b0;
        vsync = 1'b0;

        $display("");
        if (errors == 0) $display("tb_packet_ecc: PASS");
        else             $display("tb_packet_ecc: FAIL (%0d errors)", errors);
        if (errors == 0) $finish;
        else             $finish(1);
    end

endmodule

`default_nettype wire
