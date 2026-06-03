/*=============================================================================
# File Name    : aes_sbox.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Email        : no use
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# AES forward S-box byte substitution. Implemented as a small standalone
# combinational ROM module, not as a large function.
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

module aes_sbox
(
    input  wire [7:0]    i_data ,
    output reg  [7:0]    o_data
);

always @(*) begin
    case (i_data)
        8'h00: o_data = 8'h63; 8'h01: o_data = 8'h7c;
        8'h02: o_data = 8'h77; 8'h03: o_data = 8'h7b;
        8'h04: o_data = 8'hf2; 8'h05: o_data = 8'h6b;
        8'h06: o_data = 8'h6f; 8'h07: o_data = 8'hc5;
        8'h08: o_data = 8'h30; 8'h09: o_data = 8'h01;
        8'h0a: o_data = 8'h67; 8'h0b: o_data = 8'h2b;
        8'h0c: o_data = 8'hfe; 8'h0d: o_data = 8'hd7;
        8'h0e: o_data = 8'hab; 8'h0f: o_data = 8'h76;
        8'h10: o_data = 8'hca; 8'h11: o_data = 8'h82;
        8'h12: o_data = 8'hc9; 8'h13: o_data = 8'h7d;
        8'h14: o_data = 8'hfa; 8'h15: o_data = 8'h59;
        8'h16: o_data = 8'h47; 8'h17: o_data = 8'hf0;
        8'h18: o_data = 8'had; 8'h19: o_data = 8'hd4;
        8'h1a: o_data = 8'ha2; 8'h1b: o_data = 8'haf;
        8'h1c: o_data = 8'h9c; 8'h1d: o_data = 8'ha4;
        8'h1e: o_data = 8'h72; 8'h1f: o_data = 8'hc0;
        8'h20: o_data = 8'hb7; 8'h21: o_data = 8'hfd;
        8'h22: o_data = 8'h93; 8'h23: o_data = 8'h26;
        8'h24: o_data = 8'h36; 8'h25: o_data = 8'h3f;
        8'h26: o_data = 8'hf7; 8'h27: o_data = 8'hcc;
        8'h28: o_data = 8'h34; 8'h29: o_data = 8'ha5;
        8'h2a: o_data = 8'he5; 8'h2b: o_data = 8'hf1;
        8'h2c: o_data = 8'h71; 8'h2d: o_data = 8'hd8;
        8'h2e: o_data = 8'h31; 8'h2f: o_data = 8'h15;
        8'h30: o_data = 8'h04; 8'h31: o_data = 8'hc7;
        8'h32: o_data = 8'h23; 8'h33: o_data = 8'hc3;
        8'h34: o_data = 8'h18; 8'h35: o_data = 8'h96;
        8'h36: o_data = 8'h05; 8'h37: o_data = 8'h9a;
        8'h38: o_data = 8'h07; 8'h39: o_data = 8'h12;
        8'h3a: o_data = 8'h80; 8'h3b: o_data = 8'he2;
        8'h3c: o_data = 8'heb; 8'h3d: o_data = 8'h27;
        8'h3e: o_data = 8'hb2; 8'h3f: o_data = 8'h75;
        8'h40: o_data = 8'h09; 8'h41: o_data = 8'h83;
        8'h42: o_data = 8'h2c; 8'h43: o_data = 8'h1a;
        8'h44: o_data = 8'h1b; 8'h45: o_data = 8'h6e;
        8'h46: o_data = 8'h5a; 8'h47: o_data = 8'ha0;
        8'h48: o_data = 8'h52; 8'h49: o_data = 8'h3b;
        8'h4a: o_data = 8'hd6; 8'h4b: o_data = 8'hb3;
        8'h4c: o_data = 8'h29; 8'h4d: o_data = 8'he3;
        8'h4e: o_data = 8'h2f; 8'h4f: o_data = 8'h84;
        8'h50: o_data = 8'h53; 8'h51: o_data = 8'hd1;
        8'h52: o_data = 8'h00; 8'h53: o_data = 8'hed;
        8'h54: o_data = 8'h20; 8'h55: o_data = 8'hfc;
        8'h56: o_data = 8'hb1; 8'h57: o_data = 8'h5b;
        8'h58: o_data = 8'h6a; 8'h59: o_data = 8'hcb;
        8'h5a: o_data = 8'hbe; 8'h5b: o_data = 8'h39;
        8'h5c: o_data = 8'h4a; 8'h5d: o_data = 8'h4c;
        8'h5e: o_data = 8'h58; 8'h5f: o_data = 8'hcf;
        8'h60: o_data = 8'hd0; 8'h61: o_data = 8'hef;
        8'h62: o_data = 8'haa; 8'h63: o_data = 8'hfb;
        8'h64: o_data = 8'h43; 8'h65: o_data = 8'h4d;
        8'h66: o_data = 8'h33; 8'h67: o_data = 8'h85;
        8'h68: o_data = 8'h45; 8'h69: o_data = 8'hf9;
        8'h6a: o_data = 8'h02; 8'h6b: o_data = 8'h7f;
        8'h6c: o_data = 8'h50; 8'h6d: o_data = 8'h3c;
        8'h6e: o_data = 8'h9f; 8'h6f: o_data = 8'ha8;
        8'h70: o_data = 8'h51; 8'h71: o_data = 8'ha3;
        8'h72: o_data = 8'h40; 8'h73: o_data = 8'h8f;
        8'h74: o_data = 8'h92; 8'h75: o_data = 8'h9d;
        8'h76: o_data = 8'h38; 8'h77: o_data = 8'hf5;
        8'h78: o_data = 8'hbc; 8'h79: o_data = 8'hb6;
        8'h7a: o_data = 8'hda; 8'h7b: o_data = 8'h21;
        8'h7c: o_data = 8'h10; 8'h7d: o_data = 8'hff;
        8'h7e: o_data = 8'hf3; 8'h7f: o_data = 8'hd2;
        8'h80: o_data = 8'hcd; 8'h81: o_data = 8'h0c;
        8'h82: o_data = 8'h13; 8'h83: o_data = 8'hec;
        8'h84: o_data = 8'h5f; 8'h85: o_data = 8'h97;
        8'h86: o_data = 8'h44; 8'h87: o_data = 8'h17;
        8'h88: o_data = 8'hc4; 8'h89: o_data = 8'ha7;
        8'h8a: o_data = 8'h7e; 8'h8b: o_data = 8'h3d;
        8'h8c: o_data = 8'h64; 8'h8d: o_data = 8'h5d;
        8'h8e: o_data = 8'h19; 8'h8f: o_data = 8'h73;
        8'h90: o_data = 8'h60; 8'h91: o_data = 8'h81;
        8'h92: o_data = 8'h4f; 8'h93: o_data = 8'hdc;
        8'h94: o_data = 8'h22; 8'h95: o_data = 8'h2a;
        8'h96: o_data = 8'h90; 8'h97: o_data = 8'h88;
        8'h98: o_data = 8'h46; 8'h99: o_data = 8'hee;
        8'h9a: o_data = 8'hb8; 8'h9b: o_data = 8'h14;
        8'h9c: o_data = 8'hde; 8'h9d: o_data = 8'h5e;
        8'h9e: o_data = 8'h0b; 8'h9f: o_data = 8'hdb;
        8'ha0: o_data = 8'he0; 8'ha1: o_data = 8'h32;
        8'ha2: o_data = 8'h3a; 8'ha3: o_data = 8'h0a;
        8'ha4: o_data = 8'h49; 8'ha5: o_data = 8'h06;
        8'ha6: o_data = 8'h24; 8'ha7: o_data = 8'h5c;
        8'ha8: o_data = 8'hc2; 8'ha9: o_data = 8'hd3;
        8'haa: o_data = 8'hac; 8'hab: o_data = 8'h62;
        8'hac: o_data = 8'h91; 8'had: o_data = 8'h95;
        8'hae: o_data = 8'he4; 8'haf: o_data = 8'h79;
        8'hb0: o_data = 8'he7; 8'hb1: o_data = 8'hc8;
        8'hb2: o_data = 8'h37; 8'hb3: o_data = 8'h6d;
        8'hb4: o_data = 8'h8d; 8'hb5: o_data = 8'hd5;
        8'hb6: o_data = 8'h4e; 8'hb7: o_data = 8'ha9;
        8'hb8: o_data = 8'h6c; 8'hb9: o_data = 8'h56;
        8'hba: o_data = 8'hf4; 8'hbb: o_data = 8'hea;
        8'hbc: o_data = 8'h65; 8'hbd: o_data = 8'h7a;
        8'hbe: o_data = 8'hae; 8'hbf: o_data = 8'h08;
        8'hc0: o_data = 8'hba; 8'hc1: o_data = 8'h78;
        8'hc2: o_data = 8'h25; 8'hc3: o_data = 8'h2e;
        8'hc4: o_data = 8'h1c; 8'hc5: o_data = 8'ha6;
        8'hc6: o_data = 8'hb4; 8'hc7: o_data = 8'hc6;
        8'hc8: o_data = 8'he8; 8'hc9: o_data = 8'hdd;
        8'hca: o_data = 8'h74; 8'hcb: o_data = 8'h1f;
        8'hcc: o_data = 8'h4b; 8'hcd: o_data = 8'hbd;
        8'hce: o_data = 8'h8b; 8'hcf: o_data = 8'h8a;
        8'hd0: o_data = 8'h70; 8'hd1: o_data = 8'h3e;
        8'hd2: o_data = 8'hb5; 8'hd3: o_data = 8'h66;
        8'hd4: o_data = 8'h48; 8'hd5: o_data = 8'h03;
        8'hd6: o_data = 8'hf6; 8'hd7: o_data = 8'h0e;
        8'hd8: o_data = 8'h61; 8'hd9: o_data = 8'h35;
        8'hda: o_data = 8'h57; 8'hdb: o_data = 8'hb9;
        8'hdc: o_data = 8'h86; 8'hdd: o_data = 8'hc1;
        8'hde: o_data = 8'h1d; 8'hdf: o_data = 8'h9e;
        8'he0: o_data = 8'he1; 8'he1: o_data = 8'hf8;
        8'he2: o_data = 8'h98; 8'he3: o_data = 8'h11;
        8'he4: o_data = 8'h69; 8'he5: o_data = 8'hd9;
        8'he6: o_data = 8'h8e; 8'he7: o_data = 8'h94;
        8'he8: o_data = 8'h9b; 8'he9: o_data = 8'h1e;
        8'hea: o_data = 8'h87; 8'heb: o_data = 8'he9;
        8'hec: o_data = 8'hce; 8'hed: o_data = 8'h55;
        8'hee: o_data = 8'h28; 8'hef: o_data = 8'hdf;
        8'hf0: o_data = 8'h8c; 8'hf1: o_data = 8'ha1;
        8'hf2: o_data = 8'h89; 8'hf3: o_data = 8'h0d;
        8'hf4: o_data = 8'hbf; 8'hf5: o_data = 8'he6;
        8'hf6: o_data = 8'h42; 8'hf7: o_data = 8'h68;
        8'hf8: o_data = 8'h41; 8'hf9: o_data = 8'h99;
        8'hfa: o_data = 8'h2d; 8'hfb: o_data = 8'h0f;
        8'hfc: o_data = 8'hb0; 8'hfd: o_data = 8'h54;
        8'hfe: o_data = 8'hbb; 8'hff: o_data = 8'h16;
        default: o_data = 8'h00;
    endcase
end

endmodule

/*
//============================================================
// Module instance: aes_sbox
//============================================================
aes_sbox u_aes_sbox
(
    .i_data           (i_data),
    .o_data           (o_data)
);
*/
