`timescale 1ns/1ps
// Ready/valid byte input; data is captured exactly once per handshake.
module uart_tx #(parameter integer CLKS_PER_BIT = 868)(
  input logic clk, rst_n,
  input logic [7:0] data,
  input logic valid,
  output logic ready, tx
);
  localparam CW = $clog2(CLKS_PER_BIT+1);
  logic [CW-1:0] count;
  logic [3:0] bit_index;
  logic [9:0] frame;
  logic busy;
  (* IOB="TRUE" *) logic tx_reg;
  assign ready = !busy && rst_n;
  assign tx = tx_reg;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy <= 0; count <= 0; bit_index <= 0; frame <= '1; tx_reg <= 1;
    end else if (!busy) begin
      if (valid) begin
        frame <= {1'b1, data, 1'b0}; busy <= 1; count <= 0; bit_index <= 0; tx_reg <= 0;
      end
    end else if (count == CLKS_PER_BIT-1) begin
      count <= 0;
      if (bit_index == 9) begin busy <= 0; tx_reg <= 1; end
      else begin bit_index <= bit_index + 1'b1; tx_reg <= frame[bit_index+1'b1]; end
    end else count <= count + 1'b1;
  end
endmodule
