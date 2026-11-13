# Fase 0: deja el proyecto Vivado apuntando a la nueva estructura de carpetas.
# Antes de correrlo, los archivos ya se movieron en disco:
#   rtl/uart/  uart_rx, uart_tx, baud_rate_gen (reutilizados del TP2)
#   tb/uart/   sus testbenches
#   legacy/tp2 todo lo del TP2 que el TP Final no usa (ALU 8 bits, interfaces)
#
# Uso (con Vivado cerrado):
#   vivado -mode batch -source scripts/fase0_reorganizar.tcl

set root [file normalize [file dirname [info script]]/..]
open_project $root/project_final/project_final.xpr

# Saca del proyecto todos los fuentes del TP2 (ya no existen en esas rutas)
foreach fs {sources_1 sim_1 constrs_1} {
    set f [get_files -quiet -of_objects [get_filesets $fs]]
    if {[llength $f] > 0} { remove_files -fileset $fs $f }
}

# Fuentes de diseno: UART del TP2 + constantes RISC-V
add_files -fileset sources_1 [glob $root/rtl/uart/*.v]
add_files -fileset sources_1 $root/rtl/cpu/riscv_defs.vh
set_property file_type {Verilog Header} [get_files riscv_defs.vh]
set_property include_dirs [list $root/rtl/cpu] [get_filesets sources_1]
set_property include_dirs [list $root/rtl/cpu] [get_filesets sim_1]

# Testbenches de la UART
add_files -fileset sim_1 [glob $root/tb/uart/*.v]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "SOURCES: [get_files -of_objects [get_filesets sources_1]]"
puts "SIM:     [get_files -of_objects [get_filesets sim_1]]"
puts "CONSTRS: [get_files -of_objects [get_filesets constrs_uart]]"
close_project
