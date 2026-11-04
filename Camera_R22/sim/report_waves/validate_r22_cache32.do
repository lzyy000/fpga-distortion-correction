onerror {quit -code 2 -force}
do {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/compile_r22_cache32.do}
vsim -voptargs=+acc -gCACHE_BITS=5 -wlf cache32_validation.wlf $r22_lib.$r22_top
onfinish stop
vcd file cache32_validation.vcd
vcd add sim:/tb_static_cache32/clk sim:/tb_static_cache32/req sim:/tb_static_cache32/accept sim:/tb_static_cache32/write sim:/tb_static_cache32/addr sim:/tb_static_cache32/beats sim:/tb_static_cache32/valid sim:/tb_static_cache32/trace_rdata0 sim:/tb_static_cache32/dut/cache_read_valid sim:/tb_static_cache32/trace_cache_data0
run -all
vcd flush
quit -code 0 -force
