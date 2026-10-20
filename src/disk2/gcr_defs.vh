// src/disk2/gcr_defs.vh -- the 6-and-2 GCR tables, shared by the card and the store
//
// Included by src/disk2/disk2_card.v (which encodes a sector into the track's
// data field) and src/disk2/disk2_store.v (which decodes a written field back
// into a sector).  They must agree byte for byte, so there is one copy of each
// table and both `include this file, exactly as the RAM and ROM paths share
// src/hdmi/hdmi_defs.vh.
//
// The encoding table maps a 6-bit value to one of the 64 disk bytes that carry
// it.  A valid disk byte has at least two ones in each nibble and no more than
// two zero bits in a row, so the drive's data separator can find the bit cells
// without a PLL locked to the media rotation.  The 64 values that satisfy that
// are the 64 entries below; the two nibbles are independent, so the table is
// just the cross product of two 32-entry halves, which is what it looks like.
//
// A sector's data field, and the layout this pair implements
// ---------------------------------------------------------
// A DOS 3.3 16-sector data field is 343 disk bytes and carries a 256-byte
// sector, so the field has 343 x 8 = 2744 media bits for 2048 data bits.  The
// expansion is six-and-two: 86 chunks of three bytes, each yielding four
// six-bit values where the fourth is the parity of the other three.
//
// The 343 disk bytes are 342 six-bit values and a checksum, and the 342 values
// carry all 256 bytes losslessly:
//
//   position 0..85    the low two bits of three sector bytes: sector bytes
//                     172+k, 86+k and k.  86 x 3 = 258 pairs, which is every
//                     low-two-bit pair there is; the pair from byte 257 does
//                     not exist and is the zero pair, which is why the 86th
//                     value's top pair is $0.
//   position 86..341  the top six bits of sector byte k, one value each
//   position 342      the checksum: position 341's group again, with no XOR
//
// 86 + 256 + 1 = 343.  Within a pair the group's more significant bit is the
// sector byte's bit 1, and a value is the group at that position XORed with the
// group before it -- the chain runs over the *groups*, so the value before an
// auxiliary position is an auxiliary group of three pairs, and the value before
// the first data position is one of those.  A real RWTS undoes the chain by
// XORing the disk bytes as it reads them, which telescopes back to the group at
// each position.
//
// What this does *not* reproduce is the bit-level shuffle a real drive does
// inside the last 85 bytes, where the final data bits ride along with the
// parity bytes and the $AA mask.  Nothing above this card observes it: RWTS
// finds the data field by its $D5 $AA $AD address mark, reads 342 bytes, and
// checks the $DE $AA $EB tail after it -- it does not verify the data field's
// parity bytes at all, which is why a drive's 6-and-2 parity exists to help
// the data separator rather than the ROM.  The field length, the marks and the
// tail are reproduced exactly, because those are what the ROM does check.

// No include guard: the two functions below are module-scope declarations, and
// each including module needs its own copy.  A guard would hand the first
// module's copy to the second and leave that module with no functions at all.

