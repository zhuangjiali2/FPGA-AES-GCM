/*=============================================================================
# File Name    : ghash_mul_koa_pipe_fixed.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Fixed-latency pipelined GHASH GF(2^128) multiplier. Same KOA decomposition
# and GCM reduction as ghash_mul_koa_pipe, but uses a global pipe enable
# instead of per-stage val/rdy. Eliminates the fanout=840 CE bottleneck that
# limited Fmax in the val/rdy version.
#
# Pipeline: 6 stages, latency 6 cycles, throughput 1 multiply/cycle.
# Flow control only at entry (din_valid/ready) and exit (dout_valid/ready).
#
#=============================================================================
# Revision History:
# ----------------------------------------------------------------------------
# Date         | Author       | Version | Change Description
# ----------------------------------------------------------------------------
# 2026-06-03   | logic        | v1.0    | Fixed-latency version of KOA pipe
# ----------------------------------------------------------------------------
#===========================================================================*/
`default_nettype wire

module ghash_mul_koa_pipe_fixed
#(
    parameter META_WIDTH = 1
)
(
    input  wire                    i_clk        ,
    input  wire                    i_rst_n      ,

    input  wire                    i_din_valid  ,
    output wire                    o_din_ready  ,
    input  wire [127:0]            i_x          ,
    input  wire [127:0]            i_y          ,
    input  wire [META_WIDTH-1:0]   i_meta       ,

    output wire                    o_dout_valid ,
    input  wire                    i_dout_ready ,
    output wire [127:0]            o_p          ,
    output wire [META_WIDTH-1:0]   o_meta
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam STAGES = 6;

//------------------------------------------------------------
// global pipe enable
//------------------------------------------------------------
wire w_pipe_en;
reg  [STAGES-1:0] r_valid;

assign w_pipe_en   = (~r_valid[STAGES-1]) | i_dout_ready;
assign o_din_ready = w_pipe_en;
assign o_dout_valid = r_valid[STAGES-1];

//------------------------------------------------------------
// valid shift register
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_valid <= {STAGES{1'b0}};
    end else if (w_pipe_en) begin
        r_valid <= {r_valid[STAGES-2:0], i_din_valid};
    end
end

//------------------------------------------------------------
// wire: bit reverse
//------------------------------------------------------------
wire [127:0] w_x_rev;
wire [127:0] w_y_rev;

ghash_bit_reverse128 u_x_reverse (.i_data(i_x), .o_data(w_x_rev));
ghash_bit_reverse128 u_y_reverse (.i_data(i_y), .o_data(w_y_rev));

//------------------------------------------------------------
// Stage 0 registers: capture reversed operands
//------------------------------------------------------------
reg [127:0]           r_s0_x;
reg [127:0]           r_s0_y;
reg [META_WIDTH-1:0]  r_s0_meta;

always @(posedge i_clk) begin
    if (w_pipe_en && i_din_valid) begin
        r_s0_x    <= w_x_rev;
        r_s0_y    <= w_y_rev;
        r_s0_meta <= i_meta;
    end
end

//------------------------------------------------------------
// Stage 0鈫? combinational: 9 leaf 32-bit KOA splits
//------------------------------------------------------------
wire [31:0] w_a0 = r_s0_x[31:0];
wire [31:0] w_a1 = r_s0_x[63:32];
wire [31:0] w_a2 = r_s0_x[95:64];
wire [31:0] w_a3 = r_s0_x[127:96];
wire [31:0] w_b0 = r_s0_y[31:0];
wire [31:0] w_b1 = r_s0_y[63:32];
wire [31:0] w_b2 = r_s0_y[95:64];
wire [31:0] w_b3 = r_s0_y[127:96];

wire [92:0] w_leaf [0:8];

gf2_32_koa_leaf16 u_l0 (.i_a(w_a0),                         .i_b(w_b0),                         .o_leaf_pack(w_leaf[0]));
gf2_32_koa_leaf16 u_l1 (.i_a(w_a0 ^ w_a1),                  .i_b(w_b0 ^ w_b1),                  .o_leaf_pack(w_leaf[1]));
gf2_32_koa_leaf16 u_l2 (.i_a(w_a1),                         .i_b(w_b1),                         .o_leaf_pack(w_leaf[2]));
gf2_32_koa_leaf16 u_l3 (.i_a(w_a0 ^ w_a2),                  .i_b(w_b0 ^ w_b2),                  .o_leaf_pack(w_leaf[3]));
gf2_32_koa_leaf16 u_l4 (.i_a(w_a0 ^ w_a1 ^ w_a2 ^ w_a3),   .i_b(w_b0 ^ w_b1 ^ w_b2 ^ w_b3),   .o_leaf_pack(w_leaf[4]));
gf2_32_koa_leaf16 u_l5 (.i_a(w_a1 ^ w_a3),                  .i_b(w_b1 ^ w_b3),                  .o_leaf_pack(w_leaf[5]));
gf2_32_koa_leaf16 u_l6 (.i_a(w_a2),                         .i_b(w_b2),                         .o_leaf_pack(w_leaf[6]));
gf2_32_koa_leaf16 u_l7 (.i_a(w_a2 ^ w_a3),                  .i_b(w_b2 ^ w_b3),                  .o_leaf_pack(w_leaf[7]));
gf2_32_koa_leaf16 u_l8 (.i_a(w_a3),                         .i_b(w_b3),                         .o_leaf_pack(w_leaf[8]));

//------------------------------------------------------------
// Stage 1 registers: leaf products
//------------------------------------------------------------
reg [92:0]            r_s1_leaf [0:8];
reg [META_WIDTH-1:0]  r_s1_meta;

integer i1;
always @(posedge i_clk) begin
    if (w_pipe_en && r_valid[0]) begin
        for (i1 = 0; i1 < 9; i1 = i1 + 1)
            r_s1_leaf[i1] <= w_leaf[i1];
        r_s1_meta <= r_s0_meta;
    end
end

//------------------------------------------------------------
// Stage 1鈫? combinational: 32-bit KOA recombination
//------------------------------------------------------------
wire [62:0] w_p32 [0:8];

genvar g2;
generate
    for (g2 = 0; g2 < 9; g2 = g2 + 1) begin : g_recomb32
        gf2_32_koa_recombine u_r32 (.i_leaf_pack(r_s1_leaf[g2]), .o_p(w_p32[g2]));
    end
endgenerate

//------------------------------------------------------------
// Stage 2 registers: 32-bit products
//------------------------------------------------------------
reg [62:0]            r_s2_p32 [0:8];
reg [META_WIDTH-1:0]  r_s2_meta;

integer i2;
always @(posedge i_clk) begin
    if (w_pipe_en && r_valid[1]) begin
        for (i2 = 0; i2 < 9; i2 = i2 + 1)
            r_s2_p32[i2] <= w_p32[i2];
        r_s2_meta <= r_s1_meta;
    end
end

//------------------------------------------------------------
// Stage 2鈫? combinational: 64-bit KOA recombination
//------------------------------------------------------------
wire [126:0] w_p64_lo, w_p64_mid, w_p64_hi;

gf2_64_koa_from32 u_p64lo  (.i_p0(r_s2_p32[0]), .i_p1_raw(r_s2_p32[1]), .i_p2(r_s2_p32[2]), .o_p(w_p64_lo));
gf2_64_koa_from32 u_p64mid (.i_p0(r_s2_p32[3]), .i_p1_raw(r_s2_p32[4]), .i_p2(r_s2_p32[5]), .o_p(w_p64_mid));
gf2_64_koa_from32 u_p64hi  (.i_p0(r_s2_p32[6]), .i_p1_raw(r_s2_p32[7]), .i_p2(r_s2_p32[8]), .o_p(w_p64_hi));

//------------------------------------------------------------
// Stage 3 registers: 64-bit products
//------------------------------------------------------------
reg [126:0]           r_s3_p64 [0:2];
reg [META_WIDTH-1:0]  r_s3_meta;

always @(posedge i_clk) begin
    if (w_pipe_en && r_valid[2]) begin
        r_s3_p64[0] <= w_p64_lo;
        r_s3_p64[1] <= w_p64_mid;
        r_s3_p64[2] <= w_p64_hi;
        r_s3_meta   <= r_s2_meta;
    end
end

//------------------------------------------------------------
// Stage 3鈫? combinational: 128-bit KOA recombination
//------------------------------------------------------------
wire [254:0] w_raw_product;

gf2_128_koa_from64 u_raw (.i_p0(r_s3_p64[0]), .i_p1_raw(r_s3_p64[1]), .i_p2(r_s3_p64[2]), .o_p(w_raw_product));

//------------------------------------------------------------
// Stage 4 registers: raw 255-bit product
//------------------------------------------------------------
reg [254:0]           r_s4_raw;
reg [META_WIDTH-1:0]  r_s4_meta;

always @(posedge i_clk) begin
    if (w_pipe_en && r_valid[3]) begin
        r_s4_raw  <= w_raw_product;
        r_s4_meta <= r_s3_meta;
    end
end

//------------------------------------------------------------
// Stage 4鈫? combinational: GCM reduction fold 1
//------------------------------------------------------------
wire [133:0] w_fold1;

gf2_ghash_reduce_stage1 u_red1 (.i_p(r_s4_raw), .o_fold(w_fold1));

//------------------------------------------------------------
// Stage 5 registers: reduction fold 1 result
//------------------------------------------------------------
reg [133:0]           r_s5_fold1;
reg [META_WIDTH-1:0]  r_s5_meta;

always @(posedge i_clk) begin
    if (w_pipe_en && r_valid[4]) begin
        r_s5_fold1 <= w_fold1;
        r_s5_meta  <= r_s4_meta;
    end
end

//------------------------------------------------------------
// Stage 5鈫抩utput combinational: GCM reduction fold 2 + bit reverse
//------------------------------------------------------------
wire [127:0] w_reduced;
wire [127:0] w_product_rev;

gf2_ghash_reduce_stage2 u_red2 (.i_fold(r_s5_fold1), .o_p(w_reduced));
ghash_bit_reverse128 u_p_rev (.i_data(w_reduced), .o_data(w_product_rev));

assign o_p    = w_product_rev;
assign o_meta = r_s5_meta;

endmodule
