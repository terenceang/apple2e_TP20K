// ============================================================================
//  hdmi_data_island.v -- HDMI data island packet scheduler
//  Target: Sipeed Tang Nano 20K, Gowin Yosys flow.  Verilog-2001.
//
//  References:
//    HDMI 1.3 Sec 5.2.3.2  Island Placement and Duration
//                Sec 5.2.3.3  Data Island Guard Bands
//                Sec 5.2.3.4  Data Island Packet Construction
//                Table 5-3    tS,min = 12 control characters
//                Table 5-6    Data Island Leading/Trailing Guard Band values
//                Figure 5-4  Data Island Packet and ECC Structure
//
//  Island shape (Sec 5.2.3.2, 5.2.3.3):
//
//      <leading DGB> <packet 0> ... <packet N-1> <trailing DGB>
//          2 px            32 px each                   2 px
//
//  so an island is 4 + 32*N pixels, and the spec minimum of 36 pixels is
//  exactly N == 1.  "Islands shall contain an integer number of packets ...
//  limited to 18 packets or fewer."
//
//  Guard bands: channel 0 sends the TERC4 word 0xC..0xF selected by
//  {VSYNC, HSYNC}; channels 1 and 2 send the fixed pattern 0100110011, which
//  is deliberately *not* a TERC4 code (it is the complement of the 0x8 code)
//  because a guard band is a fixed 10-bit pattern, not TERC4 data.  That
//  pattern already lives in hdmi_tmds_encoder.v's data_guard_code(); this
//  module only selects TMDS_DGB, and the encoder takes {VSYNC, HSYNC} from
//  its control input.
//
//  Packet slots: the caller latches packets with pkt_valid before asserting
//  island_start, and the island is then self-contained.  One hdmi_packet_ecc
//  engine per slot, each wired to its own latched header and subpackets, so
//  every packet's BCH parity accumulates in parallel with the whole island
//  rather than being serialised through one engine.
//
//  Latency: the tmds_mode / ch*_data outputs are combinational, so
//  they reach tmds in the two cycles hdmi_tmds_encoder takes, i.e. the first
//  leading-guard-band symbol appears three clocks after island_start is
//  sampled.  They are deliberately *not* registered: registering them would add
//  a cycle that the guard bands do not share, which would make the HSYNC/VSYNC
//  bits in the island body one pixel later than the same bits in the guard
//  bands that bracket it.  Sec 5.2.3.1 requires the sync to ride ch0 D0/D1 for
//  every pixel of the island, so a sink that takes its sync from the guard
//  bands would see the transition one pixel early.  sim/tb_data_island.v checks
//  the alignment end to end by decoding the encoder output.
// ============================================================================

`default_nettype none
`include "src/hdmi/hdmi_defs.vh"

