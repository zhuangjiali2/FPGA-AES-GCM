/*=============================================================================
# File Name    : aes_sub_word_bram.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Synchronous AES key schedule SubWord transform using four BRAM-style S-box
# ROMs. The output is valid one clock after the input word is sampled by the
# internal S-box memories.
#
#=============================================================================
# Revision History:
# ----------------------------------------------------------------------------
# Date         | Author       | Version | Change Description
# ----------------------------------------------------------------------------
# 2026-05-21   | logic        | v1.0    | Initial release
# 2026-05-21   | logic        | v1.1    | Tie S-box clock enable active
# ----------------------------------------------------------------------------
#
#===========================================================================*/
`default_nettype wire

module aes_sub_word_bram
(
    input  wire           i_clk  ,
    input  wire [31:0]    i_word ,
    output wire [31:0]    o_word
);

aes_sbox_bram u_aes_sbox_bram_0
(
    .i_clk     (i_clk),
    .i_en      (1'b1),
    .i_data    (i_word[31:24]),
    .o_data    (o_word[31:24])
);

aes_sbox_bram u_aes_sbox_bram_1
(
    .i_clk     (i_clk),
    .i_en      (1'b1),
    .i_data    (i_word[23:16]),
    .o_data    (o_word[23:16])
);

aes_sbox_bram u_aes_sbox_bram_2
(
    .i_clk     (i_clk),
    .i_en      (1'b1),
    .i_data    (i_word[15:8]),
    .o_data    (o_word[15:8])
);

aes_sbox_bram u_aes_sbox_bram_3
(
    .i_clk     (i_clk),
    .i_en      (1'b1),
    .i_data    (i_word[7:0]),
    .o_data    (o_word[7:0])
);

endmodule

/*
//============================================================
// Module instance: aes_sub_word_bram
//============================================================
aes_sub_word_bram u_aes_sub_word_bram
(
    .i_clk            (i_clk),
    .i_word           (i_word),
    .o_word           (o_word)
);
*/
