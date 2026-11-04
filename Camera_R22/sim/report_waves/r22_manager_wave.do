# Paste in ModelSim: do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/r22_manager_wave.do}
onerror {abort}
catch {quit -sim}
do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/compile_r22_manager.do}
vsim -voptargs=+acc  -wlf manager_gui.wlf $r22_lib.$r22_top
onfinish stop
view wave
delete wave *
log sim:/tb_manager/clk
add wave sim:/tb_manager/clk
log sim:/tb_manager/eis
add wave sim:/tb_manager/eis
log sim:/tb_manager/cap_done
add wave sim:/tb_manager/cap_done
log sim:/tb_manager/cap_slot
add wave -radix unsigned sim:/tb_manager/cap_slot
log sim:/tb_manager/ready
add wave -radix binary sim:/tb_manager/ready
log sim:/tb_manager/ef
add wave -radix binary sim:/tb_manager/ef
log sim:/tb_manager/trace_state0
add wave -radix unsigned sim:/tb_manager/trace_state0
log sim:/tb_manager/ps
add wave sim:/tb_manager/ps
log sim:/tb_manager/pe
add wave sim:/tb_manager/pe
log sim:/tb_manager/pslt
add wave -radix unsigned sim:/tb_manager/pslt
log sim:/tb_manager/pdone
add wave sim:/tb_manager/pdone
log sim:/tb_manager/de
add wave sim:/tb_manager/de
configure wave -namecolwidth 300
configure wave -valuecolwidth 110
configure wave -signalnamewidth 1
configure wave -timelineunits ns
configure wave -rowmargin 7
run -all
view wave
wave cursor time -time 3292ns 1
wave zoom range 3184ns 3412ns
wave refresh
puts {READY R22 manager: finite functional test completed; scope: R22 four-slot finite control cases, including parameter readiness and captured mode retention}
