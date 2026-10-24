// ============================================================================
//  hdmi_packets.v -- HDMI 1.4a data island packet contents
//  Target: Sipeed Tang Nano 20K, Gowin Yosys flow.  Verilog-2001.
//
//  Every table reference below was read out of the HDMI specification PDF
//  (v1.3, which is byte-identical to v1.4b for the fields used here), not
//  inferred from third-party RTL:
//    Table 5-9   Null Packet Header
//    Table 5-10  Audio Clock Regeneration Packet Header
//    Table 5-11  Audio Clock Regeneration Subpacket
//    Table 5-12  Audio Sample Packet Header
//    Table 5-13  Audio Sample Subpacket
//    Table 5-14  InfoFrame Packet Header
//    Table 5-15  InfoFrame Packet Contents
//    Table 7-6   Audio Packet Layout and Layout Value
//    Table 7-7   Valid Sample_Present Bit Configurations for Layout 0
//    Table 7-3   Recommended N and Expected CTS for 48kHz
//    Table 8-1/8-2  AVI InfoFrame
//  sim/tb_packets.v checks every one of these against the spec text.
//
//  Every module outputs a packet as header[23:0] (HB0 in [7:0]) and
//  body[223:0], subpacket k in body[56k +: 56].  Within a subpacket SB0 is in
//  the low byte (confirmed by Table 5-11, where SB0 == 8'd0 lands in the least
//  significant byte), so an InfoFrame's PBn is simply body[8n +: 8].
// ============================================================================

