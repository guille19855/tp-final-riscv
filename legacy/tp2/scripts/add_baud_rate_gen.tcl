add_files -norecurse {C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL/rtl/baud_rate_gen.v}
add_files -fileset sim_1 -norecurse {C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL/tb/baud_rate_gen_tb.v}
set_property top baud_rate_gen_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
puts "baud_rate_gen agregado OK"
