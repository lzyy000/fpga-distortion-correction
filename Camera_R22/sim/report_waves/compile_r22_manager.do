# Local manager unit test. Source RTL is compiled read-only.
onerror {abort}
set r22_root {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves}
set r22_dir {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/manager_run}
set r22_lib r22_manager
set r22_top tb_manager
cd $r22_dir
if {![file exists $r22_lib/_info]} {vlib $r22_lib}
vmap $r22_lib [file join $r22_dir $r22_lib]
vlog -sv -work $r22_lib {+incdir+D:/pango/pango100Pro/Camera_R22_20261031/rtl} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/camera_eis_manager_r22.v} {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/manager_run/tb_manager_observe.v}