// The 6-bit data value -> disk byte table.  This is the translation the drive's
// PROM does, not a lookup of the disk alphabet: a sector byte's top six bits are
// an arbitrary value in 0..63 and the table maps each of the 64 to the disk byte
// that carries it, which is the whole point of 6-and-2 encoding.  Only the top
// six bits travel this way; the low two go in the low-bits region below.
//
// The standard table (AppleWin's ms_DiskByte), and it has to be exactly right:
// one entry being wrong is invisible until a sector happens to hold that data
// value, at which point those bytes encode to a disk byte outside the set of 64
// and a real drive's data separator would lose sync on them.  Note what is not
// in it: $D5, $AA, $AD and $96's neighbours cannot come out of a data field, so
// the $D5 $AA $AD data mark and the $DE $AA $EB tail cannot be found inside one.
function [7:0] gcr_encode(input [5:0] v);
    begin
        case (v)
            6'h00: gcr_encode = 8'h96; 6'h01: gcr_encode = 8'h97;
            6'h02: gcr_encode = 8'h9A; 6'h03: gcr_encode = 8'h9B;
            6'h04: gcr_encode = 8'h9D; 6'h05: gcr_encode = 8'h9E;
            6'h06: gcr_encode = 8'h9F; 6'h07: gcr_encode = 8'hA6;
            6'h08: gcr_encode = 8'hA7; 6'h09: gcr_encode = 8'hAB;
            6'h0A: gcr_encode = 8'hAC; 6'h0B: gcr_encode = 8'hAD;
            6'h0C: gcr_encode = 8'hAE; 6'h0D: gcr_encode = 8'hAF;
            6'h0E: gcr_encode = 8'hB2; 6'h0F: gcr_encode = 8'hB3;
            6'h10: gcr_encode = 8'hB4; 6'h11: gcr_encode = 8'hB5;
            6'h12: gcr_encode = 8'hB6; 6'h13: gcr_encode = 8'hB7;
            6'h14: gcr_encode = 8'hB9; 6'h15: gcr_encode = 8'hBA;
            6'h16: gcr_encode = 8'hBB; 6'h17: gcr_encode = 8'hBC;
            6'h18: gcr_encode = 8'hBD; 6'h19: gcr_encode = 8'hBE;
            6'h1A: gcr_encode = 8'hBF; 6'h1B: gcr_encode = 8'hCB;
            6'h1C: gcr_encode = 8'hCD; 6'h1D: gcr_encode = 8'hCE;
            6'h1E: gcr_encode = 8'hCF; 6'h1F: gcr_encode = 8'hD3;
            6'h20: gcr_encode = 8'hD6; 6'h21: gcr_encode = 8'hD7;
            6'h22: gcr_encode = 8'hD9; 6'h23: gcr_encode = 8'hDA;
            6'h24: gcr_encode = 8'hDB; 6'h25: gcr_encode = 8'hDC;
            6'h26: gcr_encode = 8'hDD; 6'h27: gcr_encode = 8'hDE;
            6'h28: gcr_encode = 8'hDF; 6'h29: gcr_encode = 8'hE5;
            6'h2A: gcr_encode = 8'hE6; 6'h2B: gcr_encode = 8'hE7;
            6'h2C: gcr_encode = 8'hE9; 6'h2D: gcr_encode = 8'hEA;
            6'h2E: gcr_encode = 8'hEB; 6'h2F: gcr_encode = 8'hEC;
            6'h30: gcr_encode = 8'hED; 6'h31: gcr_encode = 8'hEE;
            6'h32: gcr_encode = 8'hEF; 6'h33: gcr_encode = 8'hF2;
            6'h34: gcr_encode = 8'hF3; 6'h35: gcr_encode = 8'hF4;
            6'h36: gcr_encode = 8'hF5; 6'h37: gcr_encode = 8'hF6;
            6'h38: gcr_encode = 8'hF7; 6'h39: gcr_encode = 8'hF9;
            6'h3A: gcr_encode = 8'hFA; 6'h3B: gcr_encode = 8'hFB;
            6'h3C: gcr_encode = 8'hFC; 6'h3D: gcr_encode = 8'hFD;
            6'h3E: gcr_encode = 8'hFE; 6'h3F: gcr_encode = 8'hFF;
            default: gcr_encode = 8'hFF;   // unreachable: 6 bits are 0..63
        endcase
    end
endfunction

// The inverse, for decoding a written data field.  Every value 0..63 has a
// disk byte, so there is no "impossible" answer here: a byte that is not one of
// the 64 decodes to 6'h3C, which matters only to a caller that checks legality,
// which the store's write path does not -- it decodes what the drive just read
// off the media.
function [5:0] gcr_decode(input [7:0] v);
    begin
        case (v)
            8'h96: gcr_decode = 6'h00; 8'h97: gcr_decode = 6'h01;
            8'h9A: gcr_decode = 6'h02; 8'h9B: gcr_decode = 6'h03;
            8'h9D: gcr_decode = 6'h04; 8'h9E: gcr_decode = 6'h05;
            8'h9F: gcr_decode = 6'h06; 8'hA6: gcr_decode = 6'h07;
            8'hA7: gcr_decode = 6'h08; 8'hAB: gcr_decode = 6'h09;
            8'hAC: gcr_decode = 6'h0A; 8'hAD: gcr_decode = 6'h0B;
            8'hAE: gcr_decode = 6'h0C; 8'hAF: gcr_decode = 6'h0D;
            8'hB2: gcr_decode = 6'h0E; 8'hB3: gcr_decode = 6'h0F;
            8'hB4: gcr_decode = 6'h10; 8'hB5: gcr_decode = 6'h11;
            8'hB6: gcr_decode = 6'h12; 8'hB7: gcr_decode = 6'h13;
            8'hB9: gcr_decode = 6'h14; 8'hBA: gcr_decode = 6'h15;
            8'hBB: gcr_decode = 6'h16; 8'hBC: gcr_decode = 6'h17;
            8'hBD: gcr_decode = 6'h18; 8'hBE: gcr_decode = 6'h19;
            8'hBF: gcr_decode = 6'h1A; 8'hCB: gcr_decode = 6'h1B;
            8'hCD: gcr_decode = 6'h1C; 8'hCE: gcr_decode = 6'h1D;
            8'hCF: gcr_decode = 6'h1E; 8'hD3: gcr_decode = 6'h1F;
            8'hD6: gcr_decode = 6'h20; 8'hD7: gcr_decode = 6'h21;
            8'hD9: gcr_decode = 6'h22; 8'hDA: gcr_decode = 6'h23;
            8'hDB: gcr_decode = 6'h24; 8'hDC: gcr_decode = 6'h25;
            8'hDD: gcr_decode = 6'h26; 8'hDE: gcr_decode = 6'h27;
            8'hDF: gcr_decode = 6'h28; 8'hE5: gcr_decode = 6'h29;
            8'hE6: gcr_decode = 6'h2A; 8'hE7: gcr_decode = 6'h2B;
            8'hE9: gcr_decode = 6'h2C; 8'hEA: gcr_decode = 6'h2D;
            8'hEB: gcr_decode = 6'h2E; 8'hEC: gcr_decode = 6'h2F;
            8'hED: gcr_decode = 6'h30; 8'hEE: gcr_decode = 6'h31;
            8'hEF: gcr_decode = 6'h32; 8'hF2: gcr_decode = 6'h33;
            8'hF3: gcr_decode = 6'h34; 8'hF4: gcr_decode = 6'h35;
            8'hF5: gcr_decode = 6'h36; 8'hF6: gcr_decode = 6'h37;
            8'hF7: gcr_decode = 6'h38; 8'hF9: gcr_decode = 6'h39;
            8'hFA: gcr_decode = 6'h3A; 8'hFB: gcr_decode = 6'h3B;
            8'hFC: gcr_decode = 6'h3C; 8'hFD: gcr_decode = 6'h3D;
            8'hFE: gcr_decode = 6'h3E; 8'hFF: gcr_decode = 6'h3F;
            default: gcr_decode = 6'h3C;   // not one of the 64 disk bytes
        endcase
    end
