"""R29 visual shell bound to the existing R22 camera controller."""
from pathlib import Path
import tkinter as tk
from tkinter import ttk
from PIL import Image, ImageTk
from fusion_widgets import (BG, WHITE, INK, MUTED, BLUE, BORDER, GREEN, FONT,
                            styles, label, card, Badge, FlatTabs, ScrollPane, ImageView, Switch)
from quality_panel import QualityPanel
from tuning import MODE_DEFS


class ModeSwitch(Switch):
    """Keep the acknowledged controller's button API while drawing a switch."""
    def __init__(self, parent, text='开启', command=None, state='disabled', width=None):
        self.action_text=text
        self.mode_variable=tk.BooleanVar(master=parent, value=False)
        super().__init__(parent, self.mode_variable, command)
        self.configure(text=text, state=state)

    def configure(self, cnf=None, **kw):
        if isinstance(cnf, dict):kw.update(cnf);cnf=None
        text=kw.pop('text', None);state=kw.pop('state', None)
        if text is not None:
            self.action_text=text
            if text in ('开启', '关闭'):self.mode_variable.set(text=='关闭')
        if state is not None:self.state(['disabled' if state=='disabled' else '!disabled'])
        if kw or cnf is not None:return super().configure(cnf, **kw)
    config=configure

    def cget(self, key):
        if key=='text':return self.action_text
        return super().cget(key)


