// ============================================================================
//  sd_defs.vh -- SD SPI command set, the one copy (sd_loader and sd_blk).
//  `include inside a module body (repo-relative path, like uart_defs.vh).
//  SDHC/SDXC only: the argument is a block address.
// ============================================================================
localparam [2:0] CMD0 = 0, CMD8 = 1, CMD55 = 2, ACMD41 = 3, CMD17 = 4, CMD24 = 5;

function [47:0] cmdw(input [2:0] p, input [31:0] l);
    case (p)
        CMD0:   cmdw = {8'h40, 32'h0,        8'h95};
        CMD8:   cmdw = {8'h48, 32'h000001AA, 8'h87};
        CMD55:  cmdw = {8'h77, 32'h0,        8'h01};
        ACMD41: cmdw = {8'h69, 32'h40000000, 8'h01};
        CMD24:  cmdw = {8'h58, l,            8'h01};
        default:cmdw = {8'h51, l,            8'h01};   // CMD17
    endcase
endfunction
