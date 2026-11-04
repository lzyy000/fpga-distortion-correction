onerror {quit -code 2 -force}
do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/compile_r22_manager.do}
vsim -voptargs=+acc  -wlf manager_validation.wlf $r22_lib.$r22_top
onfinish stop
vcd file manager_validation.vcd
vcd add sim:/tb_manager/clk sim:/tb_manager/eis sim:/tb_manager/cap_done sim:/tb_manager/cap_slot sim:/tb_manager/ready sim:/tb_manager/ef sim:/tb_manager/trace_state0 sim:/tb_manager/ps sim:/tb_manager/pe sim:/tb_manager/pslt sim:/tb_manager/pdone sim:/tb_manager/de
run -all
vcd flush
quit -code 0 -force
