`timescale 1ns/1ps
// Buffered UART command service. Tensor capacities are 1024 64-bit words each.
module accelerator_uart_service
  import pkg_accelerator::*;
  #(parameter integer PACKET_TIMEOUT = 10_000_000,
    parameter integer RUN_TIMEOUT = 100_000_000)(
  input logic clk, rst_n,
  input logic [7:0] rx_data,
  input logic rx_valid, rx_error,
  output logic [7:0] tx_data,
  output logic tx_valid,
  input logic tx_ready,
  output logic running, completed,
  output logic [7:0] inference_error
);
  localparam CMD_PING=1, CMD_STATUS=2, CMD_CONFIG=16, CMD_WEIGHTS=17,
             CMD_ACT=18, CMD_START=19, CMD_READ=20, CMD_RESET=21;
  logic [7:0] cmd, seq, req_addr, req_data, rsp_addr, rsp_data;
  logic [8:0] req_len, rsp_len;
  logic req_valid, req_ready, rsp_start, packet_busy;
  logic [31:0] rejected;
  uart_packet #(.TIMEOUT_CYCLES(PACKET_TIMEOUT)) u_packet(
    .clk, .rst_n, .rx_data, .rx_valid, .rx_error, .tx_data, .tx_valid, .tx_ready,
    .req_cmd(cmd), .req_seq(seq), .req_len, .req_valid, .req_ready,
    .req_addr, .req_data, .rsp_start, .rsp_len, .rsp_addr, .rsp_data,
    .rsp_busy(packet_busy), .rejected_packets(rejected)
  );
  (* ram_style="distributed" *) logic [7:0] response [0:255];
  assign rsp_data = response[rsp_addr];
  typedef enum logic [3:0] {IDLE, ARGS, CHECK_ARGS, DISPATCH, WRITE_BYTES, WRITE_WORD,
      READ_WORD, READ_WAIT, READ_BYTES, STATUS_BYTES, ACK, WAIT_PACKET} cmd_state_t;
  cmd_state_t state;
  logic [71:0] args;
  logic [3:0] arg_index;
  logic [7:0] reply_code;
  logic [8:0] byte_index, response_index;
  logic [10:0] word_address, words_left;
  logic [63:0] word_buffer;
  logic [191:0] status_snapshot;
  logic [4:0] status_index;
  layer_desc_t descriptor, candidate;
  logic configured;
  logic candidate_valid;
  logic [10:0] weights_loaded, acts_loaded, results_count;
  logic [10:0] weights_needed, acts_needed, results_needed;
  logic [31:0] weight_bytes, act_bytes, result_bytes;
  assign weight_bytes = 32'(candidate.in_channels) * 32'(candidate.out_channels);
  assign act_bytes = 32'(candidate.in_channels) * 32'(candidate.spatial_size);
  assign result_bytes = 32'(candidate.out_channels) * 32'(candidate.spatial_size);
  always_comb begin
    candidate = '0;
    candidate.in_channels = args[15:0];
    candidate.out_channels = args[31:16];
    candidate.spatial_size = args[47:32];
    candidate.shift_amount = args[52:48];
    candidate.zero_point = args[63:56];
    candidate.relu_enable = args[64];
  end
  assign req_ready = state == IDLE;
  assign req_addr = state == ARGS ? {4'b0,arg_index} : 8'(byte_index+2);

  // BRAM has synchronous reads and no memory reset. Completeness counters guard it.
  (* ram_style="block" *) logic [63:0] activation_mem [0:1023];
  (* ram_style="block" *) logic [63:0] result_mem [0:1023];
  logic [63:0] activation_rd, result_rd;
  logic core_start, core_busy, core_done, core_error, core_overflow;
  error_code_t core_error_code;
  logic [3:0] core_state;
  logic [31:0] counters [NUM_PERF_CTRS];
  logic [31:0] elapsed_cycles, last_cycles;
  logic [63:0] axis_in, axis_out;
  logic axis_valid, axis_ready, out_valid, out_ready, out_last;
  logic [7:0] out_keep;
  logic [10:0] activation_address;
  logic [6:0] replay_tile;
  logic feed_finished;
  typedef enum logic [1:0] {FETCH, FETCH_WAIT, PRESENT} feed_state_t;
  feed_state_t feed_state;
  logic weight_write;
  logic response_write;
  logic [7:0] response_write_addr, response_write_data;
  assign weight_write = state == WRITE_WORD && cmd == CMD_WEIGHTS;
  assign axis_in = activation_rd;
  assign axis_valid = running && feed_state == PRESENT && !feed_finished;
  assign out_ready = running && results_count < results_needed;
  // One physical write port, with address/data multiplexed before the memory.
  // Multiple indexed writes in separate case arms prevent Vivado LUTRAM inference.
  always_comb begin
    response_write = rst_n;
    response_write_addr = 0;
    response_write_data = reply_code;
    case (state)
      READ_BYTES: begin
        response_write_addr = response_index[7:0];
        response_write_data = word_buffer[byte_index[2:0]*8 +: 8];
      end
      STATUS_BYTES: begin
        response_write_addr = {3'b0,status_index}+8'd1;
        response_write_data = status_snapshot[status_index*8 +: 8];
      end
      ACK: ;
      default: response_write = 0;
    endcase
  end
  always_ff @(posedge clk) begin
    // Keep memory writes out of resettable control logic so this remains RAM.
    if (response_write) response[response_write_addr] <= response_write_data;
    if (state == WRITE_WORD && cmd == CMD_ACT)
      activation_mem[word_address[9:0]] <= word_buffer;
    if (running && feed_state == FETCH && !feed_finished)
      activation_rd <= activation_mem[activation_address[9:0]];
    if (out_valid && out_ready)
      result_mem[results_count[9:0]] <= axis_out;
    if (state == READ_WORD) result_rd <= result_mem[word_address[9:0]];
  end
  inference_accelerator_top u_core(
    .clk, .rst_n, .start(core_start), .abort_req(!running),
    .busy(core_busy), .done(core_done), .layer_desc_in(descriptor),
    .layer_desc_valid(configured && running), .layer_desc_ready(),
    .s_axis_tdata(axis_in), .s_axis_tkeep(8'hff), .s_axis_tvalid(axis_valid),
    .s_axis_tready(axis_ready),
    .s_axis_tlast(activation_address == acts_needed-1 && replay_tile == (descriptor.out_channels>>3)-1),
    .m_axis_tdata(axis_out), .m_axis_tkeep(out_keep), .m_axis_tvalid(out_valid),
    .m_axis_tready(out_ready), .m_axis_tlast(out_last),
    .wgt_wr_en(weight_write), .wgt_wr_addr(word_address[9:0]),
    .wgt_wr_data(word_buffer), .wgt_load_done(configured && weights_loaded == weights_needed),
    .current_state(core_state), .error_flag(core_error), .error_code(core_error_code),
    .any_overflow(core_overflow), .perf_counters(counters),
    .dbg_sram_active_bank(), .dbg_sram_bank_conflict(), .dbg_sram_rd_valid(),
    .dbg_act_valid(), .dbg_act_frame_last(), .dbg_quant_valid(),
    .dbg_quant_saturated(), .dbg_out_backpressure(), .dbg_wgt_load_start()
  );
  task automatic reply(input [7:0] code);
    begin reply_code <= code; rsp_len <= 1; state <= ACK; end
  endtask
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE; args <= 0; arg_index <= 0; reply_code <= 0;
      byte_index <= 0; response_index <= 0; word_address <= 0;
      words_left <= 0; word_buffer <= 0; status_snapshot <= 0; status_index <= 0;
      rsp_start <= 0; rsp_len <= 0; descriptor <= '0; configured <= 0; candidate_valid <= 0;
      weights_loaded <= 0; acts_loaded <= 0; results_count <= 0;
      weights_needed <= 0; acts_needed <= 0; results_needed <= 0;
      running <= 0; completed <= 0; inference_error <= 0; core_start <= 0;
      elapsed_cycles <= 0; last_cycles <= 0; activation_address <= 0;
      replay_tile <= 0; feed_finished <= 0; feed_state <= FETCH;
    end else begin
      rsp_start <= 0; core_start <= 0;
      if (running) begin
        elapsed_cycles <= elapsed_cycles + 1'b1;
        case (feed_state)
          FETCH: if (!feed_finished) feed_state <= FETCH_WAIT;
          FETCH_WAIT: feed_state <= PRESENT;
          PRESENT: if (axis_valid && axis_ready) begin
            feed_state <= FETCH;
            if (activation_address == acts_needed-1) begin
              activation_address <= 0;
              if (replay_tile == (descriptor.out_channels>>3)-1) feed_finished <= 1;
              else replay_tile <= replay_tile + 1'b1;
            end else activation_address <= activation_address + 1'b1;
          end
          default: feed_state <= FETCH;
        endcase
        if (out_valid && out_ready) begin
          results_count <= results_count + 1'b1;
          if (out_keep != 8'hff || out_last != (results_count == results_needed-1)) begin
            inference_error <= 8'h22; running <= 0;
          end
        end
        if (core_done) begin
          running <= 0; last_cycles <= elapsed_cycles;
          if (results_count == results_needed && feed_finished) completed <= 1;
          else inference_error <= 8'h22;
        end
        if (core_error || core_overflow || elapsed_cycles == RUN_TIMEOUT-1) begin
          running <= 0; completed <= 0; last_cycles <= elapsed_cycles;
          inference_error <= core_error ? {4'h1,core_error_code} : core_overflow ? 8'h20 : 8'h21;
        end
      end
      case (state)
        IDLE: if (req_valid) begin state <= ARGS; arg_index <= 0; args <= 0; end
        ARGS: begin
          args[arg_index*8 +: 8] <= req_data;
          if (arg_index == 8) state <= CHECK_ARGS;
          else arg_index <= arg_index + 1'b1;
        end
        // Register capacity validation before it fans out into command control.
        // This adds one clock to configuration handling, not to MAC execution.
        CHECK_ARGS: begin
          candidate_valid <= is_valid_layer_desc(candidate) && args[55:48] <= 31 &&
                             args[71:64] <= 1 && act_bytes <= 8192 && result_bytes <= 8192;
          state <= DISPATCH;
        end
        DISPATCH: begin
          if (running && cmd != CMD_PING && cmd != CMD_STATUS && cmd != CMD_RESET) reply(4);
          else case (cmd)
            CMD_PING: begin
              if (req_len != 0) reply(2);
              else begin
                // Eight bytes: magic "AI8", protocol 1, capacity 1024 words, 8x8.
                status_snapshot <= 192'h0808040001384941;
                status_index <= 0; rsp_len <= 9; reply_code <= 0; state <= STATUS_BYTES;
              end
            end
            CMD_STATUS: begin
              if (req_len != 0) reply(2);
              else begin
                // Little endian 24-byte snapshot; flags/config/error/counts/timing.
                status_snapshot <= {rejected, running ? elapsed_cycles : last_cycles,
                  5'b0,results_needed, 5'b0,acts_needed, 5'b0,weights_needed,
                  5'b0,results_count, 5'b0,acts_loaded, 5'b0,weights_loaded,
                  4'b0,core_state, inference_error,
                  8'b0, 3'b0,(acts_loaded==acts_needed && configured),
                  (weights_loaded==weights_needed && configured),configured,completed,running};
                status_index <= 0; rsp_len <= 25; reply_code <= 0; state <= STATUS_BYTES;
              end
            end
            CMD_CONFIG: begin
              if (req_len != 9) reply(2);
              else if (!candidate_valid) reply(5);
              else begin
                descriptor <= candidate; configured <= 1;
                weights_needed <= 11'(weight_bytes>>3);
                acts_needed <= 11'(act_bytes>>3); results_needed <= 11'(result_bytes>>3);
                weights_loaded <= 0; acts_loaded <= 0; results_count <= 0;
                completed <= 0; inference_error <= 0; reply(0);
              end
            end
            CMD_WEIGHTS, CMD_ACT: begin
              if (req_len < 10 || req_len > 250 || req_len[2:0] != 2) reply(2);
              else if (!configured) reply(7);
              else if (args[15:0] != (cmd == CMD_WEIGHTS ? weights_loaded : acts_loaded) ||
                (32'(args[15:0]) + ((32'(req_len)-2)>>3)) >
                 (cmd == CMD_WEIGHTS ? weights_needed : acts_needed)) reply(6);
              else begin
                word_address <= args[10:0]; words_left <= 11'((req_len-2)>>3);
                byte_index <= 0; word_buffer <= 0; completed <= 0;
                results_count <= 0; state <= WRITE_BYTES;
              end
            end
            CMD_START: begin
              if (req_len != 0) reply(2);
              else if (!configured || weights_loaded != weights_needed || acts_loaded != acts_needed) reply(7);
              else begin
                running <= 1; core_start <= 1; completed <= 0; inference_error <= 0;
                results_count <= 0; elapsed_cycles <= 0; activation_address <= 0;
                replay_tile <= 0; feed_state <= FETCH; feed_finished <= 0; reply(0);
              end
            end
            CMD_READ: begin
              if (req_len != 3 || args[23:16] == 0 || args[23:16] > 31) reply(2);
              else if (!completed || inference_error != 0) reply(7);
              else if (32'(args[15:0])+32'(args[23:16]) > results_count) reply(6);
              else begin
                word_address <= args[10:0]; words_left <= {3'b0,args[23:16]};
                response_index <= 1; byte_index <= 0; reply_code <= 0;
                rsp_len <= 1+({1'b0,args[23:16]}<<3); state <= READ_WORD;
              end
            end
            CMD_RESET: begin
              if (req_len != 0) reply(2);
              else begin
                running <= 0; completed <= 0; inference_error <= 0; configured <= 0;
                weights_loaded <= 0; acts_loaded <= 0; results_count <= 0;
                weights_needed <= 0; acts_needed <= 0; results_needed <= 0;
                last_cycles <= 0; reply(0);
              end
            end
            default: reply(8);
          endcase
        end
        WRITE_BYTES: begin
          word_buffer[byte_index[2:0]*8 +: 8] <= req_data;
          byte_index <= byte_index + 1'b1;
          if (byte_index[2:0] == 7) state <= WRITE_WORD;
        end
        WRITE_WORD: begin
          word_address <= word_address + 1'b1; words_left <= words_left-1'b1;
          if (cmd == CMD_WEIGHTS) weights_loaded <= weights_loaded + 1'b1;
          else acts_loaded <= acts_loaded + 1'b1;
          if (words_left == 1) reply(0);
          else state <= WRITE_BYTES;
        end
        READ_WORD: state <= READ_WAIT;
        READ_WAIT: begin word_buffer <= result_rd; byte_index <= 0; state <= READ_BYTES; end
        READ_BYTES: begin
          response_index <= response_index + 1'b1; byte_index <= byte_index + 1'b1;
          if (byte_index == 7) begin
            word_address <= word_address + 1'b1; words_left <= words_left-1'b1;
            if (words_left == 1) state <= ACK;
            else state <= READ_WORD;
          end
        end
        STATUS_BYTES: begin
          if (status_index == rsp_len-2) state <= ACK;
          else status_index <= status_index+1'b1;
        end
        ACK: begin rsp_start <= 1; state <= WAIT_PACKET; end
        WAIT_PACKET: if (!packet_busy) state <= IDLE;
        default: state <= IDLE;
      endcase
    end
  end
endmodule
