`timescale 1ns/1ps
module tb_uart_phy;
  localparam CPB=868;
  logic clk=0,rst_n=0,rx=1,tx;
  always #5 clk=~clk;
  logic [7:0] rd,td=0;
  logic rv,re,tv=0,tr;
  integer rx_count=0,tx_count=0,errors=0;
  reg [7:0] rx_values[0:256];
  uart_rx #(.CLKS_PER_BIT(CPB)) receiver(.clk,.rst_n,.rx,.data(rd),.valid(rv),.framing_error(re));
  uart_tx #(.CLKS_PER_BIT(CPB)) transmitter(.clk,.rst_n,.data(td),.valid(tv),.ready(tr),.tx);
  always @(posedge clk) begin
    if(rv) begin rx_values[rx_count]=rd; rx_count=rx_count+1; end
    if(re) errors=errors+1;
  end
  task automatic receive_frame(input [7:0] b,input integer bit_cycles);
    @(negedge clk); rx=0; repeat(bit_cycles) @(negedge clk);
    for(integer i=0;i<8;i=i+1) begin rx=b[i]; repeat(bit_cycles) @(negedge clk); end
    rx=1; repeat(bit_cycles) @(negedge clk);
  endtask
  reg [7:0] value;
  initial forever begin
    @(negedge tx); repeat(CPB/2) @(posedge clk);
    if(tx!==0) $fatal(1,"TX bad start");
    for(integer i=0;i<8;i=i+1) begin repeat(CPB) @(posedge clk); value[i]=tx; end
    repeat(CPB) @(posedge clk);
    if(tx!==1 || value!==8'(tx_count^'h5a)) $fatal(1,"TX byte %0d got %0h",tx_count,value);
    tx_count=tx_count+1;
  end
  initial begin
    repeat(10) @(negedge clk); rst_n=1; repeat(10) @(negedge clk);
    fork
      begin
        // All byte patterns, including +/-2 percent baud mismatch.
        for(integer i=0;i<256;i=i+1) begin
          receive_frame(8'(i), i%3==0 ? 851 : i%3==1 ? 885 : 868);
          repeat(30) @(negedge clk);
          if(rx_count!=i+1 || rx_values[i]!==8'(i)) $fatal(1,"RX byte %0d",i);
        end
        // A short false start must not deliver a byte or an error.
        rx=0; repeat(CPB/4) @(negedge clk); rx=1; repeat(CPB*11) @(negedge clk);
        if(rx_count!=256 || errors!=0) $fatal(1,"False start accepted");
        // Bad stop + break: exactly one framing error, then wait for idle.
        rx=0; repeat(CPB*15) @(negedge clk); rx=1; repeat(CPB*2) @(negedge clk);
        if(rx_count!=256 || errors!=1) $fatal(1,"Break/framing recovery");
        receive_frame(8'ha5,CPB); repeat(10) @(negedge clk);
        if(rx_count!=257 || rx_values[256]!==8'ha5) $fatal(1,"Recovery byte");
      end
      begin
        for(integer i=0;i<256;i=i+1) begin
          @(negedge clk); td=8'(i^'h5a); tv=1;
          do @(posedge clk); while(!tr);
          @(negedge clk); tv=0;
        end
        wait(tx_count==256);
      end
    join
    $display("UART PHY PASS: 257 RX, 256 TX, baud tolerance, false start, framing and break recovery");
    $finish;
  end
  initial begin #100_000_000; $fatal(1,"PHY timeout"); end
endmodule
