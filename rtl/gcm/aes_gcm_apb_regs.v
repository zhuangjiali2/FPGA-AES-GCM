/*=============================================================================
# File Name    : aes_gcm_apb_regs.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# APB3 slave register file for aes_gcm_core. Provides register-based access
# to key, nonce, AAD/data lengths, encrypt/decrypt control, and status/tag
# readback. Generates a start pulse and captures completion results.
#
# Register Map (32-bit, byte-addressed):
# 0x00-0x1C  KEY_0..KEY_7       W     key[255:0]     (KEY_0 = key[31:0])
# 0x20-0x28  NONCE_0..NONCE_2   W     nonce[95:0]
# 0x2C       AAD_LEN            W     {16'h0, aad_bytes}
# 0x30       DATA_LEN           W     {16'h0, data_bytes}
# 0x34       CONFIG             W     {28'h0, key_len[1:0], encrypt, start}
# 0x38-0x44  TAG_IN_0..TAG_IN_3 W     expected tag for decrypt
# 0x48       STATUS             R     {29'h0, error, auth_ok, done}
# 0x4C-0x58  TAG_OUT_0..3       R     computed tag
# 0x5C       CTRL               W     {31'h0, done_ack}
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

module aes_gcm_apb_regs
(
    input  wire             i_clk          ,
    input  wire             i_rst_n        ,

    //------------------------------------------------------------
    // APB3 slave interface
    //------------------------------------------------------------
    input  wire             i_psel         ,
    input  wire             i_penable      ,
    input  wire             i_pwrite       ,
    input  wire [7:0]       i_paddr        ,
    input  wire [31:0]      i_pwdata       ,
    output reg  [31:0]      o_prdata       ,
    output wire             o_pready       ,
    output wire             o_pslverr      ,

    //------------------------------------------------------------
    // core command interface
    //------------------------------------------------------------
    output reg              o_start_pulse  ,
    output wire             o_encrypt      ,
    output wire [1:0]       o_key_len      ,
    output wire [255:0]     o_key          ,
    output wire [95:0]      o_nonce        ,
    output wire [15:0]      o_aad_bytes    ,
    output wire [15:0]      o_data_bytes   ,
    output wire [127:0]     o_tag_in       ,

    //------------------------------------------------------------
    // core status interface
    //------------------------------------------------------------
    input  wire             i_done_valid   ,
    output reg              o_done_ack     ,
    input  wire [127:0]     i_tag_out      ,
    input  wire             i_auth_ok      ,
    input  wire             i_error        ,
    input  wire             i_busy
);

//------------------------------------------------------------
// localparam
//------------------------------------------------------------
localparam ADDR_KEY_0    = 8'h00;
localparam ADDR_KEY_1    = 8'h04;
localparam ADDR_KEY_2    = 8'h08;
localparam ADDR_KEY_3    = 8'h0C;
localparam ADDR_KEY_4    = 8'h10;
localparam ADDR_KEY_5    = 8'h14;
localparam ADDR_KEY_6    = 8'h18;
localparam ADDR_KEY_7    = 8'h1C;
localparam ADDR_NONCE_0  = 8'h20;
localparam ADDR_NONCE_1  = 8'h24;
localparam ADDR_NONCE_2  = 8'h28;
localparam ADDR_AAD_LEN  = 8'h2C;
localparam ADDR_DATA_LEN = 8'h30;
localparam ADDR_CONFIG   = 8'h34;
localparam ADDR_TAG_IN_0 = 8'h38;
localparam ADDR_TAG_IN_1 = 8'h3C;
localparam ADDR_TAG_IN_2 = 8'h40;
localparam ADDR_TAG_IN_3 = 8'h44;
localparam ADDR_STATUS   = 8'h48;
localparam ADDR_TAG_OUT_0= 8'h4C;
localparam ADDR_TAG_OUT_1= 8'h50;
localparam ADDR_TAG_OUT_2= 8'h54;
localparam ADDR_TAG_OUT_3= 8'h58;
localparam ADDR_CTRL     = 8'h5C;

//------------------------------------------------------------
// reg: configuration registers
//------------------------------------------------------------
reg  [31:0]     r_key      [0:7];
reg  [31:0]     r_nonce    [0:2];
reg  [15:0]     r_aad_bytes;
reg  [15:0]     r_data_bytes;
reg             r_encrypt;
reg  [1:0]      r_key_len;
reg  [31:0]     r_tag_in   [0:3];

//------------------------------------------------------------
// reg: status capture
//------------------------------------------------------------
reg             r_done;
reg             r_auth_ok;
reg             r_error;
reg  [127:0]    r_tag_out;

//------------------------------------------------------------
// wire
//------------------------------------------------------------
wire            w_apb_write;
wire            w_apb_read;

//------------------------------------------------------------
// assign
//------------------------------------------------------------
assign o_pready  = 1'b1;
assign o_pslverr = 1'b0;

assign w_apb_write = i_psel & i_penable & i_pwrite;
assign w_apb_read  = i_psel & i_penable & (~i_pwrite);

assign o_encrypt   = r_encrypt;
assign o_key_len   = r_key_len;
assign o_key       = {r_key[7], r_key[6], r_key[5], r_key[4],
                      r_key[3], r_key[2], r_key[1], r_key[0]};
assign o_nonce     = {r_nonce[2], r_nonce[1], r_nonce[0]};
assign o_aad_bytes = r_aad_bytes;
assign o_data_bytes = r_data_bytes;
assign o_tag_in    = {r_tag_in[3], r_tag_in[2], r_tag_in[1], r_tag_in[0]};

//------------------------------------------------------------
// write logic
//------------------------------------------------------------
integer wi;
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        for (wi = 0; wi < 8; wi = wi + 1)
            r_key[wi] <= 32'h0;
        for (wi = 0; wi < 3; wi = wi + 1)
            r_nonce[wi] <= 32'h0;
        r_aad_bytes  <= 16'd0;
        r_data_bytes <= 16'd0;
        r_encrypt    <= 1'b1;
        r_key_len    <= 2'd0;
        for (wi = 0; wi < 4; wi = wi + 1)
            r_tag_in[wi] <= 32'h0;
    end else if (w_apb_write) begin
        case (i_paddr)
            ADDR_KEY_0:    r_key[0]     <= i_pwdata;
            ADDR_KEY_1:    r_key[1]     <= i_pwdata;
            ADDR_KEY_2:    r_key[2]     <= i_pwdata;
            ADDR_KEY_3:    r_key[3]     <= i_pwdata;
            ADDR_KEY_4:    r_key[4]     <= i_pwdata;
            ADDR_KEY_5:    r_key[5]     <= i_pwdata;
            ADDR_KEY_6:    r_key[6]     <= i_pwdata;
            ADDR_KEY_7:    r_key[7]     <= i_pwdata;
            ADDR_NONCE_0:  r_nonce[0]   <= i_pwdata;
            ADDR_NONCE_1:  r_nonce[1]   <= i_pwdata;
            ADDR_NONCE_2:  r_nonce[2]   <= i_pwdata;
            ADDR_AAD_LEN:  r_aad_bytes  <= i_pwdata[15:0];
            ADDR_DATA_LEN: r_data_bytes <= i_pwdata[15:0];
            ADDR_CONFIG: begin
                r_encrypt <= i_pwdata[1];
                r_key_len <= i_pwdata[3:2];
            end
            ADDR_TAG_IN_0: r_tag_in[0]  <= i_pwdata;
            ADDR_TAG_IN_1: r_tag_in[1]  <= i_pwdata;
            ADDR_TAG_IN_2: r_tag_in[2]  <= i_pwdata;
            ADDR_TAG_IN_3: r_tag_in[3]  <= i_pwdata;
            default: ;
        endcase
    end
end

//------------------------------------------------------------
// start pulse: CONFIG write with bit[0]=1
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        o_start_pulse <= 1'b0;
    end else begin
        o_start_pulse <= w_apb_write &
                         (i_paddr == ADDR_CONFIG) &
                         i_pwdata[0];
    end
end

//------------------------------------------------------------
// done ack: CTRL write with bit[0]=1
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        o_done_ack <= 1'b0;
    end else begin
        o_done_ack <= w_apb_write &
                      (i_paddr == ADDR_CTRL) &
                      i_pwdata[0];
    end
end

//------------------------------------------------------------
// status capture
//------------------------------------------------------------
always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_done    <= 1'b0;
        r_auth_ok <= 1'b0;
        r_error   <= 1'b0;
        r_tag_out <= 128'h0;
    end else if (o_done_ack) begin
        r_done    <= 1'b0;
        r_auth_ok <= 1'b0;
        r_error   <= 1'b0;
    end else if (i_done_valid && !r_done) begin
        r_done    <= 1'b1;
        r_auth_ok <= i_auth_ok;
        r_error   <= i_error;
        r_tag_out <= i_tag_out;
    end
end

//------------------------------------------------------------
// read logic
//------------------------------------------------------------
always @(*) begin
    o_prdata = 32'h0;
    if (w_apb_read) begin
        case (i_paddr)
            ADDR_STATUS:   o_prdata = {29'h0, r_error, r_auth_ok, r_done};
            ADDR_TAG_OUT_0: o_prdata = r_tag_out[31:0];
            ADDR_TAG_OUT_1: o_prdata = r_tag_out[63:32];
            ADDR_TAG_OUT_2: o_prdata = r_tag_out[95:64];
            ADDR_TAG_OUT_3: o_prdata = r_tag_out[127:96];
            ADDR_KEY_0:    o_prdata = r_key[0];
            ADDR_KEY_1:    o_prdata = r_key[1];
            ADDR_KEY_2:    o_prdata = r_key[2];
            ADDR_KEY_3:    o_prdata = r_key[3];
            ADDR_KEY_4:    o_prdata = r_key[4];
            ADDR_KEY_5:    o_prdata = r_key[5];
            ADDR_KEY_6:    o_prdata = r_key[6];
            ADDR_KEY_7:    o_prdata = r_key[7];
            ADDR_NONCE_0:  o_prdata = r_nonce[0];
            ADDR_NONCE_1:  o_prdata = r_nonce[1];
            ADDR_NONCE_2:  o_prdata = r_nonce[2];
            ADDR_AAD_LEN:  o_prdata = {16'h0, r_aad_bytes};
            ADDR_DATA_LEN: o_prdata = {16'h0, r_data_bytes};
            ADDR_TAG_IN_0: o_prdata = r_tag_in[0];
            ADDR_TAG_IN_1: o_prdata = r_tag_in[1];
            ADDR_TAG_IN_2: o_prdata = r_tag_in[2];
            ADDR_TAG_IN_3: o_prdata = r_tag_in[3];
            default:       o_prdata = 32'h0;
        endcase
    end
end

endmodule

/*
//============================================================
// Module instance: aes_gcm_apb_regs
//============================================================
aes_gcm_apb_regs u_aes_gcm_apb_regs
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
    .o_start_pulse    (o_start_pulse),
    .o_encrypt        (o_encrypt),
    .o_key_len        (o_key_len),
    .o_key            (o_key),
    .o_nonce          (o_nonce),
    .o_aad_bytes      (o_aad_bytes),
    .o_data_bytes     (o_data_bytes),
    .o_tag_in         (o_tag_in),
    .i_done_valid     (i_done_valid),
    .o_done_ack       (o_done_ack),
    .i_tag_out        (i_tag_out),
    .i_auth_ok        (i_auth_ok),
    .i_error          (i_error),
    .i_busy           (i_busy)
);
*/