def build_console(self, project):
    root=self.root
    tk.Frame(root,bg=BLUE,height=4).pack(fill='x')
    head=tk.Frame(root,bg=WHITE);head.pack(fill='x');self.header_frame=head
    asset=Path(__file__).parent/'assets/contest_logo.png'
    self.logo_loaded=False
    if asset.is_file():
        with Image.open(asset) as im:logo=im.convert('RGB');logo.thumbnail((190,60),Image.Resampling.LANCZOS)
        self.logo_photo=ImageTk.PhotoImage(logo,master=root)
        icon=Image.new('RGB',(64,64),WHITE)
        small=logo.copy();small.thumbnail((60,60),Image.Resampling.LANCZOS)
        icon.paste(small,((64-small.width)//2,(64-small.height)//2))
        self.window_icon=ImageTk.PhotoImage(icon,master=root)
        root.iconphoto(True,self.window_icon)
        self.logo_loaded=True
        tk.Label(head,image=self.logo_photo,bg=WHITE).pack(side='left',padx=(18,16),pady=10)
        tk.Frame(head,bg=BORDER,width=1,height=40).pack(side='left',padx=(0,16))
    brand=tk.Frame(head,bg=WHITE);brand.pack(side='left',pady=13)
    label(brand,'FPGA 视觉控制台',size=19,bold=True,anchor='w').pack(fill='x')
    label(brand,'1080P 图像采集与处理  /  独立算法控制',size=9,color=MUTED,anchor='w').pack(fill='x',pady=(3,0))
    badges=tk.Frame(head,bg=WHITE);badges.pack(side='right',padx=18)
    self.serial_badge=Badge(badges,'串口 · 未连接');self.serial_badge.grid(row=0,column=0,padx=(0,7))
    self.net_badge=Badge(badges,'以太网 · 未连接');self.net_badge.grid(row=0,column=1)
    self.header_state=tk.StringVar(value='等待连接')
    label(badges,variable=self.header_state,size=8,color=MUTED).grid(row=1,column=0,columnspan=2,sticky='e',pady=(5,0))
    # Keep branding visible when the full banner gives space to the workspace.
    self.compact_header=tk.Frame(root,bg=WHITE)
    if self.logo_loaded:
        compact=logo.copy();compact.thumbnail((100,32),Image.Resampling.LANCZOS)
        self.compact_logo_photo=ImageTk.PhotoImage(compact,master=root)
        self.compact_logo_label=tk.Label(self.compact_header,image=self.compact_logo_photo,bg=WHITE)
        self.compact_logo_label.pack(side='left',padx=(16,12),pady=4)
    label(self.compact_header,'FPGA 视觉控制台',size=12,bold=True).pack(side='left',pady=7)
    label(self.compact_header,variable=self.header_state,size=8,color=MUTED).pack(side='right',padx=18)
    body=tk.Frame(root,bg=BG);body.pack(fill='both',expand=True,padx=16,pady=(13,7));self.body_frame=body
    body.columnconfigure(0,weight=0,minsize=352);body.columnconfigure(1,weight=1)
    body.rowconfigure(1,weight=1)
    sidebar=card(body);sidebar.grid(row=0,column=0,rowspan=2,sticky='nsew',padx=(0,12))
    sidebar.configure(width=352);sidebar.grid_propagate(False);sidebar.pack_propagate(False);self.sidebar_frame=sidebar
    self.side_tabs=FlatTabs(sidebar,style='Side');self.side_tabs.pack(fill='both',expand=True,padx=5,pady=6)
    devices=tk.Frame(self.side_tabs,bg=WHITE);tuning_tab=tk.Frame(self.side_tabs,bg=WHITE);health=tk.Frame(self.side_tabs,bg=WHITE)
    for pane,title in ((devices,'设备连接'),(tuning_tab,'图像处理'),(health,'运行状态')):self.side_tabs.add(pane,text=title)
    device_scroll=ScrollPane(devices);device_scroll.pack(fill='both',expand=True)
    build_connections(self,device_scroll.content)
    tuning_canvas=tk.Canvas(tuning_tab,bg=WHITE,highlightthickness=0)
    bar=ttk.Scrollbar(tuning_tab,orient='vertical',command=tuning_canvas.yview)
    bar.pack(side='right',fill='y');tuning_canvas.pack(side='left',fill='both',expand=True);tuning_canvas.configure(yscrollcommand=bar.set)
    tuning_card=card(tuning_canvas,'八项算法控制','镜头模型互斥，两种稳像互斥；其他模式可组合')
    window=tuning_canvas.create_window(0,0,window=tuning_card,anchor='nw')
    tuning_card.bind('<Configure>',lambda e:tuning_canvas.configure(scrollregion=tuning_canvas.bbox('all')))
    tuning_canvas.bind('<Configure>',lambda e:tuning_canvas.itemconfigure(window,width=e.width))
    self.tuning_canvas=tuning_canvas
    build_controls(self,tuning_card)
    metrics=tk.Frame(body,bg=BG);metrics.grid(row=0,column=1,sticky='ew',pady=(0,10));self.metrics_frame=metrics
    self.metrics={}
    for n,(key,title,unit) in enumerate((('sensor','传感器帧率','fps'),('cap','完整采集帧率','fps'),('display','显示新画面','fps'),('bad','RAW 坏帧','帧 / 秒'))):
        metrics.columnconfigure(n,weight=1,uniform='metrics')
        c=card(metrics);c.grid(row=0,column=n,sticky='ew',padx=(0,7 if n<3 else 0))
        label(c,title,size=9,color=MUTED,anchor='w').pack(fill='x',padx=12,pady=(9,1))
        row=tk.Frame(c,bg=WHITE);row.pack(fill='x',padx=12,pady=(0,8))
        var=tk.StringVar(value='—');value=label(row,variable=var,size=22,bold=True,anchor='w');value.pack(side='left')
        label(row,unit,size=8,color=MUTED).pack(side='left',padx=5,pady=(9,0));self.metrics[key]=(var,value)
    status=ScrollPane(health);status.pack(fill='both',expand=True)
    for title,variable in (('串口连接',self.serial_state),('图像通道',self.network_state),('模式确认',self.tuning_status),('IMU 小抖动防抖',self.eis_status),('旋转稳像',self.rotation_status)):
        c=card(status.content,title);c.pack(fill='x',padx=5,pady=5)
        label(c,variable=variable,color=MUTED,size=9,wraplength=285,justify='left',anchor='w').pack(fill='x',padx=13,pady=(0,13))
    self.workspace=FlatTabs(body);self.workspace.grid(row=1,column=1,sticky='nsew')
    self.photo_tab=tk.Frame(self.workspace,bg=BG);self.quality_tab=tk.Frame(self.workspace,bg=BG);self.calib_tab=tk.Frame(self.workspace,bg=BG)
    for pane,title in ((self.photo_tab,'以太网照片'),(self.quality_tab,'图像质量'),(self.calib_tab,'镜头标定')):self.workspace.add(pane,text=title)
    build_photo(self,self.photo_tab)
    self.quality_panel=QualityPanel(self.quality_tab,self,project);self.quality_panel.pack(fill='both',expand=True)
    build_calibration(self,self.calib_tab)
    logs_card=card(body);logs_card.grid(row=2,column=0,columnspan=2,sticky='ew',pady=(10,0));self.logs_card=logs_card
    tools=tk.Frame(logs_card,bg=WHITE);tools.pack(side='right',padx=7,pady=7)
    ttk.Button(tools,text='保存日志',command=self.save_log,style='Quiet.TButton').pack()
    self.log_toggle=ttk.Button(tools,text='收起日志',command=self.toggle_logs,style='Quiet.TButton');self.log_toggle.pack()
    self.logs_tabs=FlatTabs(logs_card,style='Logs',height=67);self.logs_tabs.pack(side='left',fill='both',expand=True)
    self.logs={}
    for key,title in (('serial','串口与控制'),('network','以太网与照片')):
        pane=tk.Frame(self.logs_tabs,bg=WHITE);self.logs_tabs.add(pane,text=title)
        text=tk.Text(pane,bg=WHITE,fg=INK,font=('Consolas',9),wrap='none',relief='flat',padx=11,pady=7,state='disabled',height=3)
        bar=ttk.Scrollbar(pane,command=text.yview);bar.pack(side='right',fill='y');text.configure(yscrollcommand=bar.set);text.pack(fill='both',expand=True);self.logs[key]=text
    self.bottom_state=tk.StringVar(value='就绪 · 原尺寸抓拍 / CRC 校验 / 标定 / 图像质量分析')
    self.footer=self.bottom_state
    label(root,variable=self.bottom_state,size=8,color=MUTED,anchor='w').pack(fill='x',padx=18,pady=(0,8))
    self.workspace.on_select=self._workspace_layout
    self.side_tabs.on_select=self._responsive
    self._logs_visible=None;self.root.bind('<Configure>',self._responsive,add='+')
    self.root.bind('<Control-Return>',lambda e:self.capture())
    self.root.bind('<Control-s>',lambda e:self.save_log())
    self._workspace_layout();self.root.after_idle(self._responsive)


def build_photo(self,parent):
    c=card(parent);c.pack(fill='both',expand=True);c.columnconfigure(0,weight=1);c.rowconfigure(1,weight=1)
    head=tk.Frame(c,bg=WHITE);head.grid(row=0,column=0,sticky='ew',padx=14,pady=(12,8))
    label(head,'完整帧照片',size=13,bold=True).pack(side='left')
    ttk.Button(head,text='设备与控制',command=self.show_photo_devices,style='Quiet.TButton').pack(side='left',padx=6)
    ttk.Button(head,text='日志',command=self.toggle_logs,style='Quiet.TButton').pack(side='left')
    self.photo_badge=Badge(head,'等待拍摄');self.photo_badge.pack(side='right')
    self.preview=ImageView(c,zoomable=True);self.preview.grid(row=1,column=0,sticky='nsew',padx=13)
    self.quality_info=tk.StringVar(value='棋盘格：9 × 6 内角点 / 25 mm；等待完整照片')
    label(c,variable=self.quality_info,size=9,color=GREEN,anchor='w',wraplength=760,justify='left').grid(row=2,column=0,sticky='ew',padx=15,pady=(7,3))
    self.photo_info=tk.StringVar(value='原尺寸 1920 × 1080 · 双击 100% / 适应窗口，原尺寸可拖动')
    label(c,variable=self.photo_info,size=8,color=MUTED,anchor='w',wraplength=760).grid(row=3,column=0,sticky='ew',padx=15,pady=(0,7))
    self.progress=ttk.Progressbar(c,maximum=100);self.progress.grid(row=4,column=0,sticky='ew',padx=15,pady=(0,8))
    actions=tk.Frame(c,bg=WHITE);actions.grid(row=5,column=0,sticky='ew',padx=14,pady=(0,7))
    self.capture_button=ttk.Button(actions,text='拍照并接收',style='Primary.TButton',command=self.capture,state='disabled');self.capture_button.pack(side='left')
    self.cancel_capture_button=ttk.Button(actions,text='取消',command=self.cancel_network,state='disabled');self.cancel_capture_button.pack(side='left',padx=5)
    ttk.Button(actions,text='打开照片',command=self.open_photo,style='Quiet.TButton').pack(side='left')
    self.open_button=ttk.Button(actions,text='保存目录',command=self.open_output,style='Quiet.TButton');self.open_button.pack(side='left',padx=4)
    self.history_button=ttk.Button(actions,text='最近照片',command=self.open_recent_menu,style='Quiet.TButton');self.history_button.pack(side='right')
    ttk.Button(actions,text='查看大图',command=self.open_large_photo,style='Quiet.TButton').pack(side='right')
    row=tk.Frame(c,bg=WHITE);row.grid(row=6,column=0,sticky='ew',padx=14,pady=(0,7))
    self.output=tk.StringVar(value=self.settings['output'])
    label(row,'保存位置',size=8,color=MUTED).pack(side='left',padx=(0,6));ttk.Entry(row,textvariable=self.output).pack(side='left',fill='x',expand=True)
    ttk.Button(row,text='选择',command=self.choose_output,style='Quiet.TButton').pack(side='right',padx=(5,0))
    row=tk.Frame(c,bg=WHITE);row.grid(row=7,column=0,sticky='ew',padx=14,pady=(0,10))
    ttk.Button(row,text='送入 A',command=lambda:self.send_quality(0),style='Quiet.TButton').pack(side='left')
    ttk.Button(row,text='送入 B',command=lambda:self.send_quality(1),style='Quiet.TButton').pack(side='left',padx=4)
    ttk.Button(row,text='计算标定参数',command=self.calibrate,style='Quiet.TButton').pack(side='right')
    ttk.Button(row,text='适应窗口',command=self.preview.fit,style='Quiet.TButton').pack(side='right',padx=4)


def build_calibration(self,parent):
    pane=ScrollPane(parent);pane.pack(fill='both',expand=True)
    c=card(pane.content,'镜头标定','沿用原工程的完整帧采集、质量筛选和候选参数计算');c.pack(fill='x')
    for title,text in [('01  采集棋盘照片','使用 10 × 7 方格、9 × 6 内角点、边长 25 mm 的棋盘。关闭增强与几何处理，固定焦点，至少采集12张清晰完整且姿态不同的照片。'),('02  计算与复核候选','从当前保存目录读取原尺寸照片，结果写入 calibration_candidate.json。请结合逐帧误差、参数稳定性与实际效果复核候选。')]:
        label(c,title,size=12,bold=True,anchor='w').pack(fill='x',padx=20,pady=(15,7))
        label(c,text,size=10,color=MUTED,anchor='w',justify='left',wraplength=720).pack(fill='x',padx=20,pady=(0,10))
    row=tk.Frame(c,bg=WHITE);row.pack(fill='x',padx=20,pady=(4,16))
    ttk.Button(row,text='前往拍照',command=lambda:self.workspace.select(self.photo_tab)).pack(side='left')
    self.calibrate_button=ttk.Button(row,text='计算标定参数',command=self.calibrate,style='Primary.TButton');self.calibrate_button.pack(side='left',padx=8)
    label(c,variable=self.quality_info,size=10,color=MUTED,anchor='w',justify='left',wraplength=720).pack(fill='x',padx=20,pady=(0,18))
    label(c,'候选参数保存在电脑；计算操作不会写入板卡或改变当前算法。',size=9,color=MUTED,anchor='w',wraplength=720).pack(fill='x',padx=20,pady=(0,18))


def build_controls(self,tuning_card):
    tuning_canvas=self.tuning_canvas
    self.strength_vars={};self.strength_labels={};self.strength_scales={};self.strength_acks={}
    self.strength_widgets={};self.mode_rows={};self.mode_buttons={}
    self.algorithm_states={key:False for key,_,_ in MODE_DEFS}
    self.applied_states={'night':False,'denoise':False}
    for key,title,_ in MODE_DEFS:
        row=tk.Frame(tuning_card,bg=WHITE);row.pack(fill='x',padx=18,pady=(10,0))
        self.mode_rows[key]=row
        self.label(row,title,anchor='w').pack(side='left')
        button=ModeSwitch(row,text='开启',command=lambda k=key:self.mode_clicked(k),state='disabled',width=7)
        button.pack(side='right');self.mode_buttons[key]=button
        if key in ('denoise','night','ghe'):
            label=tk.StringVar(value='100%');self.strength_labels[key]=label
            tk.Label(row,textvariable=label,bg=WHITE,fg=BLUE,font=('Microsoft YaHei UI',10,'bold')).pack(side='right',padx=(0,9))
            var=tk.DoubleVar(value=100);self.strength_vars[key]=var
            scale=ttk.Scale(tuning_card,from_=0,to=100,variable=var,command=lambda value,k=key:self.strength_changed(k,value),state='disabled')
            self.strength_scales[key]=scale
            ack=tk.StringVar(value='等待板卡确认');self.strength_acks[key]=ack
            ack_widget=tk.Label(tuning_card,textvariable=ack,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),anchor='w')
            self.strength_widgets[key]=(scale,ack_widget)
    self.eis_vars={};self.eis_entries=[]
    panel=tk.LabelFrame(tuning_card,text='防抖参数 · R22',bg=WHITE,fg=INK,font=('Microsoft YaHei UI',10))
    panel.pack(fill='x',padx=18,pady=(14,0))
    specs=[('zoom_milli','裁切倍率',1.18,1.05,1.60,.01),('tau_ms','上下 / 滚转平滑 (ms)',250,100,1500,10),
           ('yaw_tau_ms','左右平滑 (ms)',500,100,1500,10),('rs_milli','卷帘修正 (%)',100,0,100,5),
           ('frame_offset_us','画面时刻偏移 (ms)',0,-50,50,1),('imu_delay_us','IMU 延迟 (ms)',0,-50,50,1)]
    for key,title,default,low,high,step in specs:
        row=tk.Frame(panel,bg=WHITE);row.pack(fill='x',padx=8,pady=3)
        self.label(row,title).pack(side='left')
        var=tk.StringVar(value=str(default));self.eis_vars[key]=var
        entry=ttk.Spinbox(row,from_=low,to=high,increment=step,textvariable=var,width=8,state='disabled')
        entry.pack(side='right');self.eis_entries.append(entry)
    row=tk.Frame(panel,bg=WHITE);row.pack(fill='x',padx=8,pady=7)
    self.eis_apply=ttk.Button(row,text='应用参数',command=self.apply_eis,state='disabled');self.eis_apply.pack(side='left')
    self.eis_restore=ttk.Button(row,text='恢复验证参数',command=self.restore_eis,state='disabled');self.eis_restore.pack(side='right')
    self.eis_status=tk.StringVar(value='连接 R22 后读取IMU和防抖状态')
    tk.Label(panel,textvariable=self.eis_status,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),wraplength=280,justify='left',anchor='w').pack(fill='x',padx=8,pady=(1,7))
    tk.Label(panel,text='平滑值越大，跟随转向越慢。裁切越小，可补偿的幅度越小。\n偏移先保持 0；卷帘修正可设 0 做对照。',bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),wraplength=280,justify='left').pack(fill='x',padx=8,pady=(0,8))
    self.rotation_vars={};self.rotation_entries=[]
    panel=tk.LabelFrame(tuning_card,text='旋转稳像参数',bg=WHITE,fg=INK,font=('Microsoft YaHei UI',10))
    panel.pack(fill='x',padx=18,pady=(14,0))
    for key,title,default,low,high,step in [('rot_zoom_milli','基准裁切倍率',1.16,1.05,2.5,.01),('rot_max_zoom_milli','最大裁切目标',2.4,1.05,3,.01),('rot_tau_ms','边界跟随 (ms)',750,100,3000,10),('rot_rs_milli','卷帘修正 (%)',0,0,100,5)]:
        row=tk.Frame(panel,bg=WHITE);row.pack(fill='x',padx=8,pady=3);self.label(row,title).pack(side='left')
        var=tk.StringVar(value=str(default));self.rotation_vars[key]=var
        entry=ttk.Spinbox(row,from_=low,to=high,increment=step,textvariable=var,width=8,state='disabled');entry.pack(side='right');self.rotation_entries.append(entry)
    self.rotation_vars['rot_horizon']=tk.IntVar(value=1)
    horizon=ttk.Checkbutton(panel,text='地平线校平',variable=self.rotation_vars['rot_horizon'],state='disabled');horizon.pack(anchor='w',padx=8,pady=4);self.rotation_entries.append(horizon)
    row=tk.Frame(panel,bg=WHITE);row.pack(fill='x',padx=8,pady=7)
    self.rotation_apply=ttk.Button(row,text='应用参数',command=self.apply_rotation,state='disabled');self.rotation_apply.pack(side='left')
    self.rotation_restore=ttk.Button(row,text='恢复默认参数',command=self.restore_rotation,state='disabled');self.rotation_restore.pack(side='right')
    self.rotation_status=tk.StringVar(value='连接支持旋转稳像的固件后可用')
    tk.Label(panel,textvariable=self.rotation_status,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),wraplength=280,justify='left',anchor='w').pack(fill='x',padx=8,pady=(1,7))
    tk.Label(panel,text='与小抖动防抖互斥；参数分别保存。\n保留视角，接近边界时跟随；校平可能增加裁切。\n时刻偏移和IMU延迟沿用上方的传感器校准值。',bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),wraplength=280,justify='left').pack(fill='x',padx=8,pady=(0,8))
    self.tuning_status=tk.StringVar(value='请先连接串口；防抖需 R22；原模式兼容 R21')
    tk.Label(tuning_card,textvariable=self.tuning_status,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),wraplength=280,justify='left',anchor='w').pack(fill='x',padx=18,pady=(16,5))
    self.snapshot_hint=tk.StringVar(value='滤波、夜景和均衡化开启后显示强度滑条。\n双视窗：左侧原始，右侧显示所选处理。')
    tk.Label(tuning_card,textvariable=self.snapshot_hint,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),justify='left',anchor='w').pack(fill='x',padx=18,pady=(5,15))
    def scroll_tuning(event):
        tuning_canvas.yview_scroll(-int(event.delta/120),'units')
        return 'break'
    stack=[tuning_canvas,tuning_card]
    while stack:
        widget=stack.pop();widget.bind('<MouseWheel>',scroll_tuning)
        stack.extend(widget.winfo_children())


