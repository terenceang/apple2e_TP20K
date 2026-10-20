// ============================================================================
//  hdmi_tx.v -- HDMI transmitter core: video timing, data islands, TMDS
//  Target: Sipeed Tang Nano 20K, Gowin Yosys flow.  Verilog-2001.
//
//  Everything here runs in the pixel clock domain and ends in three 10-bit
//  TMDS symbols per pixel; serialisation is the caller's (see src/top.v).
//
//      video_rgb ------------------------------------------------.
//      audio_valid/l/r -> sample buffer --.                      v
//      ACR / AVI / Audio InfoFrame ------> hdmi_island_scheduler -> hdmi_data_island
//                                             |  timing, preambles        |
//                                             v                           v
//                                       3 x hdmi_tmds_encoder <- period / TERC4 select
//
//  Packets per line, pushed at fixed pixels well ahead of the scheduler's
//  commit point, at most three so one island (N_FIT = 3 at 720x480p) always
//  drains them:
//    * an Audio Sample Packet whenever samples are waiting (48 kHz over a
//      31.47 kHz line rate is 1 or 2 frames per line; the buffer holds 4),
//    * an Audio Clock Regeneration packet every ACR_LINES lines,
//    * the AVI InfoFrame and the Audio InfoFrame once per frame each, on two
//      vertical blanking lines.
//
//  Sync polarity: the scheduler's hsync/vsync are "in the sync pulse".
//  HSYNC_POL / VSYNC_POL give the level on the wire during the pulse.
// ============================================================================

`default_nettype none
`include "src/hdmi/hdmi_defs.vh"

