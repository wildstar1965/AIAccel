`timescale 1ns/1ps
// Stop-and-wait, CRC-16/CCITT-FALSE framed transport. See docs/UART_PROTOCOL.md.
// Request RAM is immutable from CRC acceptance until response transmission ends.
module uart_packet #(parameter integer TIMEOUT_CYCLES = 10_000_000)(
  input logic clk, rst_n,
  input logic [7:0] rx_data,
  input logic rx_valid, rx_error,
  output logic [7:0] tx_data,
  output logic tx_valid,
  input logic tx_ready,
  output logic [7:0] req_cmd, req_seq,
  output logic [8:0] req_len,
  output logic req_valid,
  input logic req_ready,
  input logic [7:0] req_addr,
  output logic [7:0] req_data,
  input logic rsp_start,
  input logic [8:0] rsp_len,
  output logic [7:0] rsp_addr,
  input logic [7:0] rsp_data,
  output logic rsp_busy,
  output logic [31:0] rejected_packets
);
  function automatic [15:0] crc_byte(input [15:0] crc, input [7:0] value);
    reg [15:0] c;
    begin
      c = crc ^ {value, 8'b0};
      for (integer i=0; i<8; i=i+1) c = c[15] ? (c << 1)^16'h1021 : c << 1;
      return c;
    end
  endfunction
  typedef enum logic [3:0] {SYNC0, SYNC1, HEADER, PAYLOAD, CRC0, CRC1,
                            COMMAND, RESPONSE, SEND} state_t;
  state_t state;
  (* ram_style = "distributed" *) logic [7:0] payload [0:255];
  logic [2:0] header_index;
  logic [8:0] payload_index;
  logic [7:0] version, len_low, crc_low;
  logic [15:0] rx_crc, tx_crc;
  logic [$clog2(TIMEOUT_CYCLES+1)-1:0] timeout_count;
  logic [8:0] send_length;
  logic [9:0] send_index;
  logic internal_error;
  logic [7:0] transport_error;
  assign req_data = payload[req_addr];
  assign req_valid = state == COMMAND;
  assign rsp_busy = state != SYNC0 && state != SYNC1;
  assign rsp_addr = 8'(send_index-7);
  assign tx_valid = state == SEND;
  always_comb begin
    case (send_index)
      0: tx_data = 8'h55;
      1: tx_data = 8'haa;
      2: tx_data = 1;
      3: tx_data = req_cmd | 8'h80;
      4: tx_data = req_seq;
      5: tx_data = send_length[7:0];
      6: tx_data = {7'b0,send_length[8]};
      default: begin
        if (send_index == 7 + send_length) tx_data = tx_crc[7:0];
        else if (send_index == 8 + send_length) tx_data = tx_crc[15:8];
        else tx_data = internal_error ? transport_error : rsp_data;
      end
    endcase
  end
  task automatic reject(input logic [7:0] code);
    begin
      transport_error <= code; internal_error <= 1;
      send_length <= 1; send_index <= 0; tx_crc <= 16'hffff;
      rejected_packets <= rejected_packets + 1'b1;
      state <= SEND;
    end
  endtask
  always_ff @(posedge clk) begin
    if (state == PAYLOAD && rx_valid && !rx_error)
      payload[payload_index[7:0]] <= rx_data;
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= SYNC0; req_cmd <= 0; req_seq <= 0; req_len <= 0;
      header_index <= 0; payload_index <= 0; version <= 0; len_low <= 0;
      rx_crc <= 16'hffff; crc_low <= 0; timeout_count <= 0;
      send_length <= 0; send_index <= 0; tx_crc <= 16'hffff;
      internal_error <= 0; transport_error <= 0; rejected_packets <= 0;
    end else begin
      if (rx_valid || state == SYNC0 || state >= COMMAND) timeout_count <= 0;
      else timeout_count <= timeout_count + 1'b1;
      if (state < COMMAND && state != SYNC0 &&
          (rx_error || (!rx_valid && timeout_count == TIMEOUT_CYCLES-1))) begin
        reject(rx_error ? 8'd10 : 8'd9);
      end else case (state)
        SYNC0: if (rx_valid && rx_data == 8'h55 && !rx_error) begin
          state <= SYNC1; req_cmd <= 0; req_seq <= 0;
        end
        SYNC1: if (rx_valid) begin
          if (rx_data == 8'haa) begin
            state <= HEADER; header_index <= 0; rx_crc <= 16'hffff;
          end else if (rx_data != 8'h55) state <= SYNC0;
        end
        HEADER: if (rx_valid) begin
          rx_crc <= crc_byte(rx_crc, rx_data);
          header_index <= header_index + 1'b1;
          case (header_index)
            0: version <= rx_data;
            1: req_cmd <= rx_data;
            2: req_seq <= rx_data;
            3: len_low <= rx_data;
            4: begin
              payload_index <= 0;
              req_len <= {rx_data[0],len_low};
              if ({rx_data,len_low} > 256) reject(8'd2);
              else if ({rx_data,len_low} == 0) state <= CRC0;
              else state <= PAYLOAD;
            end
            default: state <= SYNC0;
          endcase
        end
        PAYLOAD: if (rx_valid) begin
          rx_crc <= crc_byte(rx_crc, rx_data);
          if (payload_index == req_len-1) state <= CRC0;
          else payload_index <= payload_index + 1'b1;
        end
        CRC0: if (rx_valid) begin crc_low <= rx_data; state <= CRC1; end
        CRC1: if (rx_valid) begin
          if ({rx_data,crc_low} != rx_crc) reject(8'd1);
          else if (version != 1) reject(8'd3);
          else state <= COMMAND;
        end
        COMMAND: if (req_ready) state <= RESPONSE;
        RESPONSE: if (rsp_start) begin
          internal_error <= 0; send_length <= rsp_len;
          send_index <= 0; tx_crc <= 16'hffff; state <= SEND;
        end
        SEND: if (tx_ready) begin
          if (send_index >= 2 && send_index < 7+send_length)
            tx_crc <= crc_byte(tx_crc,tx_data);
          if (send_index == 8+send_length) state <= SYNC0;
          else send_index <= send_index + 1'b1;
        end
        default: state <= SYNC0;
      endcase
    end
  end
endmodule
