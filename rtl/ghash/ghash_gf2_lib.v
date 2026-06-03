/*=============================================================================
# File Name    : ghash_gf2_lib.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Created Date : 2026-05-24
#
#=============================================================================
# Function Description:
# GF(2) arithmetic primitives for GHASH. Contains all Karatsuba-Ofman leaf
# products, recombination stages, GCM polynomial reduction, and bit reversal.
# These are self-contained combinational modules with no external dependencies.
#
#===========================================================================*/
`default_nettype wire

//----------------------------------------------------------------------------
// 128-bit bit reverse (GCM convention: bit 0 is MSB of polynomial)
//----------------------------------------------------------------------------
module ghash_bit_reverse128
(
    input  wire [127:0] i_data,
    output wire [127:0] o_data
);
genvar gr;
generate
    for (gr = 0; gr < 128; gr = gr + 1) begin : g_rev
        assign o_data[gr] = i_data[127-gr];
    end
endgenerate
endmodule

//----------------------------------------------------------------------------
// 16x16 carry-less polynomial product
//----------------------------------------------------------------------------
module gf2_clmul16
(
    input  wire [15:0] i_a,
    input  wire [15:0] i_b,
    output wire [30:0] o_p
);
wire [30:0] w_row [0:15];
wire [30:0] w_l1  [0:7];
wire [30:0] w_l2  [0:3];
wire [30:0] w_l3  [0:1];
genvar gi;
generate
    for (gi = 0; gi < 16; gi = gi + 1) begin : g_row
        assign w_row[gi] = i_a[gi] ? ({15'h0, i_b} << gi) : 31'h0;
    end
    for (gi = 0; gi < 8; gi = gi + 1) begin : g_l1
        assign w_l1[gi] = w_row[gi*2] ^ w_row[gi*2+1];
    end
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_l2
        assign w_l2[gi] = w_l1[gi*2] ^ w_l1[gi*2+1];
    end
    for (gi = 0; gi < 2; gi = gi + 1) begin : g_l3
        assign w_l3[gi] = w_l2[gi*2] ^ w_l2[gi*2+1];
    end
endgenerate
assign o_p = w_l3[0] ^ w_l3[1];
endmodule

//----------------------------------------------------------------------------
// 32-bit KOA leaf: split into three 16x16 carry-less products
//----------------------------------------------------------------------------
module gf2_32_koa_leaf16
(
    input  wire [31:0] i_a,
    input  wire [31:0] i_b,
    output wire [92:0] o_leaf_pack
);
wire [15:0] w_a0 = i_a[15:0];
wire [15:0] w_a1 = i_a[31:16];
wire [15:0] w_b0 = i_b[15:0];
wire [15:0] w_b1 = i_b[31:16];
wire [30:0] w_p0, w_p1_raw, w_p2;
assign o_leaf_pack = {w_p2, w_p1_raw, w_p0};
gf2_clmul16 u_p0 (.i_a(w_a0),          .i_b(w_b0),          .o_p(w_p0));
gf2_clmul16 u_p1 (.i_a(w_a0 ^ w_a1),   .i_b(w_b0 ^ w_b1),  .o_p(w_p1_raw));
gf2_clmul16 u_p2 (.i_a(w_a1),          .i_b(w_b1),          .o_p(w_p2));
endmodule

//----------------------------------------------------------------------------
// Recombine three 16x16 leaves into one 32x32 carry-less product
//----------------------------------------------------------------------------
module gf2_32_koa_recombine
(
    input  wire [92:0] i_leaf_pack,
    output wire [62:0] o_p
);
wire [30:0] w_p0     = i_leaf_pack[0 +: 31];
wire [30:0] w_p1_raw = i_leaf_pack[31 +: 31];
wire [30:0] w_p2     = i_leaf_pack[62 +: 31];
wire [30:0] w_p1     = w_p1_raw ^ w_p0 ^ w_p2;
assign o_p = {32'h0, w_p0} ^ {16'h0, w_p1, 16'h0} ^ {w_p2, 32'h0};
endmodule

//----------------------------------------------------------------------------
// Recombine three 32x32 products into one 64x64 carry-less product
//----------------------------------------------------------------------------
module gf2_64_koa_from32
(
    input  wire [62:0]  i_p0,
    input  wire [62:0]  i_p1_raw,
    input  wire [62:0]  i_p2,
    output wire [126:0] o_p
);
wire [62:0] w_p1 = i_p1_raw ^ i_p0 ^ i_p2;
assign o_p = {64'h0, i_p0} ^ {32'h0, w_p1, 32'h0} ^ {i_p2, 64'h0};
endmodule

//----------------------------------------------------------------------------
// Recombine three 64x64 products into one 128x128 carry-less product
//----------------------------------------------------------------------------
module gf2_128_koa_from64
(
    input  wire [126:0] i_p0,
    input  wire [126:0] i_p1_raw,
    input  wire [126:0] i_p2,
    output wire [254:0] o_p
);
wire [126:0] w_p1 = i_p1_raw ^ i_p0 ^ i_p2;
assign o_p = {128'h0, i_p0} ^ {64'h0, w_p1, 64'h0} ^ {i_p2, 128'h0};
endmodule

//----------------------------------------------------------------------------
// GCM polynomial reduction stage 1: x^128 + x^7 + x^2 + x + 1
//----------------------------------------------------------------------------
module gf2_ghash_reduce_stage1
(
    input  wire [254:0] i_p,
    output wire [133:0] o_fold
);
wire [133:0] w_base, w_h0, w_h1, w_h2, w_h7;
genvar gi;
generate
    for (gi = 0; gi < 134; gi = gi + 1) begin : g_fold1
        assign w_base[gi] = (gi < 128) ? i_p[gi] : 1'b0;
        assign w_h0[gi]   = (gi < 127) ? i_p[128+gi] : 1'b0;
        assign w_h1[gi]   = ((gi >= 1) && (gi <= 127)) ? i_p[128+gi-1] : 1'b0;
        assign w_h2[gi]   = ((gi >= 2) && (gi <= 128)) ? i_p[128+gi-2] : 1'b0;
        assign w_h7[gi]   = ((gi >= 7) && (gi <= 133)) ? i_p[128+gi-7] : 1'b0;
        assign o_fold[gi]  = w_base[gi] ^ w_h0[gi] ^ w_h1[gi] ^ w_h2[gi] ^ w_h7[gi];
    end
endgenerate
endmodule

//----------------------------------------------------------------------------
// GCM polynomial reduction stage 2 (final)
//----------------------------------------------------------------------------
module gf2_ghash_reduce_stage2
(
    input  wire [133:0] i_fold,
    output wire [127:0] o_p
);
wire [127:0] w_h0, w_h1, w_h2, w_h7;
genvar gi;
generate
    for (gi = 0; gi < 128; gi = gi + 1) begin : g_fold2
        assign w_h0[gi] = (gi < 6)                    ? i_fold[128+gi]   : 1'b0;
        assign w_h1[gi] = ((gi >= 1) && (gi <= 6))    ? i_fold[128+gi-1] : 1'b0;
        assign w_h2[gi] = ((gi >= 2) && (gi <= 7))    ? i_fold[128+gi-2] : 1'b0;
        assign w_h7[gi] = ((gi >= 7) && (gi <= 12))   ? i_fold[128+gi-7] : 1'b0;
        assign o_p[gi]  = i_fold[gi] ^ w_h0[gi] ^ w_h1[gi] ^ w_h2[gi] ^ w_h7[gi];
    end
endgenerate
endmodule
