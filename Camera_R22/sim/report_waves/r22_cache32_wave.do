# Paste in ModelSim: do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/r22_cache32_wave.do}
onerror {abort}
catch {quit -sim}
do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/compile_r22_cache32.do}
vsim -voptargs=+acc -gCACHE_BITS=5 -wlf cache32_gui.wlf $r22_lib.$r22_top
onfinish stop
view wave
delete wave *
log sim:/tb_static_cache32/clk
add wave sim:/tb_static_cache32/clk
log sim:/tb_static_cache32/req
add wave sim:/tb_static_cache32/req
log sim:/tb_static_cache32/accept
add wave sim:/tb_static_cache32/accept
log sim:/tb_static_cache32/write
add wave sim:/tb_static_cache32/write
log sim:/tb_static_cache32/addr
add wave -radix hexadecimal sim:/tb_static_cache32/addr
log sim:/tb_static_cache32/beats
add wave -radix unsigned sim:/tb_static_cache32/beats
log sim:/tb_static_cache32/valid
add wave sim:/tb_static_cache32/valid
log sim:/tb_static_cache32/trace_rdata0
add wave -radix hexadecimal sim:/tb_static_cache32/trace_rdata0
log sim:/tb_static_cache32/dut/cache_read_valid
add wave sim:/tb_static_cache32/dut/cache_read_valid
log sim:/tb_static_cache32/trace_cache_data0
add wave -radix hexadecimal sim:/tb_static_cache32/trace_cache_data0
configure wave -namecolwidth 300
configure wave -valuecolwidth 110
configure wave -signalnamewidth 1
configure wave -timelineunits ns
configure wave -rowmargin 7
run -all
view wave
wave cursor time -time 3028ns 1
wave zoom range 2988ns 3124ns
wave refresh
puts {READY R22 cache32: finite functional test completed; scope: 32-row cache, production width 1920, 3 sampled scanlines / 5760 pixels; DDR transaction model}
