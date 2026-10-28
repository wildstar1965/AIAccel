`timescale 1ns/1ps
// 8N1 receiver. Two-flop CDC, center sampling, stop-bit validation.
module uart_rx #(parameter integer CLKS_PER_BIT = 868)(
  input logic clk, rst_n, rx,
  output logic [7:0] data,
  output logic valid, framing_error
);
  (* ASYNC_REG = "TRUE" *) logic rx_meta = 1'b1, rx_sync = 1'b1;
  always_ff @(posedge clk) begin
    rx_meta <= rx;
    rx_sync <= rx_meta;
  end
  localparam CW = $clog2(CLKS_PER_BIT+1);
  typedef enum logic [2:0] {IDLE, START, DATA, STOP, BREAK_WAIT} state_t;
  state_t state;
  logic [CW-1:0] count;
  logic [2:0] bit_index;
  logic [7:0] shift;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; count <= 0; bit_index <= 0;
      shift <= 0; data <= 0; valid <= 0; framing_error <= 0;
    end else begin
      valid <= 0; framing_error <= 0;
      case (state)
        IDLE: if (!rx_sync) begin state <= START; count <= 0; end
        START: if (count == CLKS_PER_BIT/2-1) begin
          count <= 0;
          if (!rx_sync) begin state <= DATA; bit_index <= 0; end
          else state <= IDLE;
        end else count <= count + 1'b1;
        DATA: if (count == CLKS_PER_BIT-1) begin
          count <= 0; shift[bit_index] <= rx_sync;
          if (bit_index == 7) state <= STOP;
          else bit_index <= bit_index + 1'b1;
        end else count <= count + 1'b1;
        STOP: if (count == CLKS_PER_BIT-1) begin
          count <= 0;
          if (rx_sync) begin data <= shift; valid <= 1; state <= IDLE; end
          else begin framing_error <= 1; state <= BREAK_WAIT; end
        end else count <= count + 1'b1;
        BREAK_WAIT: if (rx_sync) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
