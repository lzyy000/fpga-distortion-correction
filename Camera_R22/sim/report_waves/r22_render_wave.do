# Paste in ModelSim: do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/r22_render_wave.do}
onerror {abort}
catch {quit -sim}
do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/compile_r22_render.do}
vsim -voptargs=+acc  -wlf render_gui.wlf $r22_lib.$r22_top
onfinish stop
view wave
delete wave *
log sim:/tb_render/clk
add wave sim:/tb_render/clk
log sim:/tb_render/dut/qv
add wave sim:/tb_render/dut/qv
log sim:/tb_render/dut/hv
add wave sim:/tb_render/dut/hv
log sim:/tb_render/dut/vv
add wave sim:/tb_render/dut/vv
log sim:/tb_render/dut/p00
add wave -radix hexadecimal sim:/tb_render/dut/p00
log sim:/tb_render/dut/p10
add wave -radix hexadecimal sim:/tb_render/dut/p10
log sim:/tb_render/dut/p01
add wave -radix hexadecimal sim:/tb_render/dut/p01
log sim:/tb_render/dut/p11
add wave -radix hexadecimal sim:/tb_render/dut/p11
log sim:/tb_render/dut/fx
add wave -radix hexadecimal sim:/tb_render/dut/fx
log sim:/tb_render/dut/fy
add wave -radix hexadecimal sim:/tb_render/dut/fy
log sim:/tb_render/dut/interpolated_pixel
add wave -radix hexadecimal sim:/tb_render/dut/interpolated_pixel
configure wave -namecolwidth 300
configure wave -valuecolwidth 110
configure wave -signalnamewidth 1
configure wave -timelineunits ns
configure wave -rowmargin 7
run -all
view wave
wave cursor time -time 6060ns 1
wave zoom range 6032ns 6128ns
wave refresh
puts {READY R22 render: finite functional test completed; scope: 128x96, 4 frames / 49152 pixels; finite RTL test with a waiting DDR transaction model}
