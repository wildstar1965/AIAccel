`timescale 1ns/1ps
module tb_uart_system;
  parameter SERIAL=0;
  localparam CPB=16;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  logic [7:0] rx_data=0, tx_data;
  logic rx_valid=0, rx_error=0, tx_valid, tx_ready=0;
  logic serial_rx=1, serial_tx;
  integer cycle=0, received=0;
  reg [7:0] captured[0:511];
  reg [7:0] send_buffer[0:511];
  integer expected[0:255];
  generate if (SERIAL) begin : g_serial
    nexys4ddr_top #(.CLKS_PER_BIT(CPB)) dut(
      .CLK100MHZ(clk),.CPU_RESETN(rst_n),.UART_TXD_IN(serial_rx),.UART_RXD_OUT(serial_tx));
    // Independent serial monitor, samples center of each transmitted bit.
    reg [7:0] value;
    initial forever begin
      @(negedge serial_tx);
      repeat(CPB/2) @(posedge clk);
      if (serial_tx !== 0) $fatal(1,"TX start bit");
      for(integer bitno=0;bitno<8;bitno=bitno+1) begin
        repeat(CPB) @(posedge clk); value[bitno]=serial_tx;
      end
      repeat(CPB) @(posedge clk);
      if (serial_tx !== 1) $fatal(1,"TX stop bit");
      captured[received]=value; received=received+1;
    end
  end else begin : g_bytes
    accelerator_uart_service #(.PACKET_TIMEOUT(200),.RUN_TIMEOUT(1_000_000)) dut(
      .clk,.rst_n,.rx_data,.rx_valid,.rx_error,.tx_data,.tx_valid,.tx_ready,
      .running(),.completed(),.inference_error());
    always @(negedge clk) begin cycle=cycle+1; tx_ready=(cycle%7 > 2); end
    always @(posedge clk) if (tx_valid && tx_ready) begin
      captured[received]=tx_data; received=received+1;
    end
  end endgenerate
  task automatic send_byte(input [7:0] value);
    if (SERIAL) begin
      @(negedge clk); serial_rx=0; repeat(CPB) @(negedge clk);
      for(integer b=0;b<8;b=b+1) begin serial_rx=value[b]; repeat(CPB) @(negedge clk); end
      serial_rx=1; repeat(CPB) @(negedge clk);
    end else begin
      @(negedge clk); rx_data=value; rx_valid=1;
      @(negedge clk); rx_valid=0;
      repeat(value%3) @(negedge clk);
    end
  endtask
  function automatic [15:0] crc_step(input [15:0] initial_crc,input [7:0] b);
    reg [15:0] c;
    begin
      c=initial_crc^{b,8'h00};
      repeat(8) c=c[15] ? (c<<1)^16'h1021 : c<<1;
      return c;
    end
  endfunction
  reg [2047:0] filename;
  integer fd,scan,nreq,gap,cmd,seq,nexpected,ntotal,timeout,tests=0;
  reg [15:0] crc;
  initial begin
    if (!$value$plusargs("vectors=%s",filename)) $fatal(1,"Missing vectors");
    fd=$fopen(filename,"r"); if(!fd) $fatal(1,"Cannot open vectors");
    repeat(10) @(negedge clk); rst_n=1; repeat(10) @(negedge clk);
    while (!$feof(fd)) begin
      scan=$fscanf(fd,"%d %d %d %d %d\n",nreq,gap,cmd,seq,nexpected);
      if(scan==5) begin
        for(integer i=0;i<nreq;i=i+1) scan=$fscanf(fd,"%h",send_buffer[i]);
        for(integer i=0;i<nexpected;i=i+1) scan=$fscanf(fd,"%d",expected[i]);
        repeat(gap) @(negedge clk);
        received=0;
        for(integer i=0;i<nreq;i=i+1) send_byte(send_buffer[i]);
        timeout=0;
        while(received<7 && timeout<200000) begin @(negedge clk); timeout=timeout+1; end
        if(received<7) $fatal(1,"Response header timeout transaction %0d cmd=%0h",tests,cmd);
        ntotal=9+{captured[6],captured[5]};
        while(received<ntotal && timeout<200000) begin @(negedge clk); timeout=timeout+1; end
        if(received!=ntotal || ntotal!=9+nexpected) $fatal(1,"Response size transaction %0d: got %0d expected %0d",tests,received,9+nexpected);
        if(captured[0]!==8'h55 || captured[1]!==8'haa || captured[2]!==1 ||
           captured[3]!==8'(cmd) || captured[4]!==8'(seq)) $fatal(1,"Response header transaction %0d",tests);
        crc=16'hffff;
        for(integer i=2;i<ntotal-2;i=i+1) crc=crc_step(crc,captured[i]);
        if ({captured[ntotal-1],captured[ntotal-2]} !== crc) $fatal(1,"Response CRC transaction %0d",tests);
        for(integer i=0;i<nexpected;i=i+1)
          if(expected[i]>=0 && captured[i+7]!==8'(expected[i]))
            $fatal(1,"Transaction %0d cmd=%0h payload[%0d]: got %0d expected %0d",tests,cmd,i,captured[i+7],expected[i]);
        tests=tests+1;
        repeat(SERIAL ? CPB : 10) @(negedge clk);
      end
    end
    $fclose(fd);
    $display("SYSTEM PASS: %0d transactions SERIAL=%0d",tests,SERIAL);
    $finish;
  end
  initial begin #2_000_000_000; $fatal(1,"Global system timeout"); end
endmodule