endfunction

// The 4-and-4 encoding an address field uses: one byte's worth of bits becomes
// two disk bytes, each with a 1 in every other bit, so the field can be read
// without a mark.  RWTS *decodes* the address field, so raw bytes there would be
// read as the wrong volume, track, sector and checksum.
//
// The first disk byte is the byte's bits shifted down one with $AA forced in,
// the second is the byte itself with $AA forced in, and the decode takes the
// shifted first byte's bits where the second has a 0.  The top bit does not
// survive the round trip -- it comes back as bit 6 -- which costs nothing: an
// address field holds a volume, a track, a sector and their XOR, all below $80.
function [7:0] a44_hi(input [7:0] v);
    begin
        a44_hi = {1'b1, v[7], 1'b1, v[5], 1'b1, v[3], 1'b1, v[1]};
    end
endfunction

function [7:0] a44_lo(input [7:0] v);
    begin
        a44_lo = {1'b1, v[6], 1'b1, v[4], 1'b1, v[2], 1'b1, v[0]};
    end
endfunction

// The inverse: the first byte's bit where the second has a 0, and vice versa.
function [7:0] a44_decode(input [7:0] hi, input [7:0] lo);
    begin
        a44_decode = {hi[6] & lo[7], hi[5] & lo[6], hi[4] & lo[5],
                      hi[3] & lo[4], hi[2] & lo[3], hi[1] & lo[2],
                      hi[0] & lo[1], lo[0]};
    end
endfunction

// The two bits of a sector byte that ride in an auxiliary group go on the disk
// transposed: the P6 ROM and RWTS unpack a group with LSR / ROL / LSR / ROL,
// which puts the group's bit 0 into the byte's bit 1 and the group's bit 1 into
// the byte's bit 0.  So the group holds {byte bit 0, byte bit 1}.  Emitting the
// pair as it stands passes any bench that transposes on the way back and hands
// the real ROM a boot sector with its low bits wrong (the checksum only covers
// the disk bytes, so the read "succeeds").  A swap is its own inverse, so the
// store's read side (encode) and write side (decode) both call this one function.
function [1:0] gcr_pair_swap(input [1:0] v);
    begin
        gcr_pair_swap = {v[0], v[1]};
    end
endfunction

// The sector byte that source n of auxiliary position k (0..85) carries the low
// two bits of: 172+k, 86+k and k.  The first is past byte 255 for k = 85, which is
// the pair 6-and-2 drops, so a caller range-checks the result.
function [8:0] gcr_aux_src(input [1:0] n, input [8:0] k);
    begin
        case (n)
            2'd0:    gcr_aux_src = 9'd172 + k;
            2'd1:    gcr_aux_src = 9'd86  + k;
            default: gcr_aux_src = k;
        endcase
    end
endfunction

// A data field: 86 low-bits bytes, then 256 data bytes, then the checksum byte.
// 343, which is what RWTS reads and what a ProDOS-order image stores per sector.
`define GCR_AUX_N     86
`define GCR_FIELD_LEN 343
// The first disk byte of the data-byte section.
`define GCR_DATA_OFF  86
// The checksum byte, the last of the field.
`define GCR_PAR_OFF   342
