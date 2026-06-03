/*=============================================================================
# File Name    : aes_gcm_top.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Top-level AES-GCM IP with APB3 control and AXI-Stream data interfaces.
# APB for register configuration (key, nonce, lengths, start/status).
# AXI-Stream slave for AAD+payload input, AXI-Stream master for output.
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

module aes_gcm_top
#(
    parameter FOLD_DEPTH = 8
)
(
    input  wire             i_clk              ,
    input  wire             i_rst_n            ,

    //------------------------------------------------------------
    // APB3 slave interface
    //------------------------------------------------------------
    input  wire             i_psel             ,
    input  wire             i_penable          ,
    input  wire             i_pwrite           ,
    input  wire [7:0]       i_paddr            ,
    input  wire [31:0]      i_pwdata           ,
    output wire [31:0]      o_prdata           ,
    output wire             o_pready           ,
    output wire             o_pslverr          ,

    //------------------------------------------------------------
    // AXI-Stream slave (data input: AAD then payload)
    //------------------------------------------------------------
    input  wire [127:0]     i_s_axis_tdata     ,
    input  wire             i_s_axis_tvalid    ,
    output wire             o_s_axis_tready    ,
    input  wire             i_s_axis_tlast     ,

    //------------------------------------------------------------
    // AXI-Stream master (data output: ciphertext/plaintext)
    //------------------------------------------------------------
    output wire [127:0]     o_m_axis_tdata     ,
    output wire [15:0]      o_m_axis_tkeep     ,
    output wire             o_m_axis_tvalid    ,
    input  wire             i_m_axis_tready    ,
    output wire             o_m_axis_tlast     ,

    //------------------------------------------------------------
    // interrupt
    //------------------------------------------------------------
    output wire             o_irq
);

//------------------------------------------------------------
// wire: APB regs 鈫?core
//------------------------------------------------------------
wire            w_start_pulse;
wire            w_encrypt;
wire [1:0]      w_key_len;
wire [255:0]    w_key;
wire [95:0]     w_nonce;
wire [15:0]     w_aad_bytes;
wire [15:0]     w_data_bytes;
wire [127:0]    w_tag_in;

wire            w_core_start_valid;
wire            w_core_start_ready;
wire            w_core_done_valid;
wire            w_core_done_ready;
wire [127:0]    w_core_tag_out;
wire            w_core_auth_ok;
wire            w_core_error;

wire            w_done_ack;
wire            w_busy;

//------------------------------------------------------------
// reg: start handshake
//------------------------------------------------------------
reg             r_start_pending;

//------------------------------------------------------------
// assign: start handshake bridge
// APB writes start pulse 鈫?pending flag 鈫?core start valid/ready
//------------------------------------------------------------
assign w_core_start_valid = r_start_pending;
assign w_busy = r_start_pending | (~w_core_start_ready);

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_start_pending <= 1'b0;
    end else if (r_start_pending && w_core_start_ready) begin
        r_start_pending <= 1'b0;
    end else if (w_start_pulse && !r_start_pending) begin
        r_start_pending <= 1'b1;
    end
end

//------------------------------------------------------------
// assign: done handshake bridge
// Core done_valid 鈫?APB regs capture 鈫?CPU reads 鈫?done_ack
//------------------------------------------------------------
assign w_core_done_ready = w_done_ack;

//------------------------------------------------------------
// assign: interrupt
//------------------------------------------------------------
assign o_irq = w_core_done_valid;

//------------------------------------------------------------
// sub modules
//------------------------------------------------------------
aes_gcm_apb_regs u_apb_regs
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_psel           (i_psel),
    .i_penable        (i_penable),
    .i_pwrite         (i_pwrite),
    .i_paddr          (i_paddr),
    .i_pwdata         (i_pwdata),
    .o_prdata         (o_prdata),
    .o_pready         (o_pready),
    .o_pslverr        (o_pslverr),
    .o_start_pulse    (w_start_pulse),
    .o_encrypt        (w_encrypt),
    .o_key_len        (w_key_len),
    .o_key            (w_key),
    .o_nonce          (w_nonce),
    .o_aad_bytes      (w_aad_bytes),
    .o_data_bytes     (w_data_bytes),
    .o_tag_in         (w_tag_in),
    .i_done_valid     (w_core_done_valid),
    .o_done_ack       (w_done_ack),
    .i_tag_out        (w_core_tag_out),
    .i_auth_ok        (w_core_auth_ok),
    .i_error          (w_core_error),
    .i_busy           (w_busy)
);

aes_gcm_stream_engine
#(
    .FOLD_DEPTH       (FOLD_DEPTH)
)
u_engine
(
    .i_clk            (i_clk),
    .i_rst_n          (i_rst_n),
    .i_start_valid    (w_core_start_valid),
    .o_start_ready    (w_core_start_ready),
    .i_encrypt        (w_encrypt),
    .i_key_len        (w_key_len),
    .i_key            (w_key),
    .i_nonce          (w_nonce),
    .i_aad_bytes      (w_aad_bytes),
    .i_data_bytes     (w_data_bytes),
    .i_tag            (w_tag_in),
    .i_s_valid        (i_s_axis_tvalid),
    .o_s_ready        (o_s_axis_tready),
    .i_s_data         (i_s_axis_tdata),
    .o_m_valid        (o_m_axis_tvalid),
    .i_m_ready        (i_m_axis_tready),
    .o_m_data         (o_m_axis_tdata),
    .o_m_keep         (o_m_axis_tkeep),
    .o_m_last         (o_m_axis_tlast),
    .o_done_valid     (w_core_done_valid),
    .i_done_ready     (w_core_done_ready),
    .o_tag            (w_core_tag_out),
    .o_auth_ok        (w_core_auth_ok),
    .o_error          (w_core_error)
);

endmodule

/*
//============================================================
// Module instance: aes_gcm_top
//============================================================
aes_gcm_top
#(
    .FOLD_DEPTH       (FOLD_DEPTH)
)
u_aes_gcm_top
(
    .i_clk              (i_clk),
    .i_rst_n            (i_rst_n),
    .i_psel             (i_psel),
    .i_penable          (i_penable),
    .i_pwrite           (i_pwrite),
    .i_paddr            (i_paddr),
    .i_pwdata           (i_pwdata),
    .o_prdata           (o_prdata),
    .o_pready           (o_pready),
    .o_pslverr          (o_pslverr),
    .i_s_axis_tdata     (i_s_axis_tdata),
    .i_s_axis_tvalid    (i_s_axis_tvalid),
    .o_s_axis_tready    (o_s_axis_tready),
    .i_s_axis_tlast     (i_s_axis_tlast),
    .o_m_axis_tdata     (o_m_axis_tdata),
    .o_m_axis_tkeep     (o_m_axis_tkeep),
    .o_m_axis_tvalid    (o_m_axis_tvalid),
    .i_m_axis_tready    (i_m_axis_tready),
    .o_m_axis_tlast     (o_m_axis_tlast),
    .o_irq              (o_irq)
);
*/
