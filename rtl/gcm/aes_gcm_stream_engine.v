/*=============================================================================
# File Name    : aes_gcm_stream_engine.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v3.0
#
#=============================================================================
# Function Description:
# Fully optimized generic AES-GCM streaming core.
#
# Optimizations vs v2.0:
#  1. Single shared KOA multiplier for H-power precompute and GHASH fold
#  2. Composite-field S-box + fixed-latency AES pipe (no BRAM S-box)
#  3. H-power stored in small memory array (not wide FF register)
#  4. Simplified valid/ready: fixed shift-register pipe, entry/exit only
#
#=============================================================================
# Revision History:
# ----------------------------------------------------------------------------
# Date         | Author       | Version | Change Description
# ----------------------------------------------------------------------------
# 2026-06-03   | logic        | v1.0    | Initial release
# 2026-06-03   | logic        | v2.0    | Merge AES pipe
# 2026-06-03   | logic        | v3.0    | Merge KOA + CF S-box + fixed pipe
# ----------------------------------------------------------------------------
#===========================================================================*/
`default_nettype wire

module aes_gcm_stream_engine
#(
    parameter FOLD_DEPTH = 8
)
(
    input  wire             i_clk          ,
    input  wire             i_rst_n        ,

    input  wire             i_start_valid  ,
    output wire             o_start_ready  ,
    input  wire             i_encrypt      ,
    input  wire [1:0]       i_key_len      ,
    input  wire [255:0]     i_key          ,
    input  wire [95:0]      i_nonce        ,
    input  wire [15:0]      i_aad_bytes    ,
    input  wire [15:0]      i_data_bytes   ,
    input  wire [127:0]     i_tag          ,

    input  wire             i_s_valid      ,
    output wire             o_s_ready      ,
    input  wire [127:0]     i_s_data       ,

    output wire             o_m_valid      ,
    input  wire             i_m_ready      ,
    output wire [127:0]     o_m_data       ,
    output wire [15:0]      o_m_keep       ,
    output wire             o_m_last       ,

    output wire             o_done_valid   ,
    input  wire             i_done_ready   ,
    output wire [127:0]     o_tag          ,
    output wire             o_auth_ok      ,
    output wire             o_error
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam STATE_IDLE         = 4'd0;
localparam STATE_CFG          = 4'd1;
localparam STATE_WAIT_KEY     = 4'd2;
localparam STATE_INIT_H       = 4'd3;
localparam STATE_INIT_J0      = 4'd4;
localparam STATE_WAIT_INIT    = 4'd5;
localparam STATE_HPOWER       = 4'd6;
localparam STATE_WAIT_HPOWER  = 4'd7;
localparam STATE_FOLD_START   = 4'd8;
localparam STATE_AAD          = 4'd9;
localparam STATE_DATA         = 4'd10;
localparam STATE_DRAIN        = 4'd11;
localparam STATE_LEN          = 4'd12;
localparam STATE_WAIT_HASH    = 4'd13;
localparam STATE_DONE         = 4'd14;

localparam AES_META_H         = 2'd0;
localparam AES_META_MASK      = 2'd1;
localparam AES_META_DATA      = 2'd2;
localparam AES_META_WIDTH     = 2;
localparam AES_PACK_WIDTH     = 128 + AES_META_WIDTH;
localparam DATA_DELAY_FIFO_ADDR_WIDTH = 5;

//------------------------------------------------------------
// reg
//------------------------------------------------------------
reg  [3:0]      r_state;
reg             r_encrypt;
reg  [1:0]      r_key_len;
reg  [95:0]     r_nonce;
reg  [15:0]     r_aad_bytes;
reg  [15:0]     r_data_bytes;
reg             r_aad_has_blocks;
reg             r_data_has_blocks;
reg  [15:0]     r_aad_last_index;
reg  [15:0]     r_data_last_index;
reg  [4:0]      r_aad_last_valid_bytes;
reg  [4:0]      r_data_last_valid_bytes;
reg  [15:0]     r_total_ghash_blocks;
reg  [127:0]    r_expect_tag;
reg  [15:0]     r_aad_count;
reg  [15:0]     r_data_in_count;
reg  [15:0]     r_data_out_count;
reg  [31:0]     r_ctr32;
reg  [127:0]    r_tag_mask;
reg             r_mask_valid;
reg             r_done_valid;
reg  [127:0]    r_done_tag;
reg             r_auth_ok;
reg             r_error;

// H-power computation
reg  [127:0]    r_h;
reg             r_h_valid;
reg  [127:0]    r_current_h;
reg  [5:0]      r_hpower_count;
reg             r_hpower_done;

// H-power memory (small array, inferred as distributed RAM)
reg  [127:0]    r_hpower_mem [0:FOLD_DEPTH-1];
reg  [127:0]    r_hpower_rd_data;

//------------------------------------------------------------
// wire: AES pipe
//------------------------------------------------------------
wire            w_start_fire;
wire            w_done_fire;
wire [16:0]     w_total_blocks_ext;
wire [15:0]     w_start_aad_blocks;
wire [15:0]     w_start_data_blocks;
wire [4:0]      w_start_aad_last_bytes;
wire [4:0]      w_start_data_last_bytes;
wire [4:0]      w_aad_valid_bytes;
wire [4:0]      w_data_valid_bytes;
wire [4:0]      w_data_out_valid_bytes;
wire [63:0]     w_aad_bits;
wire [63:0]     w_data_bits;
wire [127:0]    w_len_block;
wire [127:0]    w_j0_block;
wire [127:0]    w_ctr_block;

wire            w_aes_cfg_valid;
wire            w_aes_cfg_ready;
wire            w_aes_key_ready;
wire            w_aes_din_valid;
wire            w_aes_din_ready;
wire [127:0]    w_aes_din;
wire [AES_META_WIDTH-1:0] w_aes_meta_in;
wire            w_aes_din_fire;
wire            w_aes_data_din_fire;
wire            w_aes_data_last_fire;
wire            w_aes_dout_valid;
wire            w_aes_dout_ready;
wire [127:0]    w_aes_dout;
wire [AES_META_WIDTH-1:0] w_aes_meta_out;
wire            w_aes_raw_dout_valid;
wire            w_aes_raw_dout_ready;
wire [127:0]    w_aes_raw_dout;
wire [AES_META_WIDTH-1:0] w_aes_raw_meta_out;
wire [AES_PACK_WIDTH-1:0] w_aes_raw_pack;
wire [AES_PACK_WIDTH-1:0] w_aes_buf_pack;
wire            w_aes_dout_fire;
wire            w_aes_dout_is_data;
wire            w_aes_dout_is_mask;
wire            w_aes_dout_is_h;

//------------------------------------------------------------
// wire: data path
//------------------------------------------------------------
wire [127:0]    w_delay_input_data;
wire            w_data_delay_din_valid;
wire            w_data_delay_din_ready;
wire            w_data_delay_dout_valid;
wire            w_data_delay_dout_ready;
wire [127:0]    w_data_delay_dout;
wire [127:0]    w_aad_masked_data;
wire [15:0]     w_aad_keep;
wire [127:0]    w_data_masked_in;
wire [15:0]     w_data_in_keep;
wire [127:0]    w_data_masked_result;
wire [15:0]     w_data_out_keep;
wire [127:0]    w_data_result;
wire [127:0]    w_data_ghash_block;
wire            w_data_out_valid;
wire            w_data_out_fire;
wire            w_data_out_last_fire;
wire            w_init_done;

//------------------------------------------------------------
// wire: GHASH fold
//------------------------------------------------------------
wire            w_fold_start_valid;
wire            w_fold_start_ready;
wire            w_fold_s_valid;
wire            w_fold_s_ready;
wire [127:0]    w_fold_s_data;
wire            w_fold_s_fire;
wire            w_fold_done_valid;
wire            w_fold_done_ready;
wire [127:0]    w_fold_hash;
wire            w_aad_s_valid;
wire            w_data_s_valid;
wire            w_len_s_valid;
wire            w_aad_last_fire;
wire            w_aad_is_last;
wire            w_data_in_is_last;
wire            w_data_out_is_last;

//------------------------------------------------------------
// wire: shared KOA multiplier
//------------------------------------------------------------
wire            w_fold_ext_mul_valid;
wire            w_fold_ext_mul_ready;
wire [127:0]    w_fold_ext_mul_x;
wire [127:0]    w_fold_ext_mul_y;
wire [2:0]      w_fold_ext_mul_meta;
wire            w_fold_ext_mul_done_valid;
wire [127:0]    w_fold_ext_mul_product;
wire [2:0]      w_fold_ext_mul_done_meta;

wire            w_hp_phase;
wire            w_koa_din_valid;
wire            w_koa_din_ready;
wire [127:0]    w_koa_x;
wire [127:0]    w_koa_y;
wire [2:0]      w_koa_meta_in;
wire            w_koa_dout_valid;
wire [127:0]    w_koa_product;
wire [2:0]      w_koa_meta_out;

wire [5:0]      w_hpower_target;
wire            w_fold_h_power_rd_en;
wire [4:0]      w_fold_h_power_rd_power;

//------------------------------------------------------------
// assign: configuration
//------------------------------------------------------------
assign o_start_ready       = (r_state == STATE_IDLE);
assign w_start_fire        = i_start_valid & o_start_ready;
assign w_done_fire         = r_done_valid & i_done_ready;
assign w_start_aad_blocks  = (i_aad_bytes[3:0] == 4'd0) ?
                             {4'd0, i_aad_bytes[15:4]} :
                             ({4'd0, i_aad_bytes[15:4]} + 16'd1);
assign w_start_data_blocks = (i_data_bytes[3:0] == 4'd0) ?
                             {4'd0, i_data_bytes[15:4]} :
                             ({4'd0, i_data_bytes[15:4]} + 16'd1);
assign w_start_aad_last_bytes = (i_aad_bytes[3:0] == 4'd0) ?
                                5'd16 : {1'b0, i_aad_bytes[3:0]};
assign w_start_data_last_bytes = (i_data_bytes[3:0] == 4'd0) ?
                                 5'd16 : {1'b0, i_data_bytes[3:0]};
assign w_total_blocks_ext  = {1'b0, w_start_data_blocks} +
                             {1'b0, w_start_aad_blocks} + 17'd1;

assign w_j0_block          = {r_nonce, 32'h00000001};
assign w_ctr_block         = {r_nonce, r_ctr32};
assign w_aad_bits          = {45'd0, r_aad_bytes, 3'd0};
assign w_data_bits         = {45'd0, r_data_bytes, 3'd0};
assign w_len_block         = {w_aad_bits, w_data_bits};

//------------------------------------------------------------
// assign: byte masking
//------------------------------------------------------------
assign w_aad_is_last       = r_aad_has_blocks &
                             (r_aad_count == r_aad_last_index);
assign w_data_in_is_last   = r_data_has_blocks &
                             (r_data_in_count == r_data_last_index);
assign w_data_out_is_last  = r_data_has_blocks &
                             (r_data_out_count == r_data_last_index);
assign w_aad_valid_bytes     = w_aad_is_last     ? r_aad_last_valid_bytes  : 5'd16;
assign w_data_valid_bytes    = w_data_in_is_last  ? r_data_last_valid_bytes : 5'd16;
assign w_data_out_valid_bytes = w_data_out_is_last ? r_data_last_valid_bytes : 5'd16;

//------------------------------------------------------------
// assign: AES pipe control
//------------------------------------------------------------
assign w_aes_cfg_valid     = (r_state == STATE_CFG);
assign w_aes_din_valid     = (r_state == STATE_INIT_H) |
                              (r_state == STATE_INIT_J0) |
                              ((r_state == STATE_DATA) &
                               i_s_valid & w_data_delay_din_ready);
assign w_aes_din           = (r_state == STATE_INIT_J0) ? w_j0_block :
                             (r_state == STATE_DATA)    ? w_ctr_block :
                                                            128'h0     ;
assign w_aes_meta_in       = (r_state == STATE_INIT_H)  ? AES_META_H    :
                             (r_state == STATE_INIT_J0) ? AES_META_MASK :
                                                            AES_META_DATA ;
assign w_aes_din_fire      = w_aes_din_valid & w_aes_din_ready;
assign w_aes_data_din_fire = (r_state == STATE_DATA) & w_aes_din_fire;
assign w_aes_data_last_fire = w_aes_data_din_fire & w_data_in_is_last;
assign w_data_delay_din_valid = (r_state == STATE_DATA) &
                                i_s_valid & w_aes_din_ready;

//------------------------------------------------------------
// assign: AES output
//------------------------------------------------------------
assign w_aes_dout_is_h     = (w_aes_meta_out == AES_META_H);
assign w_aes_dout_is_mask  = (w_aes_meta_out == AES_META_MASK);
assign w_aes_dout_is_data  = (w_aes_meta_out == AES_META_DATA);
assign w_delay_input_data  = w_data_delay_dout;
assign w_aes_raw_pack      = {w_aes_raw_dout, w_aes_raw_meta_out};
assign w_aes_dout          = w_aes_buf_pack[AES_PACK_WIDTH-1 -: 128];
assign w_aes_meta_out      = w_aes_buf_pack[AES_META_WIDTH-1:0];
assign w_data_result       = w_aes_dout ^ w_delay_input_data;
assign w_data_ghash_block  = r_encrypt ? w_data_masked_result :
                                         w_delay_input_data;
assign w_data_out_valid    = ((r_state == STATE_DATA) |
                              (r_state == STATE_DRAIN)) &
                              w_aes_dout_valid & w_aes_dout_is_data &
                              w_data_delay_dout_valid;
assign o_m_valid           = w_data_out_valid & w_fold_s_ready;
assign o_m_data            = w_data_masked_result;
assign o_m_keep            = w_data_out_keep;
assign o_m_last            = w_data_out_is_last;
assign w_data_out_fire     = o_m_valid & i_m_ready;
assign w_data_out_last_fire = w_data_out_fire & w_data_out_is_last;
assign w_aes_dout_ready    = w_aes_dout_is_data ?
                              (w_data_delay_dout_valid &
                               w_fold_s_ready & i_m_ready) : 1'b1;
assign w_aes_dout_fire     = w_aes_dout_valid & w_aes_dout_ready;
assign w_data_delay_dout_ready = w_aes_dout_fire & w_aes_dout_is_data;
assign w_init_done         = r_h_valid & r_mask_valid & r_hpower_done;

//------------------------------------------------------------
// assign: GHASH fold
//------------------------------------------------------------
assign w_fold_start_valid  = (r_state == STATE_FOLD_START);
assign w_aad_s_valid       = (r_state == STATE_AAD) & i_s_valid;
assign w_data_s_valid      = ((r_state == STATE_DATA) |
                              (r_state == STATE_DRAIN)) &
                              w_data_out_valid & i_m_ready;
assign w_len_s_valid       = (r_state == STATE_LEN);
assign w_fold_s_valid      = w_aad_s_valid | w_data_s_valid | w_len_s_valid;
assign w_fold_s_data       = (r_state == STATE_AAD) ? w_aad_masked_data :
                             ((r_state == STATE_LEN) ? w_len_block :
                                                        w_data_ghash_block);
assign w_fold_s_fire       = w_fold_s_valid & w_fold_s_ready;
assign w_fold_done_ready   = 1'b1;
assign w_aad_last_fire     = (r_state == STATE_AAD) & w_fold_s_fire &
                              w_aad_is_last;

assign o_s_ready           = (r_state == STATE_AAD)  ? w_fold_s_ready :
                             (r_state == STATE_DATA) ?
                              (w_aes_din_ready & w_data_delay_din_ready) :
                                                         1'b0;
assign o_done_valid        = r_done_valid;
assign o_tag               = r_done_tag;
assign o_auth_ok           = r_auth_ok;
assign o_error             = r_error;

//------------------------------------------------------------
// assign: shared KOA mux (H-power vs fold)
//------------------------------------------------------------
assign w_hpower_target     = FOLD_DEPTH[5:0];
assign w_hp_phase          = ~r_hpower_done;

assign w_koa_din_valid     = w_hp_phase ?
                              (r_state == STATE_HPOWER) :
                              w_fold_ext_mul_valid;
assign w_koa_x             = w_hp_phase ? r_current_h  : w_fold_ext_mul_x;
assign w_koa_y             = w_hp_phase ? r_h          : w_fold_ext_mul_y;
assign w_koa_meta_in       = w_hp_phase ? 3'd0         : w_fold_ext_mul_meta;

assign w_fold_ext_mul_ready      = w_hp_phase ? 1'b0 : w_koa_din_ready;
assign w_fold_ext_mul_done_valid = w_hp_phase ? 1'b0 : w_koa_dout_valid;
assign w_fold_ext_mul_product    = w_koa_product;
assign w_fold_ext_mul_done_meta  = w_koa_meta_out;

//------------------------------------------------------------
// state machine
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_state <= STATE_IDLE;
    end else begin
        case (r_state)
            STATE_IDLE: begin
                if (w_start_fire)
                    r_state <= STATE_CFG;
            end
            STATE_CFG: begin
                if (w_aes_cfg_ready)
                    r_state <= STATE_WAIT_KEY;
            end
            STATE_WAIT_KEY: begin
                if (w_aes_key_ready)
                    r_state <= STATE_INIT_H;
            end
            STATE_INIT_H: begin
                if (w_aes_din_fire)
                    r_state <= STATE_INIT_J0;
            end
            STATE_INIT_J0: begin
                if (w_aes_din_fire)
                    r_state <= STATE_WAIT_INIT;
            end
            STATE_WAIT_INIT: begin
                if (w_init_done) begin
                    r_state <= STATE_FOLD_START;
                end else if (r_h_valid && !r_hpower_done &&
                             (w_hpower_target > 6'd1)) begin
                    r_state <= STATE_HPOWER;
                end
            end
            STATE_HPOWER: begin
                if (w_koa_din_valid & w_koa_din_ready)
                    r_state <= STATE_WAIT_HPOWER;
            end
            STATE_WAIT_HPOWER: begin
                if (w_koa_dout_valid) begin
                    if (r_hpower_count >= (w_hpower_target - 6'd1)) begin
                        if (r_mask_valid)
                            r_state <= STATE_FOLD_START;
                        else
                            r_state <= STATE_WAIT_INIT;
                    end else begin
                        r_state <= STATE_HPOWER;
                    end
                end
            end
            STATE_FOLD_START: begin
                if (w_fold_start_ready) begin
                    if (r_aad_has_blocks)
                        r_state <= STATE_AAD;
                    else if (r_data_has_blocks)
                        r_state <= STATE_DATA;
                    else
                        r_state <= STATE_LEN;
                end
            end
            STATE_AAD: begin
                if (w_aad_last_fire) begin
                    if (r_data_has_blocks)
                        r_state <= STATE_DATA;
                    else
                        r_state <= STATE_LEN;
                end
            end
            STATE_DATA: begin
                if (w_aes_data_last_fire)
                    r_state <= STATE_DRAIN;
            end
            STATE_DRAIN: begin
                if (w_data_out_last_fire)
                    r_state <= STATE_LEN;
            end
            STATE_LEN: begin
                if (w_fold_s_fire)
                    r_state <= STATE_WAIT_HASH;
            end
            STATE_WAIT_HASH: begin
                if (w_fold_done_valid)
                    r_state <= STATE_DONE;
            end
            STATE_DONE: begin
                if (w_done_fire)
                    r_state <= STATE_IDLE;
            end
            default: r_state <= STATE_IDLE;
        endcase
    end
end

//------------------------------------------------------------
// packet configuration
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_encrypt            <= 1'b1;
        r_key_len            <= 2'd0;
        r_nonce              <= 96'h0;
        r_aad_bytes          <= 16'd0;
        r_data_bytes         <= 16'd0;
        r_aad_has_blocks     <= 1'b0;
        r_data_has_blocks    <= 1'b0;
        r_aad_last_index     <= 16'd0;
        r_data_last_index    <= 16'd0;
        r_aad_last_valid_bytes  <= 5'd16;
        r_data_last_valid_bytes <= 5'd16;
        r_total_ghash_blocks <= 16'd0;
        r_expect_tag         <= 128'h0;
        r_error              <= 1'b0;
    end else if (w_start_fire) begin
        r_encrypt            <= i_encrypt;
        r_key_len            <= i_key_len;
        r_nonce              <= i_nonce;
        r_aad_bytes          <= i_aad_bytes;
        r_data_bytes         <= i_data_bytes;
        r_aad_has_blocks     <= (w_start_aad_blocks != 16'd0);
        r_data_has_blocks    <= (w_start_data_blocks != 16'd0);
        r_aad_last_index     <= w_start_aad_blocks - 16'd1;
        r_data_last_index    <= w_start_data_blocks - 16'd1;
        r_aad_last_valid_bytes  <= w_start_aad_last_bytes;
        r_data_last_valid_bytes <= w_start_data_last_bytes;
        r_total_ghash_blocks <= w_total_blocks_ext[15:0];
        r_expect_tag         <= i_tag;
        r_error              <= w_total_blocks_ext[16] |
                                ((i_aad_bytes != 16'd0) &
                                 (w_start_aad_last_bytes == 5'd0)) |
                                ((i_data_bytes != 16'd0) &
                                 (w_start_data_last_bytes == 5'd0));
    end
end

//------------------------------------------------------------
// counters
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      r_aad_count <= 16'd0;
    else if (w_start_fire) r_aad_count <= 16'd0;
    else if ((r_state == STATE_AAD) && w_fold_s_fire)
        r_aad_count <= r_aad_count + 16'd1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      r_data_in_count <= 16'd0;
    else if (w_start_fire) r_data_in_count <= 16'd0;
    else if (w_aes_data_din_fire)
        r_data_in_count <= r_data_in_count + 16'd1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      r_data_out_count <= 16'd0;
    else if (w_start_fire) r_data_out_count <= 16'd0;
    else if (w_data_out_fire)
        r_data_out_count <= r_data_out_count + 16'd1;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      r_ctr32 <= 32'h00000002;
    else if (w_start_fire) r_ctr32 <= 32'h00000002;
    else if (w_aes_data_din_fire) r_ctr32 <= r_ctr32 + 32'd1;
end

//------------------------------------------------------------
// H capture and tag mask
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      begin r_h <= 128'h0; r_h_valid <= 1'b0; end
    else if (w_start_fire) r_h_valid <= 1'b0;
    else if (w_aes_dout_fire && w_aes_dout_is_h) begin
        r_h       <= w_aes_dout;
        r_h_valid <= 1'b1;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      begin r_tag_mask <= 128'h0; r_mask_valid <= 1'b0; end
    else if (w_start_fire) r_mask_valid <= 1'b0;
    else if (w_aes_dout_fire && w_aes_dout_is_mask) begin
        r_tag_mask   <= w_aes_dout;
        r_mask_valid <= 1'b1;
    end
end

//------------------------------------------------------------
// H-power precomputation (shared KOA)
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)      r_current_h <= 128'h0;
    else if (w_aes_dout_fire && w_aes_dout_is_h)
        r_current_h <= w_aes_dout;
    else if ((r_state == STATE_WAIT_HPOWER) && w_koa_dout_valid)
        r_current_h <= w_koa_product;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_hpower_count <= 6'd0;
        r_hpower_done  <= 1'b0;
    end else if (w_start_fire) begin
        r_hpower_count <= 6'd0;
        r_hpower_done  <= (FOLD_DEPTH <= 1) ? 1'b1 : 1'b0;
    end else if (w_aes_dout_fire && w_aes_dout_is_h) begin
        r_hpower_count <= 6'd1;
        r_hpower_done  <= (w_hpower_target <= 6'd1);
    end else if ((r_state == STATE_WAIT_HPOWER) && w_koa_dout_valid) begin
        r_hpower_count <= r_hpower_count + 6'd1;
        if (r_hpower_count >= (w_hpower_target - 6'd1))
            r_hpower_done <= 1'b1;
    end
end

// H-power memory: unified write port for LUTRAM inference
wire        w_hp_wr_en   = (w_aes_dout_fire && w_aes_dout_is_h) |
                           ((r_state == STATE_WAIT_HPOWER) && w_koa_dout_valid);
wire [4:0]  w_hp_wr_addr = (w_aes_dout_fire && w_aes_dout_is_h) ?
                           5'd0 : r_hpower_count[4:0];
wire [127:0] w_hp_wr_data = (w_aes_dout_fire && w_aes_dout_is_h) ?
                            w_aes_dout : w_koa_product;

always @(posedge i_clk) begin
    if (w_hp_wr_en)
        r_hpower_mem[w_hp_wr_addr] <= w_hp_wr_data;
end

always @(posedge i_clk) begin
    r_hpower_rd_data <= r_hpower_mem[w_fold_h_power_rd_power];
end

//------------------------------------------------------------
// done registers
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_done_valid <= 1'b0; r_done_tag <= 128'h0; r_auth_ok <= 1'b0;
    end else if (w_start_fire) begin
        r_done_valid <= 1'b0;
    end else if (w_done_fire) begin
        r_done_valid <= 1'b0;
    end else if ((r_state == STATE_WAIT_HASH) && w_fold_done_valid) begin
        r_done_valid <= 1'b1;
        r_done_tag   <= r_tag_mask ^ w_fold_hash;
        r_auth_ok    <= r_encrypt ? 1'b1 :
                        ((r_tag_mask ^ w_fold_hash) == r_expect_tag);
    end
end

//------------------------------------------------------------
// sub modules
//------------------------------------------------------------
//------------------------------------------------------------
// inline byte masking (replaces byte_mask128 module)
//------------------------------------------------------------
genvar bm;
generate
    for (bm = 0; bm < 16; bm = bm + 1) begin : g_byte_mask
        localparam [4:0] BI = bm;
        // AAD mask
        assign w_aad_keep[15-bm]              = (w_aad_valid_bytes > BI);
        assign w_aad_masked_data[127-bm*8-:8] = w_aad_keep[15-bm] ?
                                                 i_s_data[127-bm*8-:8] : 8'h00;
        // Data input mask
        assign w_data_in_keep[15-bm]           = (w_data_valid_bytes > BI);
        assign w_data_masked_in[127-bm*8-:8]  = w_data_in_keep[15-bm] ?
                                                 i_s_data[127-bm*8-:8] : 8'h00;
        // Data output mask
        assign w_data_out_keep[15-bm]             = (w_data_out_valid_bytes > BI);
        assign w_data_masked_result[127-bm*8-:8]  = w_data_out_keep[15-bm] ?
                                                     w_data_result[127-bm*8-:8] : 8'h00;
    end
endgenerate

// AES pipe: composite-field S-box, fixed latency, internal key expand
aes_encrypt_core_cf
#(
    .META_WIDTH       (AES_META_WIDTH)
)
u_aes_encrypt_core
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_cfg_valid      (w_aes_cfg_valid),
    .o_cfg_ready      (w_aes_cfg_ready),
    .i_key_len        (r_key_len),
    .i_key            (i_key),
    .o_key_ready      (w_aes_key_ready),
    .i_din_valid      (w_aes_din_valid),
    .o_din_ready      (w_aes_din_ready),
    .i_din            (w_aes_din),
    .i_meta           (w_aes_meta_in),
    .o_dout_valid     (w_aes_raw_dout_valid),
    .i_dout_ready     (w_aes_raw_dout_ready),
    .o_dout           (w_aes_raw_dout),
    .o_meta           (w_aes_raw_meta_out)
);

val_rdy_two_entry_fifo
#(
    .DATA_WIDTH       (AES_PACK_WIDTH)
)
u_aes_dout_fifo
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_din_valid      (w_aes_raw_dout_valid),
    .o_din_ready      (w_aes_raw_dout_ready),
    .i_din            (w_aes_raw_pack),
    .o_dout_valid     (w_aes_dout_valid),
    .i_dout_ready     (w_aes_dout_ready),
    .o_dout           (w_aes_buf_pack)
);

val_rdy_bram_fifo
#(
    .DATA_WIDTH       (128),
    .ADDR_WIDTH       (DATA_DELAY_FIFO_ADDR_WIDTH)
)
u_data_delay_fifo
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_din_valid      (w_data_delay_din_valid),
    .o_din_ready      (w_data_delay_din_ready),
    .i_din            (w_data_masked_in),
    .o_dout_valid     (w_data_delay_dout_valid),
    .i_dout_ready     (w_data_delay_dout_ready),
    .o_dout           (w_data_delay_dout)
);

// Single shared KOA multiplier (fixed-latency, no per-stage val/rdy)
ghash_mul_koa_pipe_fixed
#(
    .META_WIDTH       (3)
)
u_shared_koa
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_din_valid      (w_koa_din_valid),
    .o_din_ready      (w_koa_din_ready),
    .i_x              (w_koa_x),
    .i_y              (w_koa_y),
    .i_meta           (w_koa_meta_in),
    .o_dout_valid     (w_koa_dout_valid),
    .i_dout_ready     (1'b1),
    .o_p              (w_koa_product),
    .o_meta           (w_koa_meta_out)
);

// GHASH fold engine with external multiplier and BRAM H-power
ghash_foldN_stream
#(
    .FOLD_DEPTH       (FOLD_DEPTH)
)
u_ghash_foldN_stream
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_start_valid    (w_fold_start_valid),
    .o_start_ready    (w_fold_start_ready),
    .i_total_blocks   (r_total_ghash_blocks),
    .o_h_power_rd_en  (w_fold_h_power_rd_en),
    .o_h_power_rd_power(w_fold_h_power_rd_power),
    .i_h_power_rd_data(r_hpower_rd_data),
    .i_s_valid        (w_fold_s_valid),
    .o_s_ready        (w_fold_s_ready),
    .i_s_data         (w_fold_s_data),
    .o_ext_mul_valid  (w_fold_ext_mul_valid),
    .i_ext_mul_ready  (w_fold_ext_mul_ready),
    .o_ext_mul_x      (w_fold_ext_mul_x),
    .o_ext_mul_y      (w_fold_ext_mul_y),
    .o_ext_mul_meta   (w_fold_ext_mul_meta),
    .i_ext_mul_done_valid(w_fold_ext_mul_done_valid),
    .i_ext_mul_product(w_fold_ext_mul_product),
    .i_ext_mul_meta   (w_fold_ext_mul_done_meta),
    .o_done_valid     (w_fold_done_valid),
    .i_done_ready     (w_fold_done_ready),
    .o_hash           (w_fold_hash)
);

endmodule
