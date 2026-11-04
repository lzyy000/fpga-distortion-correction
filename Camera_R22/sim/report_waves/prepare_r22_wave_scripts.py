"""Create ModelSim unit-test scripts and vectors from this R22 project."""
from pathlib import Path
import ast, hashlib, json, re, shutil
import numpy as np

HERE=Path(__file__).resolve().parent
P=HERE.parents[1]
ROOT=HERE.as_posix()
CASES={
 'render':dict(top='tb_render',mods=['camera_eis_remap_r22','eis_quad_cache','dynamic_map','dynamic_mul32','dynamic_divide','camera_night_pixel_r19','camera_strength_blend_r19'],params=[],window=[6032,6128],
  signals=['clk','dut.qv','dut.hv','dut.vv','dut.p00','dut.p10','dut.p01','dut.p11','dut.fx','dut.fy','dut.interpolated_pixel'],
  scope='128x96, 4 frames / 49152 pixels; finite RTL test with a waiting DDR transaction model'),
 'cache32':dict(top='tb_static_cache32',mods=['video_row_remap_r21','camera_night_pixel_r19','camera_strength_blend_r19'],params=['-gCACHE_BITS=5'],window=[2988,3124],
  signals=['clk','req','accept','write','addr','beats','valid','trace_rdata0','dut.cache_read_valid','trace_cache_data0'],
  scope='32-row cache, production width 1920, 3 sampled scanlines / 5760 pixels; DDR transaction model'),
 'manager':dict(top='tb_manager',mods=['camera_eis_manager_r22'],params=[],window=[3184,3412],
  signals=['clk','eis','cap_done','cap_slot','ready','ef','trace_state0','ps','pe','pslt','pdone','de'],
  scope='R22 four-slot finite control cases, including parameter readiness and captured mode retention')
}

def functions(file,names,namespace):
    tree=ast.parse(file.read_text(encoding='utf-8-sig'))
    selected=[node for node in tree.body if isinstance(node,ast.FunctionDef) and node.name in names]
    assert len(selected)==len(names)
    exec(compile(ast.Module(body=selected,type_ignores=[]),str(file),'exec'),namespace)
    return namespace

def put(path,text):path.write_text(text,encoding='utf-8')

originals=[P/'pnr_camera_r21_modes/camera_1080p30_raw8.pds',P/'pnr_camera_r21_modes/camera_1080p_top.fdc',P/'rtl/camera_calibration.vh',P/'rtl/night_gain.hex']
for c in CASES.values():originals += [P/'sim/r22_eis'/(c['top']+'.v')]+[P/'rtl'/(m+'.v') for m in c['mods']]
originals=sorted(set(originals))
before={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in originals}

