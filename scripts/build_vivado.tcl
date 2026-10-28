# Run from the repository root: vivado -mode batch -source scripts/build_vivado.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root build vivado]
if {[llength $argv] > 0} {set out [file normalize [lindex $argv 0]]}
file mkdir $out
set_param general.maxThreads 8
create_project -in_memory -part xc7a100tcsg324-1
set_property target_language Verilog [current_project]
foreach name {pkg_accelerator mac_unit systolic_array sram_controller axi_stream_input axi_stream_output quantize_unit layer_ctrl_fsm inference_accelerator_top uart_rx uart_tx uart_packet accelerator_uart_service nexys4ddr_top} {
    read_verilog -sv [file join $root rtl ${name}.sv]
}
read_xdc [file join $root constraints nexys4ddr.xdc]
synth_design -top nexys4ddr_top -part xc7a100tcsg324-1
write_checkpoint -force [file join $out synthesized.dcp]
report_utilization -hierarchical -file [file join $out utilization_synth.rpt]
report_timing_summary -file [file join $out timing_synth.rpt]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $out routed.dcp]
report_utilization -file [file join $out utilization_routed.rpt]
set timing_summary [report_timing_summary -delay_type min_max -check_timing_verbose -report_unconstrained -return_string -file [file join $out timing_routed.rpt]]
report_timing -max_paths 10 -file [file join $out critical_paths.rpt]
report_route_status -file [file join $out route_status.rpt]
report_drc -file [file join $out drc.rpt]
report_methodology -file [file join $out methodology.rpt]
report_cdc -file [file join $out cdc.rpt]
set tx_paths [get_timing_paths -from [get_cells u_tx/tx_reg_reg] -to [get_ports UART_RXD_OUT] -max_paths 1]
if {[llength $tx_paths] != 1} {error "UART output is not timed"}
report_timing -from [get_cells u_tx/tx_reg_reg] -to [get_ports UART_RXD_OUT] -file [file join $out uart_output_timing.rpt]
if {[get_property REQUIREMENT $tx_paths] != 10.0} {error "UART output max-delay constraint missing"}
set setup_paths [get_timing_paths -delay_type max -max_paths 1]
set hold_paths [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {error "Missing timed paths"}
set wns [get_property SLACK $setup_paths]
set whs [get_property SLACK $hold_paths]
set errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
set unrouted [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIAL}]
# Fail closed if clock coverage, internal endpoint coverage, loops, or pulse-width
# checks are missing or failing. The two asynchronous input exceptions are in XDC.
foreach check {no_clock constant_clock unconstrained_internal_endpoints loops latch_loops} {
    set pattern [format {checking %s \(([0-9]+)\)} $check]
    if {![regexp $pattern $timing_summary -> count] || $count != 0} {
        error "Timing coverage check failed: $check; inspect timing_routed.rpt"
    }
}
set summary_pattern {\n\s*([-0-9.]+)\s+([-0-9.]+)\s+([0-9]+)\s+([0-9]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([0-9]+)\s+([0-9]+)\s+([-0-9.]+)\s+([-0-9.]+)\s+([0-9]+)\s+([0-9]+)}
if {![regexp $summary_pattern $timing_summary -> sw st sf se hw ht hf he pw pt pf pe]} {
    error "Missing setup/hold/pulse-width summary"
}
if {$sf != 0 || $hf != 0 || $pf != 0} {error "Timing summary has failing endpoints"}
set f [open [file join $out result.txt] w]
puts $f "PART=xc7a100tcsg324-1\nWNS_NS=$wns\nWHS_NS=$whs\nWPWS_NS=$pw\nDRC_ERRORS=[llength $errors]\nUNROUTED_NETS=[llength $unrouted]\nTIMING_COVERAGE_PASS=1"
close $f
if {$wns < 0 || $whs < 0 || [llength $errors] > 0 || [llength $unrouted] > 0} {
    error "Implementation gates failed; inspect reports. Bitstream not generated."
}
write_bitstream -force [file join $out nexys4ddr_top.bit]
set f [open [file join $out result.txt] a]
puts $f "BITSTREAM_GENERATED=1"
close $f
puts "BUILD PASS: WNS=$wns ns WHS=$whs ns"