module hdmi_tx #(
    parameter integer H_TOTAL   = `VM_H_TOTAL,
    parameter integer H_ACTIVE  = `VM_H_ACTIVE,
    parameter integer H_FRONT   = `VM_H_FRONT,
    parameter integer H_SYNC_W  = `VM_H_SYNC_W,
    parameter integer V_TOTAL   = `VM_V_TOTAL,
    parameter integer V_ACTIVE  = `VM_V_ACTIVE,
    parameter integer V_FRONT   = `VM_V_FRONT,
    parameter integer V_SYNC_W  = `VM_V_SYNC_W,
    parameter         HSYNC_POL = `VM_HSYNC_POL,
    parameter         VSYNC_POL = `VM_VSYNC_POL,
    parameter [7:0]   VIC       = `VM_VIC,
    parameter [1:0]   ASPECT    = `VM_ASPECT,
    // AVI Q1..Q0 (CEA-861-D Table 11): 00 = default for the format (limited
    // range for a CE mode like 720x480p), 01 = limited, 10 = full range.
    parameter [1:0]   RGB_QUANT = 2'b00,
    parameter [19:0]  ACR_N     = `VM_ACR_N,
    parameter [19:0]  ACR_CTS   = `VM_ACR_CTS,
    parameter integer ACR_LINES = 16
) (
    input  wire        clk_pixel,
    input  wire        rst_n,

    // Video source: rgb for (pixel_x, pixel_y), combinationally, same cycle.
    output wire [9:0]  pixel_x,
    output wire [9:0]  pixel_y,
    input  wire [23:0] video_rgb,      // {R, G, B}

    // Audio source: one stereo frame per audio_valid strobe, 48 kHz.
    input  wire        audio_valid,
    input  wire [15:0] audio_l,
    input  wire [15:0] audio_r,

    // Lane k symbol in [10k +: 10]: lane 0 blue + sync, 1 green, 2 red.
    output wire [29:0] tmds
);

    localparam integer MAX_PACKETS = 3;
    localparam integer VIDEO_GB    = 2;

    // -----------------------------------------------------------------------
    // Scheduler
    // -----------------------------------------------------------------------
    wire         hsync_pulse, vsync_pulse;
    wire         video_led, video_act;
    wire [9:0]   hcount, vcount;
    wire [3:0]   ctl;
    wire         src_ready, island_start;

    reg          src_valid;
    reg  [23:0]  src_header;
    reg  [223:0] src_body;

    wire         pkt_valid;
    wire [23:0]  pkt_header;
    wire [223:0] pkt_body;

    hdmi_island_scheduler #(
        .H_TOTAL(H_TOTAL), .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT),
        .H_SYNC_W(H_SYNC_W), .V_TOTAL(V_TOTAL), .V_ACTIVE(V_ACTIVE),
        .V_FRONT(V_FRONT), .V_SYNC_W(V_SYNC_W), .MAX_PACKETS(MAX_PACKETS)
    ) u_sched (
        .clk_pixel(clk_pixel), .rst_n(rst_n),
        .src_valid(src_valid), .src_ready(src_ready),
        .src_header(src_header), .src_body(src_body),
        .pkt_valid(pkt_valid), .pkt_header(pkt_header), .pkt_body(pkt_body),
        .island_start(island_start),
        .video_led(video_led), .video_act(video_act),
        .hsync(hsync_pulse), .vsync(vsync_pulse),
        .hcount(hcount), .vcount(vcount),
        .ctl(ctl)
    );

    // Active-pixel coordinates for the video source.  Only meaningful while
    // video_act is high.
    assign pixel_x = hcount - VIDEO_GB;
    assign pixel_y = vcount;

    // Sync as it appears on the wire.
    wire hs = hsync_pulse ? HSYNC_POL : ~HSYNC_POL;
    wire vs = vsync_pulse ? VSYNC_POL : ~VSYNC_POL;

    // -----------------------------------------------------------------------
    // Audio sample buffer
    //
    // Up to four stereo frames wait here for the next Audio Sample Packet,
    // frame X in [16X +: 16].  A frame arriving on the push pixel starts the
    // next packet's buffer.  frame_index is the IEC 60958 block position of
    // the oldest buffered frame, which is what subpacket 0 carries.
    // -----------------------------------------------------------------------
    localparam [9:0] PUSH_AUDIO = 10'd4;
    localparam [9:0] PUSH_ACR   = 10'd6;
    localparam [9:0] PUSH_IF    = 10'd8;

    reg  [63:0] abuf_l, abuf_r;
    reg  [2:0]  acount;
    reg  [7:0]  frame_index;

    wire push_audio = (hcount == PUSH_AUDIO) && (acount != 3'd0);
    wire [8:0] frame_next = frame_index + acount;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            acount      <= 3'd0;
            frame_index <= 8'd0;
        end else if (push_audio && src_ready) begin
            frame_index <= (frame_next >= 9'd192) ? frame_next - 9'd192
                                                  : frame_next[7:0];
            acount      <= {2'b00, audio_valid};
            if (audio_valid) begin
                abuf_l[15:0] <= audio_l;
                abuf_r[15:0] <= audio_r;
            end
        end else if (audio_valid && acount != 3'd4) begin
            abuf_l[16*acount[1:0] +: 16] <= audio_l;
            abuf_r[16*acount[1:0] +: 16] <= audio_r;
            acount                       <= acount + 3'd1;
        end
    end

    // -----------------------------------------------------------------------
    // Packet contents
    // -----------------------------------------------------------------------
    wire [23:0]  asp_h, acr_h, avi_h, aif_h;
    wire [223:0] asp_b, acr_b, avi_b, aif_b;

    // Frames are packed from subpacket 0: acount frames -> low acount bits.
    wire [3:0] sample_present = ~(4'b1111 << acount);

    hdmi_audio_sample_packet u_asp (
        .sample_present(sample_present), .frame_index(frame_index),
        .left(abuf_l), .right(abuf_r),
        .header(asp_h), .body(asp_b)
    );

    hdmi_acr_packet #(.ACR_N(ACR_N), .ACR_CTS(ACR_CTS)) u_acr (
        .header(acr_h), .body(acr_b)
    );

    // AVI InfoFrame (CEA-861-D Table 8), version 2, 13 bytes:
    //   PB1 = 0x10  RGB, active format information present, no bars/scan info
    //   PB2 = {C=00, M=ASPECT, R=1000 (same as picture)}
    //   PB3 = {ITC=0, EC=000, Q=RGB_QUANT, SC=00}  no IT content, no scaling
    //   PB4 = VIC
    //   PB5 = 0x00  no pixel repetition
    hdmi_infoframe #(
        .IF_TYPE(7'h02), .IF_VERSION(8'h02), .IF_LENGTH(5'd13),
        .IF_DATA({176'd0, 8'h00, VIC, {4'b0000, RGB_QUANT, 2'b00},
                  {2'b00, ASPECT, 4'b1000}, 8'h10})
    ) u_avi (
        .header(avi_h), .body(avi_b)
    );

    // Audio InfoFrame (CEA-861-D Table 17), version 1, 10 bytes:
    //   PB1 = 0x01  coding type and sample rate from the stream, 2 channels
    //   PB4 = 0x00  speaker allocation FL/FR
    hdmi_infoframe #(
        .IF_TYPE(7'h04), .IF_VERSION(8'h01), .IF_LENGTH(5'd10),
        .IF_DATA({208'd0, 8'h01})
    ) u_aif (
        .header(aif_h), .body(aif_b)
    );

    // -----------------------------------------------------------------------
    // Packet source mux: one push per pixel, on fixed pixels of the line
    // -----------------------------------------------------------------------
    wire push_acr = (hcount == PUSH_ACR) && (vcount % ACR_LINES == 0);
    wire push_avi = (hcount == PUSH_IF)  && (vcount == V_ACTIVE + 1);
    wire push_aif = (hcount == PUSH_IF)  && (vcount == V_ACTIVE + 2);

    always @(*) begin
        src_valid = push_audio || push_acr || push_avi || push_aif;
        case (1'b1)
            push_acr: {src_header, src_body} = {acr_h, acr_b};
            push_avi: {src_header, src_body} = {avi_h, avi_b};
            push_aif: {src_header, src_body} = {aif_h, aif_b};
            default:  {src_header, src_body} = {asp_h, asp_b};
        endcase
    end

    // -----------------------------------------------------------------------
    // Data island
    // -----------------------------------------------------------------------
    wire [2:0] isl_mode;
    wire [3:0] isl_ch0, isl_ch1, isl_ch2;

    hdmi_data_island #(.MAX_PACKETS(MAX_PACKETS)) u_isl (
        .clk_pixel(clk_pixel), .rst_n(rst_n),
        .hsync(hs), .vsync(vs),
        .pkt_valid(pkt_valid), .pkt_header(pkt_header), .pkt_body(pkt_body),
        .pkt_count(), .island_start(island_start), .island_mode(),
        .tmds_mode(isl_mode),
        .ch0_data(isl_ch0), .ch1_data(isl_ch1), .ch2_data(isl_ch2)
    );

    // -----------------------------------------------------------------------
    // Period select and TMDS encoders, one per lane
    // -----------------------------------------------------------------------
    wire [2:0] enc_mode = (isl_mode != `TMDS_CTRL) ? isl_mode    :
                          video_led                ? `TMDS_VGB   :
                          video_act                ? `TMDS_VIDEO : `TMDS_CTRL;

    // Per lane: video byte ({R, G, B} is already lane 2..0), TERC4 nibble,
    // control bits (sync on lane 0, the CTL preamble bits on lanes 1 and 2).
    wire [11:0] lane_terc4 = {isl_ch2, isl_ch1, isl_ch0};
    wire [5:0]  lane_ctrl  = {ctl[3:2], ctl[1:0], vs, hs};

    genvar k;
    generate
        for (k = 0; k < 3; k = k + 1) begin : g_lane
            hdmi_tmds_encoder #(.CN(k)) u_enc (
                .clk_pixel(clk_pixel), .rst_n(rst_n), .mode(enc_mode),
                .video_data(video_rgb[8*k +: 8]),
                .data_island_data(lane_terc4[4*k +: 4]),
                .control_data(lane_ctrl[2*k +: 2]),
                .tmds(tmds[10*k +: 10]));
        end
    endgenerate

endmodule

`default_nettype wire