for name,c in CASES.items():
    run=HERE/(name+'_run');run.mkdir(exist_ok=True)
    shutil.copy2(P/'rtl/night_gain.hex',run/'night_gain.hex')
    if name=='render':
        ns=functions(P/'sim/r22_eis/run_validation.py',{'s','div','lens','mapping','source','vectors'},{'P':P,'W':run})
        ns['vectors']()
    elif name=='cache32':
        ns=functions(P/'scripts/check_r22_static_cache.py',{'i32','mul','calibrated_map'},{'P':P,'np':np,'re':re})
        code=(P/'sim/r22_eis/test_static_cache32.py').read_text(encoding='utf-8-sig')
        code=code[code.index('qx,qy=calibrated_map()'):code.index('print(check())')]
        exec(compile(code,'original_static_cache_vector_generation','exec'),ns|{'O':run})
    tb=P/'sim/r22_eis'/(c['top']+'.v')
    selected=tb
    if name in {'cache32','manager'}:
        text=tb.read_text(encoding='utf-8-sig')
        if name=='cache32':
            # These performance-counter outputs are outside the pixel checks.
            text=text.replace('.take(take));','.take(take),.map_cycles(),.load_cycles(),.pipe_cycles(),.write_cycles());')
        else:
            # Explicitly disable optional fish-eye/rotation inputs for this EIS-only test.
            text=text.replace('.eis_enable(eis),',".eis_enable(eis),.fisheye_enable(1'b0),.display_fisheye(),.slot_fisheye(),.rotation_enable(1'b0),.slot_rotation(),.display_rotation(),")
        alias='wire [15:0] trace_rdata0=rd[15:0], trace_cache_data0=dut.cache_read_data[15:0];' if name=='cache32' else 'wire [2:0] trace_state0=dut.state[0];'
        assert text.count('endmodule')==1
        selected=run/(c['top']+'_observe.v')
        put(selected,text.replace('endmodule',alias+'\nendmodule'))
    paths=[P/'rtl'/(m+'.v') for m in c['mods']]+[selected]
    compile_script=f'''# Local {name} unit test. Source RTL is compiled read-only.
onerror {{abort}}
set r22_root {{{ROOT}}}
set r22_dir {{{run.as_posix()}}}
set r22_lib r22_{name}
set r22_top {c['top']}
cd $r22_dir
if {{![file exists $r22_lib/_info]}} {{vlib $r22_lib}}
vmap $r22_lib [file join $r22_dir $r22_lib]
'''
    compile_script+=f'vlog -sv -work $r22_lib {{+incdir+{(P/"rtl").as_posix()}}} '+' '.join('{'+f.as_posix()+'}' for f in paths)+'\n'
    put(HERE/f'compile_r22_{name}.do',compile_script)
    sigs=['sim:/'+c['top']+'/'+s.replace('.','/') for s in c['signals']]
    params=' '.join(c['params'])
    sim=f'vsim -voptargs=+acc {params} -wlf {name}_gui.wlf $r22_lib.$r22_top'
    header=f'''# Paste in ModelSim: do {{{ROOT}/r22_{name}_wave.do}}
onerror {{abort}}
catch {{quit -sim}}
do {{{ROOT}/compile_r22_{name}.do}}
{sim}
onfinish stop
'''
    gui=header+'view wave\ndelete wave *\n'
    for signal,path in zip(c['signals'],sigs):
        mode='hexadecimal' if signal in ['addr','trace_rdata0','trace_cache_data0'] or signal.startswith('dut.p') or signal in ['dut.fx','dut.fy','dut.interpolated_pixel'] else 'binary' if signal in ['ready','ef'] else 'unsigned'
        scalar=signal in ['clk','req','accept','write','valid','dut.cache_read_valid','dut.qv','dut.hv','dut.vv','eis','cap_done','ps','pe','pdone','de']
        gui+=f'log {path}\nadd wave '+('' if scalar else '-radix '+mode+' ')+path+'\n'
    gui+='''configure wave -namecolwidth 300
configure wave -valuecolwidth 110
configure wave -signalnamewidth 1
configure wave -timelineunits ns
configure wave -rowmargin 7
run -all
view wave
'''
    gui+='wave cursor time -time '+str(dict(render=6060,cache32=3028,manager=3292)[name])+'ns 1\n'
    gui+=f'wave zoom range {c["window"][0]}ns {c["window"][1]}ns\nwave refresh\n'
    gui+=f'puts {{READY R22 {name}: finite functional test completed; scope: {c["scope"]}}}\n'
    put(HERE/f'r22_{name}_wave.do',gui)
    validate=f'''onerror {{quit -code 2 -force}}
do {{{ROOT}/compile_r22_{name}.do}}
vsim -voptargs=+acc {params} -wlf {name}_validation.wlf $r22_lib.$r22_top
onfinish stop
vcd file {name}_validation.vcd
vcd add {' '.join(sigs)}
run -all
vcd flush
quit -code 0 -force
'''
    put(HERE/f'validate_r22_{name}.do',validate)
after={str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in originals}
assert before==after
manifest={'date':'2026-11-03','project':str(P),'inputs_unchanged':True,'source_sha256':before,'cases':CASES,'board_access':False,'pds_build':False,'gui_user_confirmation':'pending'}
put(HERE/'r22_inputs.json',json.dumps(manifest,ensure_ascii=False,indent=2))
print('Prepared all 3 R22 ModelSim scripts and fresh vectors; original inputs unchanged')
