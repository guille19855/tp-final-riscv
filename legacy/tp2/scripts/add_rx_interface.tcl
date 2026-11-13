add_files -norecurse {C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL/rtl/rx_interface.v}
add_files -fileset sim_1 -norecurse {C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL/tb/rx_interface_tb.v}
set_property top rx_interface_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
puts "rx_interface agregado OK"
