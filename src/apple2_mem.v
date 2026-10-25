// Apple //e Memory Subsystem (RAM and ROMs) for Tang Primer 20K
// 48KB main RAM (24 SP blocks; the language card is in DDR3, src/aux_ram.v), 16KB System ROM (8 SP blocks), 4KB Character ROM (2 SP blocks)
//
// The character ROM is declared 4KB, not 8KB, because video_generator's
// char_rom_addr is 12 bits (src/video_generator.v).  Declaring 8KB only put
// two dead SP blocks on a device that is otherwise at 95% BSRAM use.  The
// dump must match: roms/apple2e_char.hex is 4096 lines, the Apple //e
// Enhanced 342-0265-A 2732.  See roms/README.md.

module apple2_system_rom (
    input  wire        clk,
    input  wire [13:0] addr, // 16KB space (0x0000 = $C000, 0x3FFF = $FFFF)
    output reg  [7:0]  dout
);
    reg [7:0] mem [0:16383];

    initial begin
        $readmemh("roms/apple2e_rom.hex", mem);
    end

    always @(posedge clk) begin
        dout <= mem[addr];
    end
endmodule


module apple2_char_rom (
    input  wire        clk,
    input  wire [11:0] addr, // 4KB, covers the whole 2732
    output reg  [7:0]  dout
);
    reg [7:0] mem [0:4095];

    initial begin
        $readmemh("roms/apple2e_char.hex", mem);
    end

    always @(posedge clk) begin
        dout <= mem[addr];
    end
endmodule


module apple2_ram_48k (   // $0000-$BFFF; addresses above are never written or used
    input  wire        clk,
    input  wire [15:0] addr,
    input  wire [7:0]  din,
    input  wire        we,
    output reg  [7:0]  dout,

    // Port B: read-only for authentic video floating bus scanner
    input  wire [15:0] addr_b,
    output reg  [7:0]  dout_b
);
    reg [7:0] mem [0:49151];
    // Simulation only (Gowin defines no SYNTHESIS macro, and loops past 2000
    // iterations are an error there).
    // synthesis translate_off
    integer i;
    initial begin
        for (i = 0; i < 49152; i = i + 1)
            mem[i] = 8'h00;
    end
    // synthesis translate_on

    always @(posedge clk) begin
        if (we)
            mem[addr] <= din;
        else
            dout <= mem[addr];
    end

    always @(posedge clk) begin
        dout_b <= mem[addr_b];
    end
endmodule
