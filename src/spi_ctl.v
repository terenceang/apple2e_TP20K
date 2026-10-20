// SPI link to the ESP32 companion: mounts disk images and flushes written tracks.
//
// The FPGA is the SPI master (src/spi_master.v, mode 0).  The ESP32 slave cannot
// answer a command in the same frame it receives it (its DMA buffer is armed
// before the first clock), so every request is two frames, with CS high between:
//
//   command frame   [op, args...]                    (response bytes ignored)
//   poll frame      [00 x N]  slave answers A5 then the payload; anything but
//                   A5 in byte 0 means "not ready yet": CS high, wait, retry
//
//   op 01 PING        -> A5 5A
//   op 02 STAT        -> A5 gen0 gen1 flags     gen = image generation of the
//                        drive (0 = no image; changes when a new image is
//                        mounted), flags bit d = drive d is writable
//   op 10 READ_TRK d t-> A5 + 7040 bytes        the nibble track (trk_defs.vh)
//   op 20 WRITE_TRK d t + 7040 bytes            one frame, no response; the
//                        ESP32 decodes the track back into the image
//
// The FPGA polls STAT every ~10 ms.  A drive whose generation differs from the
// one it last fetched is reloaded track by track into SDRAM through the card's
// x_* port (present is dropped while that happens, so the card never plays a
// half-loaded image).  A track the card has written is flushed with WRITE_TRK
// once the head leaves it or the motor stops.  With no ESP32 attached nothing
// ever answers A5, so both drives stay empty, as today.
//
// Each byte is started only when the previous SDRAM word has been served, so a
// busy arbiter slows the frame down instead of dropping data (SCK simply pauses
// between bytes, which the slave tolerates until CS rises).

