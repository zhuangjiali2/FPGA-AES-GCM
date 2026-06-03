/*=============================================================================
# File Name    : aes_round.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Complete AES encryption round: SubBytes + ShiftRows + MixColumns + AddRoundKey.
# All combinational. Uses aes_sbox for SubBytes (instantiated 16 times).
# Final round bypasses MixColumns. Inactive round passes state through.
#
#===========================================================================*/
`default_nettype wire

module aes_round
(
    input  wire [127:0]    i_state       ,
    input  wire [127:0]    i_round_key   ,
    input  wire            i_active_round,
    input  wire            i_final_round ,
    output wire [127:0]    o_state
);

//------------------------------------------------------------
// wire
//------------------------------------------------------------
wire [127:0] w_sub_bytes;
wire [127:0] w_shift_rows;
wire [127:0] w_mix_columns;
wire [127:0] w_round_body;
wire [127:0] w_round_result;

//------------------------------------------------------------
// assign
//------------------------------------------------------------
assign w_round_body   = i_final_round ? w_shift_rows : w_mix_columns;
assign w_round_result = w_round_body ^ i_round_key;
assign o_state        = i_active_round ? w_round_result : i_state;

//------------------------------------------------------------
// SubBytes: 16 parallel S-box lookups
//------------------------------------------------------------
genvar si;
generate
    for (si = 0; si < 16; si = si + 1) begin : g_sbox
        aes_sbox u_sbox
        (
            .i_data    (i_state[127 - si*8 -: 8]),
            .o_data    (w_sub_bytes[127 - si*8 -: 8])
        );
    end
endgenerate

//------------------------------------------------------------
// ShiftRows: wire permutation (row 0 no shift, row 1 left 1,
//            row 2 left 2, row 3 left 3)
//------------------------------------------------------------
assign w_shift_rows = {
    w_sub_bytes[127:120], w_sub_bytes[ 87: 80],
    w_sub_bytes[ 47: 40], w_sub_bytes[  7:  0],
    w_sub_bytes[ 95: 88], w_sub_bytes[ 55: 48],
    w_sub_bytes[ 15:  8], w_sub_bytes[103: 96],
    w_sub_bytes[ 63: 56], w_sub_bytes[ 23: 16],
    w_sub_bytes[111:104], w_sub_bytes[ 71: 64],
    w_sub_bytes[ 31: 24], w_sub_bytes[119:112],
    w_sub_bytes[ 79: 72], w_sub_bytes[ 39: 32]
};

//------------------------------------------------------------
// MixColumns: 4 columns, GF(2^8) xtime multiply
//------------------------------------------------------------
genvar ci;
generate
    for (ci = 0; ci < 4; ci = ci + 1) begin : g_mix_col
        wire [7:0] a0 = w_shift_rows[127 - ci*32 -: 8];
        wire [7:0] a1 = w_shift_rows[119 - ci*32 -: 8];
        wire [7:0] a2 = w_shift_rows[111 - ci*32 -: 8];
        wire [7:0] a3 = w_shift_rows[103 - ci*32 -: 8];

        wire [7:0] a0_x2 = {a0[6:0], 1'b0} ^ (8'h1b & {8{a0[7]}});
        wire [7:0] a1_x2 = {a1[6:0], 1'b0} ^ (8'h1b & {8{a1[7]}});
        wire [7:0] a2_x2 = {a2[6:0], 1'b0} ^ (8'h1b & {8{a2[7]}});
        wire [7:0] a3_x2 = {a3[6:0], 1'b0} ^ (8'h1b & {8{a3[7]}});

        assign w_mix_columns[127 - ci*32 -: 8] = a0_x2 ^ (a1_x2 ^ a1) ^ a2    ^ a3;
        assign w_mix_columns[119 - ci*32 -: 8] = a0    ^ a1_x2 ^ (a2_x2 ^ a2) ^ a3;
        assign w_mix_columns[111 - ci*32 -: 8] = a0    ^ a1    ^ a2_x2 ^ (a3_x2 ^ a3);
        assign w_mix_columns[103 - ci*32 -: 8] = (a0_x2 ^ a0) ^ a1    ^ a2    ^ a3_x2;
    end
endgenerate

endmodule
