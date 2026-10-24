// ============================================================================
//  hdmi_packet_ecc.v -- HDMI data island packet layout + BCH error correction
//  Target: Sipeed Tang Nano 20K, Gowin Yosys flow.  Verilog-2001.
//
//  References:
//    HDMI 1.3 Sec 5.2.3.4  Data Island Packet Construction
//                Sec 5.2.3.5  Data Island Error Correction
//                Figure 5-4   Data Island Packet and ECC Structure
//                Figure 5-5   ECC generator (BCH(32,24) / BCH(64,56))
//
//  ---------------------------------------------------------------------------
//  Island bit assignment over the 32-pixel body (Figure 5-4)
//
//  Channel 0 carries the header, channel 1 and channel 2 carry the body.
//  Every channel's 4 bits are a TERC4 input word (D3..D0).
//
//    ch0: D0 = HSYNC, D1 = VSYNC, D2 = "BCH block 4", D3 = "x"
//         "BCH block 4" is the 32-bit BCH(32,24) code over the 3 header
//         bytes: the 24 header bits in Chars 0..23, then the 8 parity bits in
//         Chars 24..31.  Figure 5-4 marks D3 as "x" within a packet, but
//         Figure 5-3 defines it across the island: 0 on the first body
//         character of the island, 1 on every other.  That framing bit is
//         island-level, so hdmi_data_island drives it; this module leaves
//         D3 at 0.
//
//    ch1/ch2: Dk of *both* channels carries BCH block k (Figure 5-4 key row
//         "0B0 0C0 1B0 1C0 2B0 2C0 3B0 3C0" against "bit 0..bit 7"), which is
//         what Sec 5.2.3.4 states in prose: "BCH Block 0 ... is mapped onto bit
//         0 of both Channel 1 and Channel 2 ... Likewise, BCH Block 1 ... is
//         mapped onto bit 1 of both Channels 1 and Channel 2."
//
//         Each block is 64 bits (56 payload + 8 parity) and is sent two bits
//         per pixel for 32 pixels: the even-indexed block bit on ch1, the
//         odd-indexed one on ch2.  Block k == subpacket k, so
//
//             ch1[k] = bchk[2n]      ch2[k] = bchk[2n+1]
//
//         with n the island pixel index.  For n < 28 those indices are the
//         subpacket payload; for n >= 28 they walk the parity byte.
//
//  An earlier revision of this file put subpackets 0/1 on ch1 and 2/3 on ch2,
//  and drove the header and first-word flag on ch0 bit 0.  Both are wrong: the
//  header belongs on ch0 D2, HSYNC/VSYNC on D0/D1, and each BCH block
//  straddles both channels on the same bit index.  sim/tb_data_island.v
//  decodes the island the way a sink does and would fail on that mapping.
//
//  The ECC is a BCH code seeded with zero and stepped once per payload bit,
//  least-significant bit first, byte 0 first.  Reference vector from Mike
//  Field's "Minimal HDMI" writeup: an AVI InfoFrame header of 82 02 0D
//  yields ECC 0xE4.  sim/tb_packet_ecc.v checks that vector.
// ============================================================================

`default_nettype none

module hdmi_packet_ecc (
    input  wire        clk_pixel,
    input  wire        rst_n,

    // High on the pixel before this packet's body: resets the 0..31 pixel
    // counter and the ECC accumulators.
    input  wire        island_start,

    // High on every pixel of this packet's 32-pixel body.  Advances the
    // counter.
    input  wire        island_active,

    // Sync bits riding ch0 D0/D1 for the whole island (Sec 5.2.3.1).
    input  wire        hsync,
    input  wire        vsync,

    // Packet header (HB0 in [7:0]) and body (subpacket k in [56k +: 56]);
    // this module appends the ECC bytes.
    input  wire [23:0]  header,
    input  wire [223:0] body,

    // TERC4 input words for the current island pixel: {D3, D2, D1, D0}.
    output wire [3:0]  ch0_data,
    output wire [3:0]  ch1_data,
    output wire [3:0]  ch2_data
);

    // -----------------------------------------------------------------------
    // Island pixel counter, 0..31
    // -----------------------------------------------------------------------
    reg [4:0] counter;
    always @(posedge clk_pixel) begin
        if (!rst_n)                 counter <= 5'd0;
        else if (island_start)      counter <= 5'd0;
        else if (island_active)     counter <= counter + 5'd1;
    end

    // -----------------------------------------------------------------------
    // BCH ECC: one 8-bit shift register per block, seeded with zero.
    //   next = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'h83 : 8'h00)
    //
    // The payload-bit argument is named "b", not "bit": "bit" is a reserved
    // SystemVerilog keyword and trips yosys' lexer when the file is read with
    // -sv.
    //
    // A block's accumulator is held once its payload has been stepped --
    // otherwise the parity byte would be fed back into its own generator:
    // subpacket blocks (56 bits, 2 per pixel) hold from pixel 28, the header
    // (24 bits, 1 per pixel) from pixel 24.
    // -----------------------------------------------------------------------
    function [7:0] ecc_step;
        input [7:0] ecc;
        input       b;
        begin
            ecc_step = (ecc >> 1) ^ ((ecc[0] ^ b) ? 8'h83 : 8'h00);
        end
    endfunction

    // "BCH block 4": the header and its BCH(32,24) parity in one 32-bit view.
    // Bits [23:0] walk the header in BCH input order, [31:24] the parity.
    reg  [7:0]  ecc_hdr;
    wire [31:0] bch4 = {ecc_hdr, header};

    always @(posedge clk_pixel) begin
        if (!rst_n || island_start)
            ecc_hdr <= 8'd0;
        else if (island_active && counter < 5'd24)
            ecc_hdr <= ecc_step(ecc_hdr, header[counter]);
    end

    // Blocks 0..3: subpacket k plus its BCH(64,56) parity, sent two bits per
    // pixel -- the even-indexed bit on ch1 and the odd one on ch2, both on
    // bit k (Figure 5-4).  Index 56..63 walks the parity byte.
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_block
            wire [55:0] payload = body[56*k +: 56];
            reg  [7:0]  ecc;
            wire [63:0] bch = {ecc, payload};

            wire [5:0] even = {counter, 1'b0};
            wire [5:0] odd  = {counter, 1'b1};

            always @(posedge clk_pixel) begin
                if (!rst_n || island_start)
                    ecc <= 8'd0;
                else if (island_active && counter < 5'd28)
                    ecc <= ecc_step(ecc_step(ecc, payload[even]), payload[odd]);
            end

            assign ch1_data[k] = bch[even];
            assign ch2_data[k] = bch[odd];
        end
    endgenerate

    // Ch0 (Figure 5-4): D0 = HSYNC, D1 = VSYNC, D2 = header then its parity.
    // D3 is the island framing bit, which hdmi_data_island drives.
    assign ch0_data = {1'b0, bch4[counter], vsync, hsync};

endmodule

`default_nettype wire
