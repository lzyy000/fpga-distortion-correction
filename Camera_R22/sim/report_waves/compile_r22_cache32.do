# Local cache32 unit test. Source RTL is compiled read-only.
onerror {abort}
set r22_root {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves}
set r22_dir {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/cache32_run}
set r22_lib r22_cache32
set r22_top tb_static_cache32
cd $r22_dir
if {![file exists $r22_lib/_info]} {vlib $r22_lib}
vmap $r22_lib [file join $r22_dir $r22_lib]
vlog -sv -work $r22_lib {+incdir+D:/pango/pango100Pro/Camera_R22_20261031/rtl} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/video_row_remap_r21.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/camera_night_pixel_r19.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/camera_strength_blend_r19.v} {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/cache32_run/tb_static_cache32_observe.v}
