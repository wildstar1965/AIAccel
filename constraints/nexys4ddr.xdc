# Source: https://github.com/Digilent/digilent-xdc/blob/master/Nexys-4-DDR-Master.xdc
# Retained original: docs/Nexys-4-DDR-Master.xdc (Rev. C).
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports CLK100MHZ]
create_clock -name sys_clk -period 10.000 [get_ports CLK100MHZ]
set_property -dict {PACKAGE_PIN C12 IOSTANDARD LVCMOS33} [get_ports CPU_RESETN]
set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports UART_TXD_IN]
set_property -dict {PACKAGE_PIN D4 IOSTANDARD LVCMOS33} [get_ports UART_RXD_OUT]
# Asynchronous external signals terminate at synchronizers. Do not false-path
# the synchronizer-to-synchronizer or internal synchronous datapath paths.
set_false_path -from [get_ports UART_TXD_IN] -to [get_pins u_rx/rx_meta_reg/D]
set_false_path -from [get_ports CPU_RESETN]
# UART has no phase relationship to the PC sampling clock. Bound register-to-pad
# delay to 10 ns (0.12% of an 8680 ns bit), excluding unrelated clock insertion.
# TX is registered in an IOB; all internal paths still use the 10 ns system clock.
set_max_delay -datapath_only 10.000 -from [get_cells u_tx/tx_reg_reg] -to [get_ports UART_RXD_OUT]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