def build_connections(self,parent):
    serial_tab=network_tab=parent
    serial_card=self.card(serial_tab,'串口信息','读取板卡启动信息、帧率与采集诊断')
    serial_card.pack(fill='x',pady=(0,12))
    row=tk.Frame(serial_card,bg=WHITE);row.pack(fill='x',padx=18,pady=4)
    self.port=tk.StringVar(value=self.settings['serial_port']);self.baud=tk.StringVar(value=self.settings['baud'])
    self.port_combo=ttk.Combobox(row,textvariable=self.port,state='readonly',width=13);self.port_combo.pack(side='left',fill='x',expand=True)
    ttk.Button(row,text='刷新',command=self.refresh_ports).pack(side='right',padx=(8,0))
    row=tk.Frame(serial_card,bg=WHITE);row.pack(fill='x',padx=18,pady=5)
    self.label(row,'波特率').pack(side='left')
    self.baud_combo=ttk.Combobox(row,textvariable=self.baud,values=['115200','230400','460800','921600'],state='readonly',width=10);self.baud_combo.pack(side='right')
    self.serial_button=ttk.Button(serial_card,text='连接串口',command=self.toggle_serial);self.serial_button.pack(fill='x',padx=18,pady=(8,6))
    self.serial_state=tk.StringVar(value='未连接'); self.serial_status_label=self.label(serial_card,'',anchor='w');self.serial_status_label.configure(textvariable=self.serial_state,fg=MUTED);self.serial_status_label.pack(fill='x',padx=18,pady=(0,5))
    self.device_label=tk.StringVar(value='选择板卡 USB 串口')
    tk.Label(serial_card,textvariable=self.device_label,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),anchor='w',wraplength=280,justify='left').pack(fill='x',padx=18,pady=(0,13))
    net_card=self.card(network_tab,'以太网信息','拍照前核验板卡的图像回传能力')
    net_card.pack(fill='both',expand=True)
    self.adapter_state=tk.StringVar(value='点击刷新查看有线网卡')
    tk.Label(net_card,textvariable=self.adapter_state,bg=WHITE,fg=GREEN,font=('Microsoft YaHei UI',9),anchor='w',wraplength=280,justify='left').pack(fill='x',padx=18,pady=(0,7))
    self.local_ip=tk.StringVar(value=self.settings['local_ip']);self.board_ip=tk.StringVar(value=self.settings['board_ip'])
    self.local_port=tk.StringVar(value=self.settings['local_port']);self.board_port=tk.StringVar(value=self.settings['board_port'])
    for title,variable in [('电脑 IP',self.local_ip),('板卡 IP',self.board_ip)]:
        row=tk.Frame(net_card,bg=WHITE);row.pack(fill='x',padx=18,pady=4)
        self.label(row,title,width=7,anchor='w').pack(side='left')
        ttk.Entry(row,textvariable=variable,width=20).pack(side='right',fill='x',expand=True)
    row=tk.Frame(net_card,bg=WHITE);row.pack(fill='x',padx=18,pady=5)
    self.label(row,'本机端口').pack(side='left');ttk.Entry(row,textvariable=self.local_port,width=6).pack(side='left',padx=(7,12))
    self.label(row,'板卡端口').pack(side='left');ttk.Entry(row,textvariable=self.board_port,width=6).pack(side='left',padx=(7,0))
    row=tk.Frame(net_card,bg=WHITE);row.pack(fill='x',padx=18,pady=(8,6))
    self.network_button=ttk.Button(row,text='连接以太网',command=self.toggle_network);self.network_button.pack(side='left',fill='x',expand=True)
    ttk.Button(row,text='网卡刷新',command=self.refresh_network).pack(side='right',padx=(8,0))
    self.network_state=tk.StringVar(value='板卡图像通道未连接')
    self.net_status_label=tk.Label(net_card,textvariable=self.network_state,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),anchor='w',wraplength=280,justify='left');self.net_status_label.pack(fill='x',padx=18,pady=(0,8))