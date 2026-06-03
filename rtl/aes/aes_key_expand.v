/*=============================================================================
# File Name    : aes_key_expand.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Sequential AES-128/192/256 key expansion. Key schedule SubWord uses a
# synchronous BRAM-style S-box, so each generated word uses an address phase and
# a write phase instead of a large combinational LUT ROM path.
#
#=============================================================================
# Revision History:
# ----------------------------------------------------------------------------
# Date         | Author       | Version | Change Description
# ----------------------------------------------------------------------------
# 2026-05-20   | logic        | v1.0    | Initial release
# ----------------------------------------------------------------------------
#===========================================================================*/
`default_nettype wire

module aes_key_expand
(
    input  wire             i_clk              ,
    input  wire             i_rst_n            ,

    input  wire             i_start_valid      ,
    output wire             o_start_ready      ,
    input  wire [1:0]       i_key_len          ,
    input  wire [255:0]     i_key              ,

    output reg              o_round_keys_valid ,
    input  wire             i_round_keys_ready ,
    output wire [1919:0]    o_round_keys       ,
    output wire [3:0]       o_round_num
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam STATE_IDLE      = 2'd0;
localparam STATE_RUN_ADDR  = 2'd1;
localparam STATE_RUN_WRITE = 2'd2;
localparam STATE_DONE      = 2'd3;

//------------------------------------------------------------
// reg
//------------------------------------------------------------
reg  [1:0]   r_state;
reg  [1:0]   r_key_len;
reg  [31:0]  r_word [0:59];
reg  [5:0]   r_word_idx;
reg  [3:0]   r_mod_idx;
reg  [3:0]   r_rcon_idx;
reg  [5:0]   r_calc_word_idx;
reg  [3:0]   r_calc_mod_idx;
reg  [31:0]  r_calc_prev_word;
reg  [31:0]  r_calc_nk_word;
reg  [31:0]  r_calc_rcon_word;

//------------------------------------------------------------
// wire
//------------------------------------------------------------
wire [3:0]   w_nk;
wire [3:0]   w_nr;
wire [5:0]   w_word_limit;
wire [5:0]   w_back_idx;
wire [31:0]  w_prev_word;
wire [31:0]  w_nk_word;
wire [31:0]  w_rot_word;
wire [31:0]  w_sub_addr_word;
wire [31:0]  w_sub_word;
wire [31:0]  w_rcon_word;
wire [31:0]  w_schedule_temp;
wire [31:0]  w_next_word;
wire         w_start_fire;
wire         w_calc_last;

//------------------------------------------------------------
// assign
//------------------------------------------------------------
assign o_start_ready = (r_state == STATE_IDLE);
assign w_start_fire  = i_start_valid & o_start_ready;

assign w_nk = (r_key_len == 2'd0) ? 4'd4 :
              (r_key_len == 2'd1) ? 4'd6 : 4'd8;
assign w_nr = (r_key_len == 2'd0) ? 4'd10 :
              (r_key_len == 2'd1) ? 4'd12 : 4'd14;
assign o_round_num  = w_nr;
assign w_word_limit = {2'b00, (w_nr + 4'd1)} << 2;
assign w_back_idx   = r_word_idx - {2'b00, w_nk};
assign w_prev_word  = r_word[r_word_idx - 6'd1];
assign w_nk_word    = r_word[w_back_idx];
assign w_rot_word   = {w_prev_word[23:0], w_prev_word[31:24]};
assign w_sub_addr_word = (r_mod_idx == 4'd0) ? w_rot_word : w_prev_word;
assign w_calc_last = (r_calc_word_idx == (w_word_limit - 6'd1));
assign w_schedule_temp = (r_calc_mod_idx == 4'd0) ?
                         (w_sub_word ^ r_calc_rcon_word) :
                         ((w_nk == 4'd8) && (r_calc_mod_idx == 4'd4)) ?
                         w_sub_word : r_calc_prev_word;
assign w_next_word = r_calc_nk_word ^ w_schedule_temp;

genvar gi;
generate
    for (gi = 0; gi < 15; gi = gi + 1) begin : g_round_key_pack
        assign o_round_keys[1919-gi*128 -: 128] = {
            r_word[gi*4+0],
            r_word[gi*4+1],
            r_word[gi*4+2],
            r_word[gi*4+3]
        };
    end
endgenerate

//------------------------------------------------------------
// sub modules
//------------------------------------------------------------
aes_sub_word_bram u_aes_sub_word_bram
(
    .i_clk     (i_clk),
    .i_word    (w_sub_addr_word),
    .o_word    (w_sub_word)
);

aes_rcon u_aes_rcon
(
    .i_index   (r_rcon_idx),
    .o_word    (w_rcon_word)
);

//------------------------------------------------------------
// state
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_state <= STATE_IDLE;
    end else begin
        case (r_state)
            STATE_IDLE: begin
                if (w_start_fire) begin
                    r_state <= STATE_RUN_ADDR;
                end
            end
            STATE_RUN_ADDR: begin
                r_state <= STATE_RUN_WRITE;
            end
            STATE_RUN_WRITE: begin
                if (w_calc_last) begin
                    r_state <= STATE_DONE;
                end else begin
                    r_state <= STATE_RUN_ADDR;
                end
            end
            STATE_DONE: begin
                if (o_round_keys_valid && i_round_keys_ready) begin
                    r_state <= STATE_IDLE;
                end
            end
            default: begin
                r_state <= STATE_IDLE;
            end
        endcase
    end
end

//------------------------------------------------------------
// key length register
//------------------------------------------------------------
always @(posedge i_clk) begin
    if (w_start_fire) begin
        r_key_len <= i_key_len;
    end
end

//------------------------------------------------------------
// output valid
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        o_round_keys_valid <= 1'b0;
    end else if (o_round_keys_valid && i_round_keys_ready) begin
        o_round_keys_valid <= 1'b0;
    end else if ((r_state == STATE_RUN_WRITE) && w_calc_last) begin
        o_round_keys_valid <= 1'b1;
    end
end

//------------------------------------------------------------
// word index
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_word_idx <= 6'd0;
    end else if (w_start_fire) begin
        r_word_idx <= (i_key_len == 2'd0) ? 6'd4 :
                      (i_key_len == 2'd1) ? 6'd6 : 6'd8;
    end else if ((r_state == STATE_RUN_WRITE) && (!w_calc_last)) begin
        r_word_idx <= r_word_idx + 6'd1;
    end
end

//------------------------------------------------------------
// modulo index
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_mod_idx <= 4'd0;
    end else if (w_start_fire) begin
        r_mod_idx <= 4'd0;
    end else if ((r_state == STATE_RUN_WRITE) && (!w_calc_last)) begin
        if (r_mod_idx == (w_nk - 4'd1)) begin
            r_mod_idx <= 4'd0;
        end else begin
            r_mod_idx <= r_mod_idx + 4'd1;
        end
    end
end

//------------------------------------------------------------
// rcon index
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_rcon_idx <= 4'd1;
    end else if (w_start_fire) begin
        r_rcon_idx <= 4'd1;
    end else if ((r_state == STATE_RUN_WRITE) &&
                 (!w_calc_last) && (r_mod_idx == 4'd0)) begin
        r_rcon_idx <= r_rcon_idx + 4'd1;
    end
end

//------------------------------------------------------------
// calculation context
//------------------------------------------------------------
always @(posedge i_clk) begin
    if (r_state == STATE_RUN_ADDR) begin
        r_calc_word_idx  <= r_word_idx;
        r_calc_mod_idx   <= r_mod_idx;
        r_calc_prev_word <= w_prev_word;
        r_calc_nk_word   <= w_nk_word;
        r_calc_rcon_word <= w_rcon_word;
    end
end

//------------------------------------------------------------
// key words
//------------------------------------------------------------
integer wi;
always @(posedge i_clk) begin
    if (w_start_fire) begin
        for (wi = 0; wi < 60; wi = wi + 1) begin
            r_word[wi] <= 32'h00000000;
        end
        r_word[0] <= i_key[255:224];
        r_word[1] <= i_key[223:192];
        r_word[2] <= i_key[191:160];
        r_word[3] <= i_key[159:128];
        r_word[4] <= i_key[127:96];
        r_word[5] <= i_key[95:64];
        r_word[6] <= i_key[63:32];
        r_word[7] <= i_key[31:0];
    end else if (r_state == STATE_RUN_WRITE) begin
        r_word[r_calc_word_idx] <= w_next_word;
    end
end

endmodule

/*
//============================================================
// Module instance: aes_key_expand
//============================================================
aes_key_expand u_aes_key_expand
(
    .i_clk                 (i_clk),
    .i_rst_n               (i_rst_n),
    .i_start_valid         (i_start_valid),
    .o_start_ready         (o_start_ready),
    .i_key_len             (i_key_len),
    .i_key                 (i_key),
    .o_round_keys_valid    (o_round_keys_valid),
    .i_round_keys_ready    (i_round_keys_ready),
    .o_round_keys          (o_round_keys),
    .o_round_num           (o_round_num)
);
*/
