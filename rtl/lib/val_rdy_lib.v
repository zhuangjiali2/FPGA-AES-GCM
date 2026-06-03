/*=============================================================================
# File Name    : val_rdy_lib.v
# Project Name : FPGA-AES-GCM
# Author       : StreamCore-zjl
# Created Date : 2026-05-24
# Version      : v1.0
#
#=============================================================================
# Function Description:
# Valid/ready flow-control primitive library. Contains:
#   - val_rdy_one_stage      : 1-deep pipeline register
#   - val_rdy_two_entry_fifo : 2-entry elastic circular buffer
#   - val_rdy_bram_fifo      : BRAM-backed synchronous FIFO
#
#===========================================================================*/
`default_nettype wire

//============================================================
// val_rdy_one_stage : 1-deep valid/ready pipeline register
//============================================================
module val_rdy_one_stage
#(
    parameter DATA_WIDTH = 8
)
(
    input  wire                     i_clk        ,
    input  wire                     i_rst_n      ,

    input  wire                     i_din_valid  ,
    output wire                     o_din_ready  ,
    input  wire [DATA_WIDTH-1:0]    i_din        ,

    output reg                      o_dout_valid ,
    input  wire                     i_dout_ready ,
    output reg  [DATA_WIDTH-1:0]    o_dout
);

wire w_load;

assign o_din_ready = (~o_dout_valid) | i_dout_ready;
assign w_load      = i_din_valid & o_din_ready;

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
        o_dout_valid <= 1'b0;
    else if (o_din_ready)
        o_dout_valid <= i_din_valid;
end

always @(posedge i_clk) begin
    if (w_load)
        o_dout <= i_din;
end

endmodule

//============================================================
// val_rdy_two_entry_fifo : 2-entry circular elastic buffer
//============================================================
module val_rdy_two_entry_fifo
#(
    parameter DATA_WIDTH = 8
)
(
    input  wire                     i_clk        ,
    input  wire                     i_rst_n      ,

    input  wire                     i_din_valid  ,
    output wire                     o_din_ready  ,
    input  wire [DATA_WIDTH-1:0]    i_din        ,

    output wire                     o_dout_valid ,
    input  wire                     i_dout_ready ,
    output wire [DATA_WIDTH-1:0]    o_dout
);

reg  [1:0]              r_count;
reg  [DATA_WIDTH-1:0]   r_data0;
reg  [DATA_WIDTH-1:0]   r_data1;
reg                     r_wr_sel;
reg                     r_rd_sel;

wire w_push = i_din_valid & o_din_ready;
wire w_pop  = o_dout_valid & i_dout_ready;

assign o_din_ready  = (r_count != 2'd2);
assign o_dout_valid = (r_count != 2'd0);
assign o_dout       = r_rd_sel ? r_data1 : r_data0;

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
        r_count <= 2'd0;
    else
        case ({w_push, w_pop})
            2'b10:   r_count <= r_count + 2'd1;
            2'b01:   r_count <= r_count - 2'd1;
            default: r_count <= r_count;
        endcase
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_wr_sel <= 1'b0;
        r_rd_sel <= 1'b0;
    end else begin
        if (w_push) r_wr_sel <= ~r_wr_sel;
        if (w_pop)  r_rd_sel <= ~r_rd_sel;
    end
end

always @(posedge i_clk) begin
    if (w_push & (~r_wr_sel)) r_data0 <= i_din;
    if (w_push &   r_wr_sel)  r_data1 <= i_din;
end

endmodule

//============================================================
// val_rdy_bram_fifo : BRAM-backed synchronous FIFO
//============================================================
module val_rdy_bram_fifo
#(
    parameter DATA_WIDTH = 128,
    parameter ADDR_WIDTH = 5
)
(
    input  wire                     i_clk        ,
    input  wire                     i_rst_n      ,

    input  wire                     i_din_valid  ,
    output wire                     o_din_ready  ,
    input  wire [DATA_WIDTH-1:0]    i_din        ,

    output wire                     o_dout_valid ,
    input  wire                     i_dout_ready ,
    output wire [DATA_WIDTH-1:0]    o_dout
);

localparam [ADDR_WIDTH:0] FIFO_DEPTH = (1 << ADDR_WIDTH);

(* ram_style = "block" *) reg [DATA_WIDTH-1:0] r_mem [0:FIFO_DEPTH-1];
reg  [ADDR_WIDTH-1:0]   r_wr_addr;
reg  [ADDR_WIDTH-1:0]   r_rd_addr;
reg  [ADDR_WIDTH:0]     r_mem_count;
reg                     r_out_valid;
reg  [DATA_WIDTH-1:0]   r_out_data;

wire [ADDR_WIDTH:0] w_total_count = r_mem_count + {{ADDR_WIDTH{1'b0}}, r_out_valid};
wire w_push    = i_din_valid & o_din_ready;
wire w_pop     = r_out_valid & i_dout_ready;
wire w_read_mem = ((~r_out_valid) | i_dout_ready) &
                  (r_mem_count != {(ADDR_WIDTH+1){1'b0}});

assign o_din_ready  = (w_total_count != FIFO_DEPTH) | w_pop;
assign o_dout_valid = r_out_valid;
assign o_dout       = r_out_data;

always @(posedge i_clk) begin
    if (w_push) r_mem[r_wr_addr] <= i_din;
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
        r_mem_count <= {(ADDR_WIDTH+1){1'b0}};
    else
        case ({w_push, w_read_mem})
            2'b10:   r_mem_count <= r_mem_count + {{ADDR_WIDTH{1'b0}}, 1'b1};
            2'b01:   r_mem_count <= r_mem_count - {{ADDR_WIDTH{1'b0}}, 1'b1};
            default: r_mem_count <= r_mem_count;
        endcase
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n) begin
        r_wr_addr <= {ADDR_WIDTH{1'b0}};
        r_rd_addr <= {ADDR_WIDTH{1'b0}};
    end else begin
        if (w_push)     r_wr_addr <= r_wr_addr + {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
        if (w_read_mem) r_rd_addr <= r_rd_addr + {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
    end
end

always @(posedge i_clk or negedge i_rst_n) begin
    if (!i_rst_n)
        r_out_valid <= 1'b0;
    else if (w_read_mem)
        r_out_valid <= 1'b1;
    else if (w_pop)
        r_out_valid <= 1'b0;
end

always @(posedge i_clk) begin
    if (w_read_mem) r_out_data <= r_mem[r_rd_addr];
end

endmodule
