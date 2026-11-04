onerror {quit -code 2 -force}
set validation_root {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves}
do [file join $validation_root compile_control.do]
vsim -voptargs=+acc -wlf control_validation.wlf report_control.tb_control
onfinish stop
run -all
quit -code 0 -force
