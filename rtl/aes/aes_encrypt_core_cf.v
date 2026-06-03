/*=============================================================================
# File Name    : aes_encrypt_core_cf.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# AES encrypt stream core using composite-field (combinational) S-box and
# fixed-latency pipeline. Key expansion is done internally. Same external
# interface as aes_encrypt_core but uses aes_encrypt_pipe_cf (no BRAM S-box).
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

module aes_encrypt_core_cf
#(
    parameter META_WIDTH = 1
)
(
    input  wire                    i_clk        ,
    input  wire                    i_rst_n      ,

    input  wire                    i_cfg_valid  ,
    output wire                    o_cfg_ready  ,
    input  wire [1:0]              i_key_len    ,
    input  wire [255:0]            i_key        ,
    output wire                    o_key_ready  ,

    input  wire                    i_din_valid  ,
    output wire                    o_din_ready  ,
    input  wire [127:0]            i_din        ,
    input  wire [META_WIDTH-1:0]   i_meta       ,

    output wire                    o_dout_valid ,
    input  wire                    i_dout_ready ,
    output wire [127:0]            o_dout       ,
    output wire [META_WIDTH-1:0]   o_meta
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam STATE_IDLE   = 2'd0;
localparam STATE_EXPAND = 2'd1;
localparam STATE_READY  = 2'd2;

//------------------------------------------------------------
// reg
//------------------------------------------------------------
reg  [1:0]      r_state;
reg  [1:0]      r_key_len;
reg  [1919:0]   r_round_keys;

//------------------------------------------------------------
// wire
//------------------------------------------------------------
wire            w_cfg_fire;
wire            w_expand_valid;
wire [1919:0]   w_expand_keys;
wire [3:0]      w_expand_round_num;
wire            w_pipe_ready;

//------------------------------------------------------------
// assign
//------------------------------------------------------------
assign o_cfg_ready    = (r_state == STATE_IDLE) | (r_state == STATE_READY);
assign w_cfg_fire     = i_cfg_valid & o_cfg_ready;
assign o_key_ready    = (r_state == STATE_READY);
assign o_din_ready    = o_key_ready & w_pipe_ready;

//------------------------------------------------------------
// state
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_state <= STATE_IDLE;
    end else begin
        case (r_state)
            STATE_IDLE: begin
                if (w_cfg_fire)
                    r_state <= STATE_EXPAND;
            end
            STATE_EXPAND: begin
                if (w_expand_valid)
                    r_state <= STATE_READY;
            end
            STATE_READY: begin
                if (w_cfg_fire)
                    r_state <= STATE_EXPAND;
            end
            default: r_state <= STATE_IDLE;
        endcase
    end
end

always @(posedge i_clk) begin
    if (w_cfg_fire)
        r_key_len <= i_key_len;
end

always @(posedge i_clk) begin
    if (w_expand_valid)
        r_round_keys <= w_expand_keys;
end

//------------------------------------------------------------
// sub modules
//------------------------------------------------------------
aes_key_expand u_aes_key_expand
(
    .i_clk              (i_clk),
    .i_rst_n            (i_rst_n),
    .i_start_valid      (w_cfg_fire),
    .o_start_ready      (),
    .i_key_len          (i_key_len),
    .i_key              (i_key),
    .o_round_keys_valid (w_expand_valid),
    .i_round_keys_ready (1'b1),
    .o_round_keys       (w_expand_keys),
    .o_round_num        (w_expand_round_num)
);

aes_encrypt_pipe_cf
#(
    .META_WIDTH         (META_WIDTH)
)
u_aes_encrypt_pipe
(
    .i_clk              (i_clk),
    .i_rst_n            (i_rst_n),
    .i_din_valid        (i_din_valid & o_key_ready),
    .o_din_ready        (w_pipe_ready),
    .i_din              (i_din),
    .i_meta             (i_meta),
    .i_key_len          (r_key_len),
    .i_round_keys       (r_round_keys),
    .o_dout_valid       (o_dout_valid),
    .i_dout_ready       (i_dout_ready),
    .o_dout             (o_dout),
    .o_meta             (o_meta)
);

endmodule
