# Compile only the dependencies of sim/r16/tb_snapshot_views.v.
# The board-level encrypted DDR/PLL IP is outside this unit test.
onerror {abort}
set report_root {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves}
set project_root [file normalize [file join $report_root ../..]]
set result_dir [file join $report_root control_run]
file mkdir $result_dir
cd $result_dir
if {![file exists report_control/_info]} {vlib report_control}
vmap report_control [file join $result_dir report_control]
vlog -sv -work report_control \
    [file join $project_root rtl camera_view_control.v] \
    [file join $project_root rtl camera_corrected_manager.v] \
    [file join $project_root rtl camera_engine_arbiter.v] \
    [file join $project_root sim r16 tb_snapshot_views.v]
