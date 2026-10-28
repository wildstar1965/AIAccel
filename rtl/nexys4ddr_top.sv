`timescale 1ns/1ps
module nexys4ddr_top #(parameter integer CLKS_PER_BIT=868)(
  input logic CLK100MHZ,
  input logic CPU_RESETN,
  input logic UART_TXD_IN,
  output logic UART_RXD_OUT
);
  // Board button is active-low. Assert asynchronously, release on two clock edges.
  (* ASYNC_REG="TRUE" *) logic [1:0] reset_sync = 0;
  always_ff @(posedge CLK100MHZ or negedge CPU_RESETN)
    if (!CPU_RESETN) reset_sync <= 0;
    else reset_sync <= {reset_sync[0],1'b1};
  wire rst_n = reset_sync[1];
  logic [7:0] rx_data, tx_data;
  logic rx_valid, rx_error, tx_valid, tx_ready;
  uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx(
    .clk(CLK100MHZ), 
    .rst_n, 
    .rx(UART_TXD_IN), 
    .data(rx_data),
    .valid(rx_valid), 
    .framing_error(rx_error));
  uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx(
    .clk(CLK100MHZ), 
    .rst_n, 
    .data(tx_data), 
    .valid(tx_valid),
    .ready(tx_ready), 
    .tx(UART_RXD_OUT));
  accelerator_uart_service u_service(
    .clk(CLK100MHZ), 
    .rst_n, 
    .rx_data, .rx_valid, .rx_error,
    .tx_data, .tx_valid, .tx_ready, 
    .running(), .completed(), .inference_error());
endmodule
