# Local render unit test. Source RTL is compiled read-only.
onerror {abort}
set r22_root {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves}
set r22_dir {D:/pango/pango100Pro/Camera_R22_20261031/sim/report_waves/render_run}
set r22_lib r22_render
set r22_top tb_render
cd $r22_dir
if {![file exists $r22_lib/_info]} {vlib $r22_lib}
vmap $r22_lib [file join $r22_dir $r22_lib]
vlog -sv -work $r22_lib {+incdir+D:/pango/pango100Pro/Camera_R22_20261031/rtl} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/camera_eis_remap_r22.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/eis_quad_cache.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/dynamic_map.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/dynamic_mul32.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/dynamic_divide.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/camera_night_pixel_r19.v} {D:/pango/pango100Pro/Camera_R22_20261031/rtl/camera_strength_blend_r19.v} {D:/pango/pango100Pro/Camera_R22_20261031/sim/r22_eis/tb_render.v}
