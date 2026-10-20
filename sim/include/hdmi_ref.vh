// ============================================================================
//  hdmi_ref.vh -- sink-side reference functions shared by the testbenches
//
//  `include inside a module body.  Written from the HDMI 1.3 / DVI 1.0
//  tables, independently of the RTL, so testbenches can decode and check
//  what the DUT puts on the wire.
// ============================================================================

// Table 5-5 / 5-6 fixed guard band words.
localparam [9:0] REF_VGB_02 = 10'b1011001100;  // video GB, channels 0 and 2
localparam [9:0] REF_GB_1   = 10'b0100110011;  // video GB ch1; data GB ch1, ch2

// Control characters (Sec 5.4.2): {valid, D1, D0}.
function [2:0] ctrl_dec;
    input [9:0] s;
    begin
        case (s)
            10'b1101010100: ctrl_dec = 3'b100;
            10'b0010101011: ctrl_dec = 3'b101;
            10'b0101010100: ctrl_dec = 3'b110;
            10'b1010101011: ctrl_dec = 3'b111;
            default:        ctrl_dec = 3'b000;
        endcase
    end
endfunction

// TERC4 (Table 5-31 / 5-35): {valid, D3..D0}.
function [4:0] terc4_dec;
    input [9:0] s;
    begin
        case (s)
            10'b1010011100: terc4_dec = 5'h10;
            10'b1001100011: terc4_dec = 5'h11;
            10'b1011100100: terc4_dec = 5'h12;
            10'b1011100010: terc4_dec = 5'h13;
            10'b0101110001: terc4_dec = 5'h14;
            10'b0100011110: terc4_dec = 5'h15;
            10'b0110001110: terc4_dec = 5'h16;
            10'b0100111100: terc4_dec = 5'h17;
            10'b1011001100: terc4_dec = 5'h18;
            10'b0100111001: terc4_dec = 5'h19;
            10'b0110011100: terc4_dec = 5'h1a;
            10'b1011000110: terc4_dec = 5'h1b;
            10'b1010001110: terc4_dec = 5'h1c;
            10'b1001110001: terc4_dec = 5'h1d;
            10'b0101100011: terc4_dec = 5'h1e;
            10'b1011000011: terc4_dec = 5'h1f;
            default:        terc4_dec = 5'h00;
        endcase
    end
endfunction

// Video data symbol decode, DVI 1.0 Figure 6-3.
function [7:0] tmds_dec;
    input [9:0] s;
    reg   [7:0] d;
    integer i;
    begin
        d = s[9] ? ~s[7:0] : s[7:0];
        tmds_dec[0] = d[0];
        for (i = 1; i < 8; i = i + 1)
            tmds_dec[i] = s[8] ? (d[i] ^ d[i-1]) : ~(d[i] ^ d[i-1]);
    end
endfunction

// HDMI BCH generator G(x) = 1 + x^6 + x^7 + x^8 (Figure 5-5), seeded with 0
// and stepped LSB first over the first nbits of word.  ECC of a payload is
// bch(payload, 24 or 56); the syndrome of a whole block, parity included, is
// bch(block, 32 or 64) and is 0 for a valid codeword.
function [7:0] bch;
    input [63:0]  word;
    input integer nbits;
    integer i;
    begin
        bch = 8'h00;
        for (i = 0; i < nbits; i = i + 1)
            bch = (bch >> 1) ^ ((bch[0] ^ word[i]) ? 8'h83 : 8'h00);
    end
endfunction
