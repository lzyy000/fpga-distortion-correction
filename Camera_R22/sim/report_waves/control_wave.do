# Run this from the ModelSim Transcript, after aborting the paused PDS macro.
onerror {abort}
catch {quit -sim}
set wave_script_root {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves}
do [file join $wave_script_root compile_control.do]
vsim -voptargs=+acc -wlf control_gui.wlf report_control.tb_control
onfinish stop
log -r sim:/tb_control/*
view wave
view structure
view signals
add wave -divider {Clock and reset}
add wave sim:/tb_control/clk sim:/tb_control/rst
add wave -divider {KEY mode and frame-boundary commit}
add wave -radix binary sim:/tb_control/keys
add wave -radix unsigned sim:/tb_control/requested sim:/tb_control/mode
add wave sim:/tb_control/edge_d
add wave -divider {Capture, processing and snapshot}
add wave sim:/tb_control/capdone sim:/tb_control/ps sim:/tb_control/pdone
add wave sim:/tb_control/snapreq sim:/tb_control/locked sim:/tb_control/snaprel
add wave -radix unsigned sim:/tb_control/captured sim:/tb_control/processed sim:/tb_control/displayed
configure wave -namecolwidth 280
configure wave -valuecolwidth 100
configure wave -timelineunits ns
run 1000ns
wave zoom range 0ns 1000ns
puts {READY: tb_control loaded and ran to 1000 ns. This is the existing R16 control test, not the R22 pixel pipeline.}
