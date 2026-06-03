/*=============================================================================
# File Name    : aes_encrypt_pipe_cf.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Fixed-latency AES encrypt pipeline using combinational S-box (no BRAM).
# 15 pipeline stages: 1 AddRoundKey + 14 round stages.
# Valid/ready flow control only at entry and exit; internal stages use a
# simple enable-gated shift register to save FF overhead.
#
# Latency: 15 cycles. Throughput: 1 block/cycle when downstream is ready.
# AES-128 uses rounds 1-10, AES-192 uses 1-12, AES-256 uses 1-14.
# Inactive rounds pass data through.
#
#=============================================================================
# Revision History:
# ----------------------------------------------------------------------------
# Date         | Author       | Version | Change Description
# ----------------------------------------------------------------------------
# 2026-06-03   | logic        | v1.0    | Initial release
# ----------------------------------------------------------------------------
#===========================================================================*/
`default_nettype wire

module aes_encrypt_pipe_cf
#(
    parameter META_WIDTH = 1
)
(
    input  wire                    i_clk        ,
    input  wire                    i_rst_n      ,

    input  wire                    i_din_valid  ,
    output wire                    o_din_ready  ,
    input  wire [127:0]            i_din        ,
    input  wire [META_WIDTH-1:0]   i_meta       ,

    input  wire [1:0]              i_key_len    ,
    input  wire [1919:0]           i_round_keys ,

    output wire                    o_dout_valid ,
    input  wire                    i_dout_ready ,
    output wire [127:0]            o_dout       ,
    output wire [META_WIDTH-1:0]   o_meta
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam STAGES = 15;

//------------------------------------------------------------
// wire
//------------------------------------------------------------
wire            w_pipe_en;
wire [127:0]    w_round_key [0:14];
wire [127:0]    w_round_out [1:14];

//------------------------------------------------------------
// reg: shift register pipeline
//------------------------------------------------------------
reg  [STAGES-1:0]          r_valid;
reg  [127:0]               r_state  [0:STAGES-1];
reg  [META_WIDTH-1:0]      r_meta   [0:STAGES-1];

//------------------------------------------------------------
// flow control: entry/exit only
//------------------------------------------------------------
assign w_pipe_en   = (~r_valid[STAGES-1]) | i_dout_ready;
assign o_din_ready = w_pipe_en;
assign o_dout_valid = r_valid[STAGES-1];
assign o_dout      = r_state[STAGES-1];
assign o_meta      = r_meta[STAGES-1];

//------------------------------------------------------------
// round key unpacking
//------------------------------------------------------------
genvar ki;
generate
    for (ki = 0; ki < 15; ki = ki + 1) begin : g_key_unpack
        assign w_round_key[ki] = i_round_keys[1919 - ki*128 -: 128];
    end
endgenerate

//------------------------------------------------------------
// round cores (combinational)
//------------------------------------------------------------
genvar ri;
generate
    for (ri = 1; ri < 15; ri = ri + 1) begin : g_round
        wire w_active = (i_key_len == 2'd0) ? (ri <= 10) :
                        (i_key_len == 2'd1) ? (ri <= 12) :
                                               (ri <= 14);
        wire w_final  = (i_key_len == 2'd0) ? (ri == 10) :
                        (i_key_len == 2'd1) ? (ri == 12) :
                                               (ri == 14);

        aes_round u_round
        (
            .i_state        (r_state[ri-1]),
            .i_round_key    (w_round_key[ri]),
            .i_active_round (w_active),
            .i_final_round  (w_final),
            .o_state        (w_round_out[ri])
        );
    end
endgenerate

//------------------------------------------------------------
// pipeline registers
//------------------------------------------------------------
// Stage 0: AddRoundKey only
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_valid[0] <= 1'b0;
    end else if (w_pipe_en) begin
        r_valid[0] <= i_din_valid;
    end
end

always @(posedge i_clk) begin
    if (w_pipe_en && i_din_valid) begin
        r_state[0] <= i_din ^ w_round_key[0];
        r_meta[0]  <= i_meta;
    end
end

// Stages 1-14: round outputs
genvar si;
generate
    for (si = 1; si < STAGES; si = si + 1) begin : g_pipe_reg
        always @(posedge i_clk or negedge i_rst_n) begin
            if (!i_rst_n) begin
                r_valid[si] <= 1'b0;
            end else if (w_pipe_en) begin
                r_valid[si] <= r_valid[si-1];
            end
        end

        always @(posedge i_clk) begin
            if (w_pipe_en && r_valid[si-1]) begin
                r_state[si] <= w_round_out[si];
                r_meta[si]  <= r_meta[si-1];
            end
        end
    end
endgenerate

endmodule
