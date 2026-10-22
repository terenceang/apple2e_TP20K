// ============================================================================
//  hdmi_island_scheduler.v -- video timing and data island placement
//  Target: Sipeed Tang Nano 20K, Gowin Yosys flow.  Verilog-2001.
//
//  References:
//    HDMI 1.3 Sec 5.2.1.1  Preamble: 8 control characters precede each period
//                Sec 5.2.1.2  Sink resynchronises in >= tS,min control chars
//                Table 5-3     tS,min = 12 pixels
//                Sec 5.2.2     Video Data Period opens with a 2-char guard band
//                Sec 5.2.3.1  HSYNC/VSYNC ride ch0 D0/D1 for the whole island
//                Sec 5.2.3.2  Island placement and duration
//                Table 5-6     ch0 guard band code selected by {VSYNC, HSYNC}
//                Figure 5-2    720x480p: 858 total, 138 horizontal blanking
//
//  One line is laid out as
//
//      |<--------------- H_TOTAL ---------------->|
//      |<---- video data period ---->|<-- blanking -->|
//      GB   active video            ^ island ^ control
//      2    H_ACTIVE                | 4+32N |  >= 12
//                                    ^ 12 control pixels carry the Preamble
//
//  Three rules from Sec 5.2.3.2 / Sec 5.2.1.1 constrain the island:
//
//    1. A Control Period is at least tS,min = 12 pixels, and its last 8
//       characters are the Preamble, so the leading guard band may not start
//       until 12 pixels after the video data period ends.
//    2. The same holds between the island and the next video data period.
//    3. The island is 4 + 32*N pixels, so the blanking interval alone fixes
//       the maximum N.  640x480p (160 blanking) allows N = 4; 720x480p
//       (138 blanking) allows N = 3.
//
//  Pipeline alignment.  hdmi_data_island drives its tmds_mode and ch*_data
//  combinationally, so the island and the video reach the encoder on the same
//  pixel and both take the same VIDEO_LATENCY = 2 pixels to the wire.  There is
//  therefore nothing to correct for, and ISLAND_START_PX is simply the first
//  blanking pixel that leaves a full tS,min = 12 control characters between the
//  video data period and the island.  The two latencies are still separate
//  parameters and the geometry still accounts for the difference, so that
//  re-adding a register inside hdmi_data_island cannot silently shorten the
//  gap below 12.
//
//  hsync is deliberately allowed to change in the middle of an island: with
//  both supported modes the island is longer than the front porch, so no
//  placement avoids it.  Sec 5.2.3.1 covers exactly this -- "During every TMDS
//  clock period of the Data Island, including the Guard Band, bits 0 and 1 of
//  TMDS Channel 0 transmit an encoded form of HSYNC and VSYNC" -- and the
//  channel 0 guard band code is chosen from {VSYNC, HSYNC} per Table 5-6, so
//  hdmi_tmds_encoder recomputes it per pixel.
// ============================================================================

`default_nettype none
`include "src/hdmi/hdmi_defs.vh"

