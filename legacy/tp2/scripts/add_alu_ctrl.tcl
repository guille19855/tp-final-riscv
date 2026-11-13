add_files -norecurse {C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL/rtl/alu_ctrl.v}
add_files -fileset sim_1 -norecurse {C:/Users/Guillee/FACU/ARQUI/PRACTICO/TPFINAL/tb/alu_ctrl_tb.v}
set_property top alu_ctrl_tb [get_filesets sim_1]
update_compile_order -fileset sim_1
puts "alu_ctrl agregado OK"
