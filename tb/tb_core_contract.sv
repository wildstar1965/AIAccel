`timescale 1ns/1ps
module tb_core_contract;
  import pkg_accelerator::*;
  logic clk=0,rst_n=0,start=0,abort_req=0,busy,done;
  always #5 clk=~clk;
  layer_desc_t desc;
  logic desc_valid=0,desc_ready,error_flag;
  error_code_t error_code;
  logic [3:0] state;
  logic [63:0] in_data=64'h0807060504030201,out_data,wdata=0;
  logic [7:0] keep=8'h0f,out_keep;
  logic in_valid=0,in_ready,out_valid,out_ready=0,out_last;
  logic wren=0,wloaded=0;
  logic [9:0] waddr=0;
  inference_accelerator_top dut(
    .clk,.rst_n,.start,.abort_req,.busy,.done,
    .layer_desc_in(desc),.layer_desc_valid(desc_valid),.layer_desc_ready(desc_ready),
    .s_axis_tdata(in_data),.s_axis_tkeep(keep),.s_axis_tvalid(in_valid),
    .s_axis_tready(in_ready),.s_axis_tlast(1'b1),
    .m_axis_tdata(out_data),.m_axis_tkeep(out_keep),.m_axis_tvalid(out_valid),
    .m_axis_tready(out_ready),.m_axis_tlast(out_last),
    .wgt_wr_en(wren),.wgt_wr_addr(waddr),.wgt_wr_data(wdata),.wgt_load_done(wloaded),
    .current_state(state),.error_flag,.error_code,.any_overflow(),.perf_counters(),
    .dbg_sram_active_bank(),.dbg_sram_bank_conflict(),.dbg_sram_rd_valid(),
    .dbg_act_valid(),.dbg_act_frame_last(),.dbg_quant_valid(),
    .dbg_quant_saturated(),.dbg_out_backpressure(),.dbg_wgt_load_start());
  task automatic clear_core;
    @(negedge clk); abort_req=1; in_valid=0; desc_valid=0; wren=0; wloaded=0;
    repeat(3) @(negedge clk); abort_req=0;
    repeat(3) @(negedge clk);
    if(busy || done || error_flag || out_valid) $fatal(1,"Abort did not clear core");
  endtask
  task automatic begin_core(input bit supply_desc);
    @(negedge clk); start=1;
    @(negedge clk); start=0;
    wait(desc_ready);
    if(supply_desc) begin
      @(negedge clk); desc_valid=1;
      @(negedge clk); desc_valid=0;
    end
  endtask
  task automatic timeout_check;
    wait(error_flag); @(negedge clk);
    if(error_code!=ERR_TIMEOUT || busy) $fatal(1,"Watchdog error contract");
    clear_core();
  endtask
  initial begin
    desc='0; desc.in_channels=8; desc.out_channels=8; desc.spatial_size=1;
    repeat(10) @(negedge clk); rst_n=1;
    for(integer c=0;c<5;c=c+1) begin
      desc.in_channels=8; desc.out_channels=8; desc.spatial_size=1; desc.reserved=0;
      case(c)
        0: desc.in_channels=0;
        1: desc.in_channels=9;
        2: begin desc.in_channels=512;desc.out_channels=512;end
        3: desc.spatial_size=0;
        4: desc.reserved=1;
      endcase
      begin_core(1); repeat(4) @(negedge clk);
      if(!error_flag || error_code!=ERR_BAD_CONFIG || busy) $fatal(1,"Invalid descriptor %0d accepted",c);
      clear_core();
    end
    desc='0;desc.in_channels=8;desc.out_channels=8;desc.spatial_size=1;
    begin_core(0); timeout_check(); // missing descriptor
    begin_core(1); timeout_check(); // missing weights
    begin_core(1);
    wait(state==FSM_LOAD_WEIGHTS);
    @(negedge clk);wloaded=1;
    @(negedge clk);wloaded=0;
    timeout_check(); // missing activation
    begin_core(1);
    wait(state==FSM_LOAD_WEIGHTS);
    for(integer i=0;i<8;i=i+1) begin
      @(negedge clk);wren=1;waddr=10'(i);wdata=64'b1<<(i*8);
    end
    @(negedge clk);wren=0;wloaded=1;
    @(negedge clk);wloaded=0;
    repeat(53) @(negedge clk); // late input must wait safely
    in_valid=1;do @(posedge clk);while(!in_ready);
    @(negedge clk);in_valid=0;
    wait(out_valid);@(negedge clk);
    if(out_data!==64'h0000000004030201 || !out_last || out_keep!==8'hff)
      $fatal(1,"TKEEP masking or output metadata failed: %h",out_data);
    repeat(100) begin
      @(negedge clk);
      if(!out_valid || out_data!==64'h0000000004030201) $fatal(1,"Stalled result changed");
    end
    clear_core(); // abort must remove the queued result
    $display("CORE CONTRACT PASS: 5 invalid descriptors, 3 watchdogs, TKEEP, delayed input, stalled-output abort");
    $finish;
  end
  initial begin #10_000_000; $fatal(1,"Core contract timeout"); end
endmodule