`default_nettype none

module spi_ctl #(
    parameter integer NTRK       = 35,
    parameter integer BOOT_CLKS  = 13_500_000,   // 0.5 s for the ESP32 to boot
    parameter integer STAT_CLKS  = 270_000,      // 10 ms between STATs
    parameter integer GAP_CLKS   = 4_000,        // CS high between frames
    parameter integer RETRY_CLKS = 27_000,       // 1 ms between polls
    parameter integer MAX_TRIES  = 4000,
    parameter integer HALF       = 2
) (
    input  wire        clk,
    input  wire        reset,

    output wire        spi_sck,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output reg         spi_cs_n,

    // From the card
    input  wire        head_drv,
    input  wire [5:0]  head_trk,
    input  wire        motor,
    input  wire        wr_evt,
    input  wire        wr_drv,
    input  wire [5:0]  wr_trk,

    // To the card
    output reg  [1:0]  drv_present,
    output reg  [1:0]  drv_writable,
    output reg         x_req,
    output reg         x_we,
    output reg  [18:0] x_addr,
    output reg  [15:0] x_wdata,
    input  wire [15:0] x_rdata,
    input  wire        x_ack,

    output reg         link_up
);

    `include "src/disk2/trk_defs.vh"

    // ---- byte engine ----
    reg        sm_start = 1'b0;
    reg  [7:0] sm_tx    = 8'd0;
    wire [7:0] sm_rx;
    wire       sm_busy, sm_done;
    spi_master #(.HALF(HALF)) u_sm (
        .clk(clk), .reset(reset), .start(sm_start), .tx(sm_tx), .rx(sm_rx),
        .busy(sm_busy), .done(sm_done), .sck(spi_sck), .mosi(spi_mosi), .miso(spi_miso));

    localparam [1:0] OP_PING = 2'd0, OP_STAT = 2'd1, OP_READ = 2'd2, OP_WRITE = 2'd3;

    localparam [4:0]
        ST_BOOT      = 5'd0,  ST_IDLE      = 5'd1,  ST_CS        = 5'd2,  ST_CSW       = 5'd3,
        ST_CMD_SEND  = 5'd4,  ST_CMD_WAIT  = 5'd5,  ST_GAP       = 5'd6,  ST_POLL_SEND = 5'd7,
        ST_POLL_WAIT = 5'd8,  ST_RESP_SEND = 5'd9,  ST_RESP_WAIT = 5'd10, ST_XW        = 5'd11,
        ST_NEXT      = 5'd12, ST_FIN       = 5'd13, ST_WR_RD     = 5'd14, ST_WR_RDW    = 5'd15,
        ST_WR_B0     = 5'd16, ST_WR_B1     = 5'd17;

    reg [4:0]  st = ST_BOOT;
    reg [4:0]  nxt = ST_IDLE;
    reg [24:0] timer;                   // no initialiser: reset loads BOOT_CLKS
    reg [1:0]  op = OP_PING;
    reg [1:0]  cmd_n = 2'd1;
    reg [1:0]  ci = 2'd0;
    reg [7:0]  cmd0 = 8'd0, cmd1 = 8'd0, cmd2 = 8'd0;
    reg        gap_cmd = 1'b0;          // after the gap: 1 = send a command, 0 = poll
    reg [11:0] tries = 12'd0;
    reg [12:0] ri = 13'd0, wi = 13'd0;
    reg [12:0] resp_n = 13'd1;
    reg [7:0]  hold = 8'd0;
    reg [15:0] wdat = 16'd0;
    reg        last = 1'b0;

    reg [7:0]  gen0_seen = 8'd0, gen1_seen = 8'd0, fgen0 = 8'd0, fgen1 = 8'd0;
    reg [1:0]  flags_seen = 2'd0;
    reg        fdrv = 1'b0;
    reg [5:0]  ftrk = 6'd0;
    reg        wdrv = 1'b0;
    reg [5:0]  wtrk = 6'd0;

    // Dirty tracks: idx = drive*35 + track
    reg [69:0] dirty = 70'd0;
    reg [6:0]  scan  = 7'd0;
    wire [6:0] wr_idx   = (wr_drv ? 7'd35 : 7'd0) + {1'b0, wr_trk};
    wire [6:0] head_idx = (head_drv ? 7'd35 : 7'd0) + {1'b0, head_trk};
    wire       scan_drv = (scan >= 7'd35);
    wire [6:0] scan_trk7 = scan_drv ? scan - 7'd35 : scan;
    wire       elig     = (scan != head_idx) || !motor;
    wire       flush_now = dirty[scan] && elig;

    wire nf0 = (gen0_seen != 8'd0) && (gen0_seen != fgen0);
    wire nf1 = (gen1_seen != 8'd0) && (gen1_seen != fgen1);
    wire need_fetch = nf0 || nf1;

    task set_cmd(input [1:0] o, input d, input [5:0] t);
        begin
            op <= o;
            ci <= 2'd0;
            case (o)
                OP_PING:  begin cmd_n <= 2'd1; cmd0 <= 8'h01; resp_n <= 13'd1; end
                OP_STAT:  begin cmd_n <= 2'd1; cmd0 <= 8'h02; resp_n <= 13'd3; end
                OP_READ:  begin cmd_n <= 2'd3; cmd0 <= 8'h10; cmd1 <= {7'd0, d}; cmd2 <= {2'd0, t};
                                resp_n <= `TRK_BYTES; end
                default:  begin cmd_n <= 2'd3; cmd0 <= 8'h20; cmd1 <= {7'd0, d}; cmd2 <= {2'd0, t};
                                resp_n <= 13'd0; end
            endcase
        end
    endtask

    wire [7:0] cmd_byte = (ci == 2'd0) ? cmd0 : (ci == 2'd1) ? cmd1 : cmd2;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            st <= ST_BOOT; nxt <= ST_IDLE; timer <= BOOT_CLKS; op <= OP_PING;
            spi_cs_n <= 1'b1; sm_start <= 1'b0; sm_tx <= 8'd0;
            drv_present <= 2'b00; drv_writable <= 2'b00;
            x_req <= 1'b0; x_we <= 1'b0; x_addr <= 19'd0; x_wdata <= 16'd0;
            link_up <= 1'b0;
            gen0_seen <= 8'd0; gen1_seen <= 8'd0; fgen0 <= 8'd0; fgen1 <= 8'd0; flags_seen <= 2'd0;
            dirty <= 70'd0; scan <= 7'd0;
            ci <= 2'd0; cmd_n <= 2'd1; cmd0 <= 8'd0; cmd1 <= 8'd0; cmd2 <= 8'd0; resp_n <= 13'd1;
            ri <= 13'd0; wi <= 13'd0; hold <= 8'd0; wdat <= 16'd0; last <= 1'b0;
            tries <= 12'd0; gap_cmd <= 1'b0; fdrv <= 1'b0; ftrk <= 6'd0; wdrv <= 1'b0; wtrk <= 6'd0;
        end else begin
            sm_start <= 1'b0;
            if (scan == 7'd69) scan <= 7'd0; else scan <= scan + 7'd1;
            case (st)
                ST_BOOT: begin
                    if (timer == 0) begin
                        st <= ST_IDLE; timer <= 25'd0;
                    end else timer <= timer - 25'd1;
                end

                ST_IDLE: begin
                    if (timer != 0) begin
                        timer <= timer - 25'd1;     // CS stays high for the gap before any frame
                    end else if (flush_now) begin
                        dirty[scan] <= 1'b0;
                        wdrv <= scan_drv; wtrk <= scan_trk7[5:0];
                        set_cmd(OP_WRITE, scan_drv, scan_trk7[5:0]);
                        nxt <= ST_CMD_SEND; st <= ST_CS;
                    end else if (link_up && need_fetch) begin
                        fdrv <= !nf0; ftrk <= 6'd0;
                        drv_present[nf0 ? 1'b0 : 1'b1] <= 1'b0;
                        set_cmd(OP_READ, !nf0, 6'd0);
                        nxt <= ST_CMD_SEND; st <= ST_CS;
                    end else begin
                        set_cmd(link_up ? OP_STAT : OP_PING, 1'b0, 6'd0);
                        nxt <= ST_CMD_SEND; st <= ST_CS;
                    end
                end

                // CS low, a few clocks of setup, then on to nxt
                ST_CS:  begin spi_cs_n <= 1'b0; timer <= 25'd8; st <= ST_CSW; end
                ST_CSW: begin
                    if (timer == 0) st <= nxt; else timer <= timer - 25'd1;
                end

                ST_CMD_SEND: if (!sm_busy && !sm_start) begin
                    sm_start <= 1'b1; sm_tx <= cmd_byte; st <= ST_CMD_WAIT;
                end
                ST_CMD_WAIT: if (sm_done) begin
                    if (ci != cmd_n - 2'd1) begin
                        ci <= ci + 2'd1; st <= ST_CMD_SEND;
                    end else if (op == OP_WRITE) begin
                        wi <= 13'd0; st <= ST_WR_RD;
                    end else begin
                        spi_cs_n <= 1'b1; timer <= GAP_CLKS; tries <= MAX_TRIES;
                        gap_cmd <= 1'b0; st <= ST_GAP;
                    end
                end

                ST_GAP: begin
                    if (timer == 0) begin
                        nxt <= gap_cmd ? ST_CMD_SEND : ST_POLL_SEND; st <= ST_CS;
                    end else timer <= timer - 25'd1;
                end

                ST_POLL_SEND: if (!sm_busy && !sm_start) begin
                    sm_start <= 1'b1; sm_tx <= 8'h00; st <= ST_POLL_WAIT;
                end
                ST_POLL_WAIT: if (sm_done) begin
                    if (sm_rx == 8'hA5) begin
                        ri <= 13'd0; last <= 1'b0; link_up <= 1'b1; st <= ST_RESP_SEND;
                    end else begin
                        spi_cs_n <= 1'b1;
                        if (tries == 12'd1) begin
                            // gave up: back off, and a READ will be retried by STAT
                            if (op == OP_PING || op == OP_STAT) link_up <= 1'b0;
                            ftrk <= 6'd0;
                            timer <= STAT_CLKS; st <= ST_IDLE;
                        end else begin
                            tries <= tries - 12'd1; timer <= RETRY_CLKS; st <= ST_GAP;
                        end
                    end
                end

                ST_RESP_SEND: if (!sm_busy && !sm_start) begin
                    sm_start <= 1'b1; sm_tx <= 8'h00; st <= ST_RESP_WAIT;
                end
                ST_RESP_WAIT: if (sm_done) begin
                    if (ri == resp_n - 13'd1) last <= 1'b1;
                    ri <= ri + 13'd1;
                    st <= ST_NEXT;
                    case (op)
                        OP_STAT: case (ri[1:0])
                            2'd0: gen0_seen <= sm_rx;
                            2'd1: gen1_seen <= sm_rx;
                            default: flags_seen <= sm_rx[1:0];
                        endcase
                        OP_READ: begin
                            if (!ri[0]) hold <= sm_rx;
                            else begin
                                x_we <= 1'b1; x_req <= 1'b1;
                                x_wdata <= {sm_rx, hold};
                                x_addr  <= trk_base(fdrv, ftrk) + {6'd0, ri[12:1], 1'b0};
                                st <= ST_XW;
                            end
                        end
                        default: ;
                    endcase
                end
                ST_XW: if (x_ack) begin x_req <= 1'b0; st <= ST_NEXT; end
                ST_NEXT: begin
                    if (last) st <= ST_FIN; else st <= ST_RESP_SEND;
                end

                ST_FIN: begin
                    spi_cs_n <= 1'b1; timer <= (op == OP_STAT) ? STAT_CLKS : GAP_CLKS;
                    case (op)
                        OP_STAT: begin
                            drv_present <= drv_present & {gen1_seen != 8'd0, gen0_seen != 8'd0};
                            st <= ST_IDLE;
                        end
                        OP_READ: begin
                            if (ftrk == NTRK - 1) begin
                                drv_present[fdrv]  <= 1'b1;
                                drv_writable[fdrv] <= flags_seen[fdrv];
                                if (fdrv) fgen1 <= gen1_seen; else fgen0 <= gen0_seen;
                                st <= ST_IDLE;
                            end else begin
                                ftrk <= ftrk + 6'd1;
                                set_cmd(OP_READ, fdrv, ftrk + 6'd1);
                                gap_cmd <= 1'b1; st <= ST_GAP;
                            end
                        end
                        default: st <= ST_IDLE;
                    endcase
                end

                // ---- WRITE_TRK data, in the command frame ----
                ST_WR_RD: begin
                    x_we <= 1'b0; x_req <= 1'b1;
                    x_addr <= trk_base(wdrv, wtrk) + {6'd0, wi[12:1], 1'b0};
                    st <= ST_WR_RDW;
                end
                ST_WR_RDW: if (x_ack) begin
                    x_req <= 1'b0; wdat <= x_rdata;
                    sm_start <= 1'b1; sm_tx <= x_rdata[7:0]; st <= ST_WR_B0;
                end
                ST_WR_B0: if (sm_done) begin
                    sm_start <= 1'b1; sm_tx <= wdat[15:8]; st <= ST_WR_B1;
                end
                ST_WR_B1: if (sm_done) begin
                    if (wi + 13'd2 >= `TRK_BYTES) begin
                        spi_cs_n <= 1'b1; timer <= GAP_CLKS; st <= ST_IDLE;
                    end else begin
                        wi <= wi + 13'd2; st <= ST_WR_RD;
                    end
                end
                default: st <= ST_IDLE;
            endcase
            if (wr_evt) dirty[wr_idx] <= 1'b1;
        end
    end
endmodule

`default_nettype wire
