/*=============================================================================
# File Name    : aes_rcon.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# AES key schedule round constant lookup.
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

module aes_rcon
(
    input  wire [3:0]     i_index ,
    output reg  [31:0]    o_word
);

always @(*) begin
    case (i_index)
        4'd1:    o_word = 32'h01000000;
        4'd2:    o_word = 32'h02000000;
        4'd3:    o_word = 32'h04000000;
        4'd4:    o_word = 32'h08000000;
        4'd5:    o_word = 32'h10000000;
        4'd6:    o_word = 32'h20000000;
        4'd7:    o_word = 32'h40000000;
        4'd8:    o_word = 32'h80000000;
        4'd9:    o_word = 32'h1b000000;
        4'd10:   o_word = 32'h36000000;
        default: o_word = 32'h00000000;
    endcase
end

endmodule

/*
//============================================================
// Module instance: aes_rcon
//============================================================
aes_rcon u_aes_rcon
(
    .i_index          (i_index),
    .o_word           (o_word)
);
*/
