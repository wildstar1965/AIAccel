`timescale 1ns/1ps
// Fault injection tests the externally observable error/recovery contract.
// Forced internal faults are not presented as naturally occurring arithmetic failures.
module tb_uart_faults;
  import pkg_accelerator::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [7:0] rx_data=0, tx_data, error;
  logic rx_valid=0, rx_error=0, tx_valid, tx_ready=1, running, completed;
  reg [7:0] payload[0:255], captured[0:264];
  integer received=0, transactions=0;
  reg [7:0] sequence_id=0;
  accelerator_uart_service #(.PACKET_TIMEOUT(40),.RUN_TIMEOUT(160)) dut(
    .clk,.rst_n,.rx_data,.rx_valid,.rx_error,.tx_data,.tx_valid,.tx_ready,
    .running,.completed,.inference_error(error));
  always @(posedge clk) if (tx_valid && tx_ready) begin
    if(received>=265) $fatal(1,"Unexpected extra response bytes");
    captured[received]=tx_data;
    received=received+1;
  end

  function automatic [15:0] crc_byte(input [15:0] previous,input [7:0] value);
    reg [15:0] c;
    c=previous^{value,8'h00};
    repeat(8) c=c[15] ? (c<<1)^16'h1021 : c<<1;
    return c;
  endfunction
  task automatic send_byte(input [7:0] value);
    @(negedge clk);rx_data=value;rx_valid=1;
    @(negedge clk);rx_valid=0;
  endtask
  task automatic check_reply(input [7:0] cmd,input [7:0] seq,input [7:0] status);
    integer timeout,total;
    reg [15:0] crc;
    timeout=0;
    while(received<7 && timeout<1000) begin @(negedge clk);timeout++;end
    if(received<7) $fatal(1,"Reply timeout cmd=%h",cmd);
    total=9+{captured[6],captured[5]};
    if(total<10 || total>265) $fatal(1,"Invalid response length");
    while(received<total && timeout<1000) begin @(negedge clk);timeout++;end
    if(received!=total || captured[0]!==8'h55 || captured[1]!==8'haa ||
       captured[2]!==1 || captured[3]!==(cmd|8'h80) || captured[4]!==seq ||
       captured[7]!==status) $fatal(1,"Response mismatch cmd=%h status=%h",cmd,captured[7]);
    crc=16'hffff;
    for(integer i=2;i<total-2;i++) crc=crc_byte(crc,captured[i]);
    if({captured[total-1],captured[total-2]}!==crc) $fatal(1,"Bad response CRC");
    repeat(4) @(negedge clk);
    if(received!=total) $fatal(1,"Duplicate response");
    transactions++;
  endtask
  task automatic request(input [7:0] cmd,input integer length,input [7:0] status);
    reg [15:0] crc;
    reg [7:0] value;
    received=0;
    send_byte(8'h55);send_byte(8'haa);
    crc=16'hffff;
    for(integer i=0;i<5+length;i++) begin
      case(i)
        0:value=1;
        1:value=cmd;
        2:value=sequence_id;
        3:value=8'(length);
        4:value=8'(length>>8);
        default:value=payload[i-5];
      endcase
      send_byte(value);crc=crc_byte(crc,value);
    end
    send_byte(crc[7:0]);send_byte(crc[15:8]);
    check_reply(cmd,sequence_id,status);
    sequence_id++;
  endtask
  task automatic load_identity;
    for(integer i=0;i<256;i++) payload[i]=0;
    payload[0]=8;payload[2]=8;payload[4]=1;
    request(8'h10,9,0);
    for(integer i=0;i<66;i++) payload[i]=0;
    for(integer i=0;i<8;i++) payload[2+i*8+i]=1;
    request(8'h11,66,0);
    for(integer i=0;i<8;i++) payload[2+i]=8'(i+1);
    request(8'h12,10,0);
  endtask
  task automatic check_error_and_reset(input [7:0] code);
    repeat(3) @(negedge clk);
    if(running || completed || error!==code) $fatal(1,"Fault contract: %h expected %h",error,code);
    request(2,0,0);
    if(captured[8][1:0]!==0 || captured[10]!==code) $fatal(1,"Fault not reported in STATUS");
    payload[0]=0;payload[1]=0;payload[2]=1;
    request(8'h14,3,7); // no results may be read after failure
    request(8'h15,0,0);
    request(2,0,0);
    if(captured[8]!==0 || captured[10]!==0) $fatal(1,"Reset left stale state/error");
    request(8'h13,0,7); // reset invalidates loaded tensors
  endtask
  initial begin
    repeat(10) @(negedge clk);rst_n=1;repeat(3) @(negedge clk);
    // Framing error after a partial header must produce error 10 and recover.
    received=0;
    send_byte(8'h55);send_byte(8'haa);send_byte(1);send_byte(1);send_byte(sequence_id);
    @(negedge clk);rx_error=1;
    @(negedge clk);rx_error=0;
    check_reply(1,sequence_id,10);sequence_id++;
    request(1,0,0);
    // Timeout before cmd/sequence exists uses zero for both response fields.
    received=0;send_byte(8'h55);check_reply(0,0,9);
    request(1,0,0);
    for(integer i=0;i<256;i++) payload[i]=8'(i);
    request(8'h77,256,8); // maximum transport payload accepted, command rejected
    request(8'h10,0,2);
    request(8'h11,8,2);

    load_identity();
    force dut.axis_valid=0; // missing activation: wrapper watchdog, not core watchdog
    request(8'h13,0,0);
    wait(!running);release dut.axis_valid;
    check_error_and_reset(8'h21);

    load_identity();request(8'h13,0,0);
    if(!running) $fatal(1,"Fault injection started too late");
    force dut.core_overflow=1;
    repeat(2) @(negedge clk);
    // XSim retains a released forced variable until its driver next changes.
    // Restore the idle value before release so one injection cannot leak into
    // a later test whose upstream idle driver has remained constant.
    force dut.core_overflow=0;
    @(negedge clk);release dut.core_overflow;
    check_error_and_reset(8'h20);

    load_identity();request(8'h13,0,0);
    force dut.core_error=1;force dut.core_error_code=ERR_TIMEOUT;
    repeat(2) @(negedge clk);
    force dut.core_error=0;force dut.core_error_code=ERR_NONE;
    @(negedge clk);release dut.core_error;release dut.core_error_code;
    check_error_and_reset(8'h11);

    load_identity();force dut.out_keep=0;
    request(8'h13,0,0);
    wait(!running);force dut.out_keep=8'hff;
    @(negedge clk);release dut.out_keep;
    check_error_and_reset(8'h22);

    load_identity();request(8'h13,0,0);
    force dut.core_done=1; // completion before expected results/replay finished
    repeat(2) @(negedge clk);force dut.core_done=0;
    @(negedge clk);release dut.core_done;
    check_error_and_reset(8'h22);

    // A final unmodified execution proves reset/reload restored service.
    load_identity();request(8'h13,0,0);wait(!running);
    request(2,0,0);
    if(captured[8]!==30 || captured[10]!==0) $fatal(1,"Recovery inference did not complete");
    payload[0]=0;payload[1]=0;payload[2]=1;request(8'h14,3,0);
    for(integer i=0;i<8;i++)
      if(captured[8+i]!==8'(i+1)) $fatal(1,"Recovery identity result mismatch");
    $display("UART FAULTS PASS: %0d transactions, parser recovery, watchdog, injected faults, reset/reload inference",transactions);
    $finish;
  end
  initial begin #1_000_000;$fatal(1,"Fault test timeout");end
endmodule