module hdmi_data_island #(
    // Ceiling on packets per island.  The real limit is the blanking interval,
    // not this parameter: the caller must fit 4 + 32*N pixels inside the
    // horizontal blanking interval with tS,min (12) control characters on each
    // side.  640x480p60 fits 4, 720x480p60 fits 3.
    parameter integer MAX_PACKETS = 3
) (
    input  wire        clk_pixel,
    input  wire        rst_n,

    // Live sync levels.  They ride ch0 D0/D1 for the whole island and also
    // select the channel 0 guard band word.
    input  wire        hsync,
    input  wire        vsync,

    // -----------------------------------------------------------------------
    // Packet commit interface.  The caller latches packets into slots 0,1,2...
    // and slot 0 is transmitted first.
    // -----------------------------------------------------------------------
    input  wire        pkt_valid,      // pulse: latch the packet inputs
    input  wire [23:0]  pkt_header,
    input  wire [223:0] pkt_body,      // subpacket k in [56k +: 56]
    output reg  [4:0]  pkt_count,      // slots filled

    // Start transmitting the island.  Runs to completion without further input.
    input  wire        island_start,

    // -----------------------------------------------------------------------
    // Outputs, all registered and mutually aligned.
    // -----------------------------------------------------------------------
    // island_mode is registered (it tracks the wire, not the generator);
    // the data outputs are combinational.  See the latency note at the top.
    output reg         island_mode,    // 1 anywhere inside the island
    // TMDS_TERC4 in the body, TMDS_DGB in the guard bands (where the
    // encoder takes {vsync, hsync} from its control input), else TMDS_CTRL.
    output wire [2:0]  tmds_mode,
    output wire [3:0]  ch0_data,
    output wire [3:0]  ch1_data,
    output wire [3:0]  ch2_data
);

    // -----------------------------------------------------------------------
    // Packet slot storage
    //
    // Slots are filled by pkt_valid and consumed by island_start, which also
    // clears the count so the next island starts empty.  The caller must latch
    // at least one packet before starting: Sec 5.2.3.2 requires an island to
    // carry at least one packet, and a zero-packet island would degenerate to
    // the 36-pixel minimum with no body at all.
    // -----------------------------------------------------------------------
    reg [23:0]  hdr  [0:MAX_PACKETS-1];
    reg [223:0] body [0:MAX_PACKETS-1];

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            pkt_count <= 5'd0;
        end else if (island_start) begin
            pkt_count <= 5'd0;
        end else if (pkt_valid) begin
            if (pkt_count < MAX_PACKETS) begin
                hdr [pkt_count] <= pkt_header;
                body[pkt_count] <= pkt_body;
                pkt_count     <= pkt_count + 5'd1;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Island pixel counter.  total is latched at island_start so the island
    // length is fixed for its whole duration: 4 guard band pixels plus 32 per
    // packet.  The 10-bit width covers the spec maximum of 18 packets (580).
    //
    // pxl is the island pixel index *before* the one currently being driven:
    // pxl_c is the pixel on the output this cycle, and pxl is loaded with 0 at
    // island_start so pxl_c walks 0, 1, 2 ... one cycle behind the register.
    // That is what lets pixel 0 be driven combinationally in the same cycle
    // island_start is asserted, which is what keeps the island on the same
    // two-cycle pipeline as the video path (see the latency note at the top).
    // -----------------------------------------------------------------------
    localparam [9:0] LEAD_PX  = 10'd2;
    localparam [9:0] BODY_OFF = 10'd2;
    localparam [9:0] PKT_PX   = 10'd32;

    reg        running;
    reg [9:0]  pxl;        // 0 .. total-1, one behind the output
    reg [9:0]  total;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            running <= 1'b0;
            pxl     <= 10'd0;
            total   <= 10'd0;
        end else if (island_start) begin
            running <= 1'b1;
            pxl     <= 10'd0;
            total   <= 10'd4 + (PKT_PX * pkt_count);
        end else if (running) begin
            if (pxl + 10'd1 >= total) begin
                running <= 1'b0;
            end else begin
                pxl <= pxl + 10'd1;
            end
        end
    end

    // Pixel index and length on the outputs this cycle.  During the island_start
    // cycle the registers still hold the previous island's state, so both are
    // overridden from the live island_start / pkt_count inputs.
    wire [9:0] pxl_c   = running ? (pxl + 10'd1) : 10'd0;
    wire [9:0] total_c = running ? total : (10'd4 + (PKT_PX * pkt_count));
    wire       run_any = running || island_start;

    wire in_lead  = run_any && (pxl_c <  LEAD_PX);
    wire in_body  = run_any && (pxl_c >= BODY_OFF) && (pxl_c < (total_c - 10'd2));
    wire in_trail = run_any && (pxl_c >= (total_c - 10'd2)) && (pxl_c < total_c);

    // Island pixel -> packet slot and pixel-within-packet.
    wire [9:0] body_pxl = pxl_c - BODY_OFF;
    wire [4:0] sub_pxl  = body_pxl[4:0];
    wire [4:0] slot     = body_pxl[9:5];       // body_pxl / 32

    // -----------------------------------------------------------------------
    // Per-slot BCH engines.  Each is wired to its own latched packet, so all
    // slots step in parallel for the whole island.
    // -----------------------------------------------------------------------
    wire [4*MAX_PACKETS-1:0] all_ch0;
    wire [4*MAX_PACKETS-1:0] all_ch1;
    wire [4*MAX_PACKETS-1:0] all_ch2;

    genvar g;
    generate
        for (g = 0; g < MAX_PACKETS; g = g + 1) begin : g_slot
            // hdmi_packet_ecc's pixel counter is a register, while pxl_c is the
            // pixel on the outputs this cycle, so pkt_start is asserted on the
            // pixel *before* the packet's first body pixel: the edge at its end
            // loads the engine's counter to 0, which is then what drives body
            // pixel 0 of slot g.  pkt_active then spans all 32 body pixels,
            // advancing the counter once per pixel.
            wire pkt_start  = run_any && (pxl_c == (PKT_PX * g + 10'd1));
            wire pkt_active = run_any && (pxl_c >= (PKT_PX * g + 10'd2)) &&
                                       (pxl_c <=  (PKT_PX * g + 10'd33));

            hdmi_packet_ecc u_ecc (
                .clk_pixel     (clk_pixel),
                .rst_n         (rst_n),
                .island_start  (pkt_start),
                .island_active (pkt_active),
                .hsync         (hsync),
                .vsync         (vsync),
                .header        (hdr[g]),
                .body          (body[g]),
                .ch0_data      (all_ch0[4*g +: 4]),
                .ch1_data      (all_ch1[4*g +: 4]),
                .ch2_data      (all_ch2[4*g +: 4])
            );
        end
    endgenerate

    // Select whichever engine owns the current body pixel.
    reg [3:0] m_ch0, m_ch1, m_ch2;
    integer k;
    always @(*) begin
        m_ch0 = 4'b0000;
        m_ch1 = 4'b0000;
        m_ch2 = 4'b0000;
        for (k = 0; k < MAX_PACKETS; k = k + 1) begin
            if (slot == k) begin
                m_ch0 = all_ch0[4*k +: 4];
                m_ch1 = all_ch1[4*k +: 4];
                m_ch2 = all_ch2[4*k +: 4];
            end
        end
    end

    // -----------------------------------------------------------------------
    // Combinational outputs
    //
    // These drive hdmi_tmds_encoder's mode and data inputs directly, taking the
    // encoder's two cycles to reach the tmds pins -- the same two cycles the
    // video path takes, so video, control and island symbols all stay aligned
    // with the sync bits that select them.
    // -----------------------------------------------------------------------
    assign tmds_mode = in_body              ? `TMDS_TERC4 :
                       (in_lead || in_trail) ? `TMDS_DGB   : `TMDS_CTRL;

    // Ch0 D3 marks island framing (Figure 5-3): 0 on the island's first body
    // character, 1 on every other one.  Without it a sink cannot tell where
    // the packets start and drops them -- and with them HDMI mode.
    assign ch0_data = in_body ? {(body_pxl != 10'd0), m_ch0[2:0]} : 4'b0000;
    assign ch1_data = in_body ? m_ch1 : 4'b0000;
    assign ch2_data = in_body ? m_ch2 : 4'b0000;

    // -----------------------------------------------------------------------
    // island_mode: "an island symbol is on the wire right now"
    //
    // One island pixel is being generated when run_any is high and pxl_c is
    // inside the island.  That signal is delayed by the encoder's two cycles
    // here, so island_mode is high exactly while the island occupies the link
    // rather than while it is being generated.  A top-level scheduler -- or a
    // sink-side monitor -- can trust it and never mis-trim a guard band.
    // -----------------------------------------------------------------------
    wire island_pixel = run_any && (pxl_c < total_c);

    reg island_mode_d1;

    always @(posedge clk_pixel) begin
        if (!rst_n) begin
            island_mode_d1 <= 1'b0;
            island_mode    <= 1'b0;
        end else begin
            island_mode_d1 <= island_pixel;
            island_mode    <= island_mode_d1;
        end
    end

endmodule

`default_nettype wire
