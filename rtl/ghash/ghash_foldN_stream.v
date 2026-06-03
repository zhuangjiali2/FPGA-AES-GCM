/*=============================================================================
# File Name    : ghash_foldN_stream.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Parameterized streaming GHASH fold engine. It processes GHASH blocks in groups
# up to FOLD_DEPTH using precomputed H powers and one shared multiplier pipeline.
# FOLD_DEPTH may be 4, 8, 16 or 32. The upstream context must keep i_h_powers
# stable from start until done.
#
# Based on ghash_fold32_stream.v with GROUP_SIZE replaced by FOLD_DEPTH parameter.
#
#=============================================================================
# Revision History:
# ----------------------------------------------------------------------------
# Date         | Author       | Version | Change Description
# ----------------------------------------------------------------------------
# 2026-06-03   | logic        | v1.0    | Parameterized fold depth from fold32
# ----------------------------------------------------------------------------
#===========================================================================*/
`default_nettype wire

module ghash_foldN_stream
#(
    parameter FOLD_DEPTH = 32
)
(
    input  wire             i_clk           ,
    input  wire             i_rst_n         ,

    input  wire             i_start_valid   ,
    output wire             o_start_ready   ,
    input  wire [15:0]      i_total_blocks  ,
    output wire             o_h_power_rd_en ,
    output wire [4:0]       o_h_power_rd_power,
    input  wire [127:0]     i_h_power_rd_data,

    input  wire             i_s_valid       ,
    output wire             o_s_ready       ,
    input  wire [127:0]     i_s_data        ,

    // External multiplier interface (active when MUL_EXTERNAL=1)
    output wire             o_ext_mul_valid ,
    input  wire             i_ext_mul_ready ,
    output wire [127:0]     o_ext_mul_x     ,
    output wire [127:0]     o_ext_mul_y     ,
    output wire [2:0]       o_ext_mul_meta  ,
    input  wire             i_ext_mul_done_valid,
    input  wire [127:0]     i_ext_mul_product,
    input  wire [2:0]       i_ext_mul_meta  ,

    output wire             o_done_valid    ,
    input  wire             i_done_ready    ,
    output wire [127:0]     o_hash
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam [5:0]  GROUP_SIZE    = FOLD_DEPTH[5:0];
localparam [15:0] GROUP_SIZE_16 = {{10{1'b0}}, GROUP_SIZE};
localparam SLOT_NUM = 2;

//------------------------------------------------------------
// reg
//------------------------------------------------------------
reg             r_running;
reg             r_done_valid;
reg  [127:0]    r_done_hash;
reg  [127:0]    r_hash_state;
reg  [15:0]     r_unassigned_remaining;
reg  [1:0]      r_input_slot;
reg  [1:0]      r_head_slot;
reg  [5:0]      r_input_count;
reg  [3:0]      r_groups_inflight;

reg             r_slot_active        [0:SLOT_NUM-1];
reg             r_slot_input_done    [0:SLOT_NUM-1];
reg             r_slot_state_started [0:SLOT_NUM-1];
reg             r_slot_state_valid   [0:SLOT_NUM-1];
reg  [5:0]      r_slot_size          [0:SLOT_NUM-1];
reg  [5:0]      r_slot_data_count    [0:SLOT_NUM-1];
reg  [127:0]    r_slot_data_sum      [0:SLOT_NUM-1];
reg  [127:0]    r_slot_state_term    [0:SLOT_NUM-1];

//------------------------------------------------------------
// wire
//------------------------------------------------------------
wire            w_start_fire;
wire            w_done_fire;
wire            w_zero_start;
wire [5:0]      w_first_group_size;
wire [15:0]     w_first_remaining;
wire [1:0]      w_input_next_slot;
wire [1:0]      w_head_next_slot;
wire            w_input_slot_active;
wire            w_input_slot_done;
wire [5:0]      w_input_slot_size;
wire [5:0]      w_data_power_idx;
wire            w_data_din_valid;
wire            w_data_din_ready;
wire            w_data_din_fire;
wire            w_data_dout_valid;
wire            w_data_dout_ready;
wire [127:0]    w_data_product;
wire [1:0]      w_data_meta;
wire            w_data_dout_fire;
wire            w_input_last_fire;
wire            w_next_slot_free;
wire            w_need_next_group;
wire            w_can_alloc_next;
wire [5:0]      w_next_group_size;
wire [15:0]     w_next_remaining;
wire            w_head_slot_active;
wire            w_head_input_done;
wire            w_head_state_started;
wire            w_head_state_valid;
wire [5:0]      w_head_slot_size;
wire [5:0]      w_head_data_count;
wire [127:0]    w_head_data_sum;
wire [127:0]    w_head_state_term;
wire            w_state_din_valid;
wire            w_state_din_ready;
wire            w_state_din_fire;
wire            w_state_dout_valid;
wire            w_state_dout_ready;
wire [127:0]    w_state_product;
wire [1:0]      w_state_meta;
wire            w_state_dout_fire;
wire [5:0]      w_mul_issue_power_idx;
wire            w_mul_issue_valid;
wire            w_mul_issue_ready;
wire [127:0]    w_mul_issue_x;
wire [2:0]      w_mul_issue_meta;
wire [5:0]      w_h_power_rd_power_ext;
wire [127:0]    w_mul_h_power;
wire            w_mul_din_valid;
wire            w_mul_din_ready;
wire [127:0]    w_mul_x;
wire [2:0]      w_mul_meta_in;
wire            w_mul_dout_valid;
wire            w_mul_dout_ready;
wire [127:0]    w_mul_product;
wire [2:0]      w_mul_meta_out;
wire            w_mul_dout_fire;
wire            w_head_complete;
wire [127:0]    w_next_hash_state;
wire            w_alloc_after_start;
wire            w_alloc_after_input;
wire            w_alloc_group;
wire [1:0]      w_alloc_slot;
wire [5:0]      w_alloc_size;
wire [15:0]     w_alloc_remaining;

//------------------------------------------------------------
// assign
//------------------------------------------------------------
assign o_start_ready          = (~r_running) & (~r_done_valid);
assign w_start_fire           = i_start_valid & o_start_ready;
assign w_done_fire            = r_done_valid & i_done_ready;
assign w_zero_start           = w_start_fire & (i_total_blocks == 16'd0);
assign w_first_group_size     = (i_total_blocks >= GROUP_SIZE_16) ? GROUP_SIZE :
                                {1'b0, i_total_blocks[4:0]};
assign w_first_remaining      = (i_total_blocks >= GROUP_SIZE_16) ?
                                (i_total_blocks - GROUP_SIZE_16) : 16'd0;

assign w_input_next_slot      = (r_input_slot == 2'd1) ? 2'd0 :
                                (r_input_slot + 2'd1);
assign w_head_next_slot       = (r_head_slot == 2'd1) ? 2'd0 :
                                (r_head_slot + 2'd1);
assign w_input_slot_active    = r_slot_active[r_input_slot];
assign w_input_slot_done      = r_slot_input_done[r_input_slot];
assign w_input_slot_size      = r_slot_size[r_input_slot];
assign w_data_power_idx       = w_input_slot_size - r_input_count;

assign o_s_ready              = r_running & w_input_slot_active &
                                (~w_input_slot_done) & w_data_din_ready;
assign w_data_din_valid       = i_s_valid & o_s_ready;
assign w_data_din_fire        = w_data_din_valid & w_data_din_ready;
assign w_data_din_ready       = (~w_state_din_valid) & w_mul_issue_ready;
assign w_data_dout_valid      = w_mul_dout_valid & (~w_mul_meta_out[2]);
assign w_data_dout_ready      = 1'b1;
assign w_data_product         = w_mul_product;
assign w_data_meta            = w_mul_meta_out[1:0];
assign w_data_dout_fire       = w_data_dout_valid & w_data_dout_ready;
assign w_input_last_fire      = w_data_din_fire &
                                (r_input_count == (w_input_slot_size - 6'd1));
assign w_next_slot_free       = ~r_slot_active[w_input_next_slot];
assign w_need_next_group      = (r_unassigned_remaining != 16'd0);
assign w_can_alloc_next       = w_need_next_group & w_next_slot_free;
assign w_next_group_size      = (r_unassigned_remaining >= GROUP_SIZE_16) ?
                                GROUP_SIZE :
                                {1'b0, r_unassigned_remaining[4:0]};
assign w_next_remaining       = (r_unassigned_remaining >= GROUP_SIZE_16) ?
                                (r_unassigned_remaining - GROUP_SIZE_16) : 16'd0;

assign w_head_slot_active     = r_slot_active[r_head_slot];
assign w_head_input_done      = r_slot_input_done[r_head_slot];
assign w_head_state_started   = r_slot_state_started[r_head_slot];
assign w_head_state_valid     = r_slot_state_valid[r_head_slot];
assign w_head_slot_size       = r_slot_size[r_head_slot];
assign w_head_data_count      = r_slot_data_count[r_head_slot];
assign w_head_data_sum        = r_slot_data_sum[r_head_slot];
assign w_head_state_term      = r_slot_state_term[r_head_slot];
assign w_state_din_valid      = r_running & w_head_slot_active &
                                (~w_head_state_started);
assign w_state_din_ready      = w_mul_issue_ready;
assign w_state_din_fire       = w_state_din_valid & w_state_din_ready;
assign w_state_dout_valid     = w_mul_dout_valid & w_mul_meta_out[2];
assign w_state_dout_ready     = 1'b1;
assign w_state_product        = w_mul_product;
assign w_state_meta           = w_mul_meta_out[1:0];
assign w_state_dout_fire      = w_state_dout_valid & w_state_dout_ready;
assign w_head_complete        = w_head_slot_active & w_head_input_done &
                                w_head_state_valid &
                                (w_head_data_count == w_head_slot_size);
assign w_next_hash_state      = w_head_data_sum ^ w_head_state_term;

assign w_mul_issue_power_idx  = w_state_din_valid ? w_head_slot_size :
                                w_data_power_idx;
assign w_mul_issue_valid      = w_state_din_valid | w_data_din_valid;
assign w_mul_issue_x          = w_state_din_valid ? r_hash_state : i_s_data;
assign w_mul_issue_meta       = w_state_din_valid ? {1'b1, r_head_slot} :
                                {1'b0, r_input_slot};
assign w_h_power_rd_power_ext = w_mul_issue_power_idx - 6'd1;
assign w_mul_dout_ready       = 1'b1;
assign w_mul_dout_fire        = w_mul_dout_valid & w_mul_dout_ready;

assign w_alloc_after_start    = w_start_fire & (i_total_blocks != 16'd0);
assign w_alloc_after_input    = ((w_input_last_fire & w_can_alloc_next) |
                                 (w_input_slot_active & w_input_slot_done &
                                  w_can_alloc_next));
assign w_alloc_group          = w_alloc_after_start | w_alloc_after_input;
assign w_alloc_slot           = w_alloc_after_start ? 2'd0 : w_input_next_slot;
assign w_alloc_size           = w_alloc_after_start ? w_first_group_size :
                                w_next_group_size;
assign w_alloc_remaining      = w_alloc_after_start ? w_first_remaining :
                                w_next_remaining;

assign o_done_valid           = r_done_valid;
assign o_hash                 = r_done_hash;

//------------------------------------------------------------
// slot reset and allocation
//------------------------------------------------------------
integer si;
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        for (si = 0; si < SLOT_NUM; si = si + 1) begin
            r_slot_active[si]        <= 1'b0;
            r_slot_input_done[si]    <= 1'b0;
            r_slot_state_started[si] <= 1'b0;
            r_slot_state_valid[si]   <= 1'b0;
            r_slot_size[si]          <= 6'd0;
            r_slot_data_count[si]    <= 6'd0;
            r_slot_data_sum[si]      <= 128'h0;
            r_slot_state_term[si]    <= 128'h0;
        end
    end else begin
        if (w_head_complete) begin
            r_slot_active[r_head_slot]        <= 1'b0;
            r_slot_input_done[r_head_slot]    <= 1'b0;
            r_slot_state_started[r_head_slot] <= 1'b0;
            r_slot_state_valid[r_head_slot]   <= 1'b0;
            r_slot_size[r_head_slot]          <= 6'd0;
            r_slot_data_count[r_head_slot]    <= 6'd0;
            r_slot_data_sum[r_head_slot]      <= 128'h0;
            r_slot_state_term[r_head_slot]    <= 128'h0;
        end

        if (w_alloc_group) begin
            r_slot_active[w_alloc_slot] <= 1'b1;
            r_slot_size[w_alloc_slot]   <= w_alloc_size;
        end

        if (w_input_last_fire) begin
            r_slot_input_done[r_input_slot] <= 1'b1;
        end

        if (w_state_din_fire) begin
            r_slot_state_started[r_head_slot] <= 1'b1;
        end

        if (w_state_dout_fire) begin
            r_slot_state_term[w_state_meta]  <= w_state_product;
            r_slot_state_valid[w_state_meta] <= 1'b1;
        end

        if (w_data_dout_fire) begin
            r_slot_data_sum[w_data_meta]   <= r_slot_data_sum[w_data_meta] ^
                                             w_data_product;
            r_slot_data_count[w_data_meta] <= r_slot_data_count[w_data_meta] +
                                             6'd1;
        end
    end
end

//------------------------------------------------------------
// control registers
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_running <= 1'b0;
    end else if (w_zero_start) begin
        r_running <= 1'b0;
    end else if (w_start_fire) begin
        r_running <= 1'b1;
    end else if (w_head_complete && (r_groups_inflight == 4'd1) &&
                 (r_unassigned_remaining == 16'd0)) begin
        r_running <= 1'b0;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_done_valid <= 1'b0;
        r_done_hash  <= 128'h0;
    end else if (w_done_fire) begin
        r_done_valid <= 1'b0;
    end else if (w_zero_start) begin
        r_done_valid <= 1'b1;
        r_done_hash  <= 128'h0;
    end else if (w_head_complete && (r_groups_inflight == 4'd1) &&
                 (r_unassigned_remaining == 16'd0)) begin
        r_done_valid <= 1'b1;
        r_done_hash  <= w_next_hash_state;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_hash_state <= 128'h0;
    end else if (w_start_fire) begin
        r_hash_state <= 128'h0;
    end else if (w_head_complete) begin
        r_hash_state <= w_next_hash_state;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_unassigned_remaining <= 16'd0;
    end else if (w_zero_start) begin
        r_unassigned_remaining <= 16'd0;
    end else if (w_alloc_group) begin
        r_unassigned_remaining <= w_alloc_remaining;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_input_slot <= 2'd0;
    end else if (w_start_fire) begin
        r_input_slot <= 2'd0;
    end else if (w_alloc_after_input) begin
        r_input_slot <= w_input_next_slot;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_head_slot <= 2'd0;
    end else if (w_start_fire) begin
        r_head_slot <= 2'd0;
    end else if (w_head_complete) begin
        r_head_slot <= w_head_next_slot;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_input_count <= 6'd0;
    end else if (w_start_fire) begin
        r_input_count <= 6'd0;
    end else if (w_alloc_after_input) begin
        r_input_count <= 6'd0;
    end else if (w_input_last_fire) begin
        r_input_count <= w_input_slot_size;
    end else if (w_data_din_fire) begin
        r_input_count <= r_input_count + 6'd1;
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_groups_inflight <= 4'd0;
    end else if (w_start_fire) begin
        r_groups_inflight <= (i_total_blocks == 16'd0) ? 4'd0 : 4'd1;
    end else begin
        case ({w_alloc_after_input, w_head_complete})
            2'b10: r_groups_inflight <= r_groups_inflight + 4'd1;
            2'b01: r_groups_inflight <= r_groups_inflight - 4'd1;
            default: r_groups_inflight <= r_groups_inflight;
        endcase
    end
end

//------------------------------------------------------------
// H-power BRAM read pipeline (1-cycle latency)
//------------------------------------------------------------
reg             r_direct_valid;
reg  [127:0]    r_direct_x;
reg  [2:0]      r_direct_meta;
reg  [4:0]      r_direct_power;

wire            w_direct_fire;

assign w_mul_issue_ready  = (~r_direct_valid) | w_mul_din_ready;
assign w_direct_fire      = w_mul_issue_valid & w_mul_issue_ready;
assign o_h_power_rd_en    = w_direct_fire;
assign o_h_power_rd_power = w_direct_fire ? w_h_power_rd_power_ext[4:0] :
                                            r_direct_power;
assign w_mul_din_valid    = r_direct_valid;
assign w_mul_x            = r_direct_x;
assign w_mul_meta_in      = r_direct_meta;
assign w_mul_h_power      = i_h_power_rd_data;

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
        r_direct_valid <= 1'b0;
    else if (w_mul_issue_ready)
        r_direct_valid <= w_mul_issue_valid;
end

always @(posedge i_clk) begin
    if (!i_rst_n) begin
        r_direct_x     <= 128'h0;
        r_direct_meta  <= 3'h0;
        r_direct_power <= 5'd0;
    end else if (w_direct_fire) begin
        r_direct_x     <= w_mul_issue_x;
        r_direct_meta  <= w_mul_issue_meta;
        r_direct_power <= w_h_power_rd_power_ext[4:0];
    end
end

//------------------------------------------------------------
// external multiplier interface
//------------------------------------------------------------
assign o_ext_mul_valid = w_mul_din_valid;
assign o_ext_mul_x     = w_mul_x;
assign o_ext_mul_y     = w_mul_h_power;
assign o_ext_mul_meta  = w_mul_meta_in;

assign w_mul_din_ready  = i_ext_mul_ready;
assign w_mul_dout_valid = i_ext_mul_done_valid;
assign w_mul_product    = i_ext_mul_product;
assign w_mul_meta_out   = i_ext_mul_meta;

endmodule

/*
//============================================================
// Module instance: ghash_foldN_stream
//============================================================
ghash_foldN_stream
#(
    .FOLD_DEPTH        (FOLD_DEPTH),
    .H_POWER_MODE      (H_POWER_MODE),
    .MUL_IMPL          (MUL_IMPL)
)
u_ghash_foldN_stream
(
    .i_clk             (i_clk),
    .i_rst_n           (i_rst_n),
    .i_start_valid     (i_start_valid),
    .o_start_ready     (o_start_ready),
    .i_total_blocks    (i_total_blocks),
    .i_h_powers        (i_h_powers),
    .o_h_power_rd_en   (o_h_power_rd_en),
    .o_h_power_rd_power(o_h_power_rd_power),
    .i_h_power_rd_data (i_h_power_rd_data),
    .i_s_valid         (i_s_valid),
    .o_s_ready         (o_s_ready),
    .i_s_data          (i_s_data),
    .o_done_valid      (o_done_valid),
    .i_done_ready      (i_done_ready),
    .o_hash            (o_hash)
);
*/
