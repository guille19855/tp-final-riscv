# uso: vivado -mode batch -source measure.tcl -tclargs <etiqueta>
# Sintetiza top_core (OOC) con un clock de 10 ns para medir fmax = 1/(10 - WNS)
# post-sintesis y post-route. Mismos fuentes que el proyecto.
set tag [lindex $argv 0]
set root C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL
set_part xc7a35tcpg236-1
foreach f [concat [glob $root/rtl/cpu/*.v] [glob $root/rtl/debug/*.v] [glob $root/rtl/uart/*.v] [list $root/rtl/top/top_core.v $root/rtl/board/seven_seg.v]] { read_verilog $f }
read_checkpoint instr_mem.dcp
read_checkpoint data_mem.dcp
synth_design -top top_core -part xc7a35tcpg236-1 -mode out_of_context -include_dirs $root/rtl/cpu
create_clock -period 10.000 -name clk [get_ports clk]
report_timing_summary -max_paths 5 -file ${tag}_synth_timing.rpt
report_timing -max_paths 1 -nworst 1 -file ${tag}_synth_path.rpt
report_utilization -file ${tag}_util.rpt
set wns_s [get_property SLACK [get_timing_paths -max_paths 1]]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -max_paths 5 -file ${tag}_route_timing.rpt
report_timing -max_paths 1 -nworst 1 -file ${tag}_route_path.rpt
set wns_r [get_property SLACK [get_timing_paths -max_paths 1]]
puts "RESULT $tag synth WNS=$wns_s fmax=[format %.1f [expr 1000.0/(10.0-$wns_s)]] MHz | route WNS=$wns_r fmax=[format %.1f [expr 1000.0/(10.0-$wns_r)]] MHz"
