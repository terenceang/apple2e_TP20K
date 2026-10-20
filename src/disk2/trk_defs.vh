// src/disk2/trk_defs.vh -- where a nibble track lives in the image store.
//
// Shared by src/disk2/disk2_trk.v (the card, which plays and overwrites the
// bytes) and src/spi_ctl.v (which fills them from, and flushes them to, the
// ESP32).  One copy so the two cannot disagree about a track's address.
//
// A track is TRK_BYTES = 7040 disk bytes (16 sectors x 440), in a 7168-byte
// slot (7 KB) so a slot's base is idx*7168 = (idx<<13) - (idx<<10) and the two
// drives' 70 slots (501,760 bytes) still fit in the 19-bit byte address
// disk2_store.v's sd_word_addr() uses.  The 128 spare bytes per slot are
// reserved for a bit count when WOZ images arrive.
//
// Functions, so each including module needs its own copy (as gcr_defs.vh).

`define TRK_BYTES 7040
`define TRK_COUNT 35

// Byte address of a drive's track slot within the store's bank.
function [18:0] trk_base(input drv, input [5:0] trk);
    reg [6:0]  idx;
    reg [19:0] t;
    begin
        idx      = (drv ? 7'd35 : 7'd0) + {1'b0, trk};
        t        = ({13'd0, idx} << 13) - ({13'd0, idx} << 10);
        trk_base = t[18:0];
    end
endfunction

// The SDRAM controller's word address for an even byte address (bank 1).
function [21:0] trk_word_addr(input [18:0] byte_even);
    begin
        trk_word_addr = {2'b01, 1'b0, byte_even[18:1], 1'b0};
    end
endfunction
