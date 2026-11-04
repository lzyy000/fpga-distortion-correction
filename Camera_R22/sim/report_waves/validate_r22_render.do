onerror {quit -code 2 -force}
do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/compile_r22_render.do}
vsim -voptargs=+acc  -wlf render_validation.wlf $r22_lib.$r22_top
onfinish stop
vcd file render_validation.vcd
vcd add sim:/tb_render/clk sim:/tb_render/dut/qv sim:/tb_render/dut/hv sim:/tb_render/dut/vv sim:/tb_render/dut/p00 sim:/tb_render/dut/p10 sim:/tb_render/dut/p01 sim:/tb_render/dut/p11 sim:/tb_render/dut/fx sim:/tb_render/dut/fy sim:/tb_render/dut/interpolated_pixel
run -all
vcd flush
quit -code 0 -force