`default_nettype none

// ----------------------------------------------------------------------------
//  hdmi_acr_packet -- Audio Clock Regeneration Packet
//
//  Header (Table 5-10): 01 00 00
//  Subpacket (Table 5-11), repeated identically in all four subpackets:
//      SB0 = 0x00
//      SB1 = {4'b0, CTS[19:16]}
//      SB2 = CTS[15:8]
//      SB3 = CTS[7:0]
//      SB4 = {4'b0, N[19:16]}
//      SB5 = N[15:8]
//      SB6 = N[7:0]
//
//  Table 7-3, 48 kHz column:
//      27 MHz        -> N = 6144,  CTS = 27000
//      25.2/1.001 MHz-> N = 6864,  CTS = 28125
//      25.2 MHz      -> N = 6144,  CTS = 25200
//      "Other"       -> N = 6144,  CTS = measured
// ----------------------------------------------------------------------------
module hdmi_acr_packet #(
    parameter [19:0] ACR_N   = 20'd6144,
    parameter [19:0] ACR_CTS = 20'd27000
) (
    output wire [23:0]  header,
    output wire [223:0] body
);
    assign header = 24'h000001;

    wire [55:0] acr_sub = {ACR_N[7:0], ACR_N[15:8], 4'b0000, ACR_N[19:16],
                           ACR_CTS[7:0], ACR_CTS[15:8], 4'b0000, ACR_CTS[19:16],
                           8'h00};

    // "The four Subpackets each contain the same Audio Clock regeneration
    // Subpacket."
    assign body = {4{acr_sub}};
endmodule

// ----------------------------------------------------------------------------
//  hdmi_audio_sample_packet -- Audio Sample Packet, 2-channel 16-bit L-PCM
//
//  Header (Table 5-12):
//      HB0 = 0x02                          (packet type: Audio Sample)
//      HB1 = {3'b000, layout, sp3, sp2, sp1, sp0}
//      HB2 = {B.3, B.2, B.1, B.0, flat3, flat2, flat1, flat0}
//
//  layout = 0 (Table 7-6): two channels, and each subpacket carries ONE
//  sample frame -- subpacket X holds "sample X+1" of channels 1 and 2 -- so a
//  packet carries one to four stereo frames.  sample_present[X] marks the
//  subpackets that carry a frame; frames are packed from subpacket 0 up.
//  Frame X is left[16X +: 16] / right[16X +: 16].
//
//  B.X is set when subpacket X holds frame 0 of a 192-frame IEC 60958
//  channel status block.  frame_index is the block position (0..191) of the
//  frame in subpacket 0, so subpacket X holds frame (frame_index + X) mod 192.
//
//  Subpacket (Table 5-13).  L.n / R.n are IEC 60958 time slots, and the
//  sample MSB is always slot 27, so a 16-bit sample occupies L.12..L.27:
//      SB0 = L.4..L.11   = 0 (unused LSBs of a 24-bit word)
//      SB1 = L.12..L.19  = left[7:0]
//      SB2 = L.20..L.27  = left[15:8]
//      SB3..SB5          = the same for right
//      SB6 = {PR, CR, UR, VR, PL, CL, UL, VL}
//
//  IEC 60958: V = 0 means the sample is valid, U = 0 (no user data), C is the
//  channel status bit of this frame, and P makes time slots 4..31 -- sample,
//  V, U, C and P -- even parity.
//
//  CHANNEL_STATUS is the 192-bit consumer channel status block, bit 0 first
//  (IEC 60958-3).  The default says: consumer, L-PCM, no copyright asserted
//  (bit 2), 48 kHz (bits 24..27 = 0100, i.e. bit 25), 16-bit word length
//  (bits 32..35 = 0100, i.e. bit 33).
// ----------------------------------------------------------------------------
module hdmi_audio_sample_packet #(
    parameter [191:0] CHANNEL_STATUS = (192'd1 << 2) | (192'd1 << 25) |
                                       (192'd1 << 33)
) (
    input  wire [3:0]   sample_present,
    input  wire [7:0]   frame_index,      // 0..191
    input  wire [63:0]  left,             // frame X in [16X +: 16]
    input  wire [63:0]  right,

    output wire [23:0]  header,
    output wire [223:0] body
);
    wire [3:0] b_flag;

    genvar x;
    generate
        for (x = 0; x < 4; x = x + 1) begin : g_sub
            // Block position of this subpacket's frame.
            wire [8:0] f_raw = {1'b0, frame_index} + x;
            wire [7:0] f     = (f_raw >= 9'd192) ? (f_raw - 9'd192) : f_raw[7:0];

            wire [15:0] l = left [16*x +: 16];
            wire [15:0] r = right[16*x +: 16];
            wire        c = CHANNEL_STATUS[f];

            // V = 0, U = 0, so even parity over slots 4..31 is ^sample ^ C.
            wire pl = ^l ^ c;
            wire pr = ^r ^ c;

            assign b_flag[x] = sample_present[x] && (f == 8'd0);
            assign body[56*x +: 56] = sample_present[x]
                ? {pr, c, 2'b00, pl, c, 2'b00, r, 8'h00, l, 8'h00}
                : 56'd0;
        end
    endgenerate

    assign header = {b_flag, 4'b0000,              // HB2: B.3..B.0, flat = 0
                     4'b0000, sample_present,      // HB1: layout 0
                     8'h02};                       // HB0: Audio Sample Packet
endmodule

// ----------------------------------------------------------------------------
//  hdmi_infoframe -- generic CEA-861-D InfoFrame packet
//
//  Header (Table 5-14):
//      HB0 = {1'b1, type[6:0]}
//      HB1 = version
//      HB2 = {3'b000, length[4:0]}
//
//  Contents (Table 5-15): PB0 = checksum, PB1..PB27 = data bytes, laid out
//  across the four 7-byte subpackets in order -- so the body is just
//  {IF_DATA, checksum}.
//
//  Checksum: "a byte-wide sum of all three bytes of the Packet Header and
//  all valid bytes of the InfoFrame Packet contents, plus the checksum
//  itself, equals zero."
// ----------------------------------------------------------------------------
module hdmi_infoframe #(
    parameter [6:0]   IF_TYPE    = 7'h02,  // AVI InfoFrame
    parameter [7:0]   IF_VERSION = 8'h02,
    parameter [4:0]   IF_LENGTH  = 5'd13,
    // PB1..PB27, PB1 in [7:0].  Bytes past IF_LENGTH must be 0; the checksum
    // only covers the first IF_LENGTH of them.
    parameter [215:0] IF_DATA    = 216'd0
) (
    output wire [23:0]  header,
    output wire [223:0] body
);
    assign header = {3'b000, IF_LENGTH, IF_VERSION, 1'b1, IF_TYPE};

    reg [7:0] checksum;
    integer   i;
    always @(*) begin
        checksum = header[7:0] + header[15:8] + header[23:16];
        for (i = 0; i < 27; i = i + 1)
            if (i < IF_LENGTH) checksum = checksum + IF_DATA[8*i +: 8];
        checksum = 8'h00 - checksum;
    end

    assign body = {IF_DATA, checksum};
endmodule

`default_nettype wire