module hdmi_island_scheduler #(
    parameter integer H_TOTAL     = `VM_H_TOTAL,
    parameter integer H_ACTIVE    = `VM_H_ACTIVE,
    parameter integer H_FRONT     = `VM_H_FRONT,   // active end -> hsync start
    parameter integer H_SYNC_W    = `VM_H_SYNC_W,
    parameter integer V_TOTAL     = `VM_V_TOTAL,
    parameter integer V_ACTIVE    = `VM_V_ACTIVE,
    parameter integer V_FRONT     = `VM_V_FRONT,   // active end -> vsync start
    parameter integer V_SYNC_W    = `VM_V_SYNC_W,
    // Ceiling on packets per island; must not exceed hdmi_data_island's
    // MAX_PACKETS, since that is how many slots it can hold.
    parameter integer MAX_PACKETS  = 3,
    parameter integer TS_MIN       = 12,  // Table 5-3
    // Pixels from a driven value to the tmds pin, per path.  Both are the
    // encoder's two stages; hdmi_data_island is combinational.  They are
    // separate parameters so the geometry below stays correct if that changes.
    parameter integer VIDEO_LATENCY = 2,
    parameter integer ISLAND_LATENCY = 2
) (
    input  wire        clk_pixel,
    input  wire        rst_n,

    // -----------------------------------------------------------------------
    // hdmi_data_island holds at least one packet for this line's island.  The
    // sources push straight into its slots, early in the line (local change,
    // see "Packets" below).
    // -----------------------------------------------------------------------
    input  wire        pkt_pending,
    output wire        island_start,

    // -----------------------------------------------------------------------
    // Video
    // -----------------------------------------------------------------------
    output wire        video_led,   // 2-character video guard band
    output wire        video_act,   // active video pixels

    // -----------------------------------------------------------------------
    // Timing: sync is "in the pulse" (the caller applies polarity)
    // -----------------------------------------------------------------------
    output wire        hsync,
    output wire        vsync,
    output wire [9:0]  hcount,
    output wire [9:0]  vcount,

    // {CTL3, CTL2, CTL1, CTL0} for the control period (Sec 5.2.1.1).  Ch1
    // sends {CTL1, CTL0} and ch2 sends {CTL3, CTL2} as control characters.
    // Non-zero only during the 8-pixel Preamble in front of a video data
    // period (1000) or a data island (1010), in generator coordinates.
    output wire [3:0]  ctl
);

    // -----------------------------------------------------------------------
    // Derived line geometry
    //
    // Pixel indices here count along the line as the generator sees them: the
    // video data period occupies pixels 0 .. ACTIVE_END-1, where ACTIVE_END is
    // the first blanking pixel, because it is the 2-character video guard band
    // (Sec 5.2.2) followed by H_ACTIVE active pixels.
    //
    // A value driven combinationally from pixel P reaches the tmds pin
    // LATENCY pixels later, so the two paths reach the wire at different
    // points unless their depths are equal.  Everything below is derived from
    // that offset rather than assuming it away, so the required gap on the wire
    // stays TS_MIN even if either pipeline depth is changed.
    //
    // Leading: the last video character lands at ACTIVE_END - 1 + VIDEO_LATENCY
    // and the island's first at ISLAND_START_PX + ISLAND_LATENCY, so requiring
    // TS_MIN control characters between them gives
    //
    //   ISLAND_START_PX = ACTIVE_END + TS_MIN + VIDEO_LATENCY - ISLAND_LATENCY
    //
    // Trailing: the island's last character is at
    // ISLAND_START_PX + ISLAND_LATENCY + 3 + 32*N, and the next line's video
    // guard band begins at H_TOTAL + VIDEO_GB + VIDEO_LATENCY, so
    //
    //   32*N <= H_TOTAL - ACTIVE_END - 2*TS_MIN - 4
    // -----------------------------------------------------------------------
    localparam integer VIDEO_GB         = 2;                       // Sec 5.2.2
    localparam integer ACTIVE_END       = VIDEO_GB + H_ACTIVE;

    localparam integer ISLAND_START_PX  = ACTIVE_END + TS_MIN +
                                          VIDEO_LATENCY - ISLAND_LATENCY;

    // Longest island that still leaves TS_MIN of control before the next
    // video data period.  The sources may push at most this many packets a
    // line; hdmi_data_island holds MAX_PACKETS.
    localparam integer N_FIT_RAW = (H_TOTAL - ACTIVE_END - (2 * TS_MIN) - 4) / 32;

    // The mode is usable at all only if a full MAX_PACKETS island fits.
    wire geometry_ok = (N_FIT_RAW >= MAX_PACKETS);

    // -----------------------------------------------------------------------
    // Pixel and line counters
    // -----------------------------------------------------------------------
    reg [9:0] hcnt, vcnt;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            hcnt <= 10'd0;
            vcnt <= 10'd0;
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= 10'd0;
            vcnt <= (vcnt == V_TOTAL - 1) ? 10'd0 : vcnt + 10'd1;
        end else begin
            hcnt <= hcnt + 10'd1;
        end
    end

    assign hcount      = hcnt;
    assign vcount      = vcnt;

    // -----------------------------------------------------------------------
    // Synchronisation and video enable
    //
    // Both syncs run on every line, including the vertical blanking lines, so
    // a sink locks to the vertical cadence continuously.  Video data -- and
    // therefore the video guard band -- only exists on the active lines.
    //
    // In a progressive CEA-861 format both vsync edges coincide with an
    // hsync leading edge; a receiver tells progressive from interlaced (whose
    // odd field puts vsync half a line off) by that phase, so a vsync that
    // switches anywhere else can make it keep re-detecting the format.  The
    // vertical line count is therefore referenced to the hsync leading edge:
    // vsync opens at HS_START of line VS_L0 and closes at HS_START of VS_L1.
    // -----------------------------------------------------------------------
    localparam integer HS_START = ACTIVE_END + H_FRONT;
    localparam integer VS_L0    = V_ACTIVE + V_FRONT;
    localparam integer VS_L1    = VS_L0 + V_SYNC_W;

    assign hsync = (hcnt >= HS_START) && (hcnt < (HS_START + H_SYNC_W));

    assign vsync = ((vcnt > VS_L0) || ((vcnt == VS_L0) && (hcnt >= HS_START))) &&
                   ((vcnt < VS_L1) || ((vcnt == VS_L1) && (hcnt <  HS_START)));

    assign video_led = (hcnt < VIDEO_GB) && (vcnt < V_ACTIVE);
    assign video_act = (hcnt >= VIDEO_GB) && (hcnt < ACTIVE_END) &&
                       (vcnt < V_ACTIVE);

    // -----------------------------------------------------------------------
    // Packets (local change: upstream queues them here)
    //
    // Upstream keeps an 8-deep FIFO of whole packets (3 block RAMs) and
    // commits up to N_FIT of them into hdmi_data_island 32 pixels before the
    // island.  In this design the sources push at fixed pixels near the start
    // of every line, never more than MAX_PACKETS of them, and the line's own
    // island always sends them all, so nothing ever waits for a later line.
    // The sources therefore push straight into hdmi_data_island's slots, and
    // the previous line's island has finished (it ends near pixel 834) long
    // before they do.
    //
    // Island start: a one-cycle pulse at ISLAND_START_PX, suppressed when no
    // packet was pushed: Sec 5.2.3.2 requires at least one packet, so an
    // empty line must produce no island rather than a 4-pixel one.
    // -----------------------------------------------------------------------
    assign island_start = (hcnt == ISLAND_START_PX) && pkt_pending && geometry_ok;

    // -----------------------------------------------------------------------
    // Preambles (Sec 5.2.1.1, Table 5-2)
    //
    // The last 8 characters of the control period before a video data period
    // carry CTL0..3 = 1,0,0,0, and those before a data island carry 1,0,1,0.
    // Both live in the tS,min = 12 control characters the geometry above
    // already reserves, so they only have to be placed, not made room for.
    //
    // The video preamble ends the line *before* an active line, so it runs on
    // the last line of the frame (next line is 0) and on every active line but
    // the last.  The island preamble is only sent when island_start will fire;
    // pkt_pending is settled from the last push, long before it opens.
    // -----------------------------------------------------------------------
    localparam integer PREAMBLE = 8;

    wire next_line_active = (vcnt == V_TOTAL - 1) || (vcnt < V_ACTIVE - 1);

    wire video_pre  = (hcnt >= H_TOTAL - PREAMBLE) && next_line_active;
    wire island_pre = (hcnt >= ISLAND_START_PX - PREAMBLE) &&
                      (hcnt <  ISLAND_START_PX) &&
                      pkt_pending && geometry_ok;

    assign ctl = video_pre  ? 4'b0001 :
                 island_pre ? 4'b0101 : 4'b0000;

endmodule

`default_nettype wire
