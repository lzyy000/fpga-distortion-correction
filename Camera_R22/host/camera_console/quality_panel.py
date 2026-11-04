"""Quality workbench: synchronized native-pixel comparison and offline jobs."""
from pathlib import Path
import json, math, os, queue, threading, tkinter as tk
from tkinter import ttk, filedialog, messagebox
from PIL import Image, ImageTk
from fusion_widgets import BG, WHITE, INK, MUTED, BLUE, BORDER, DARK, FONT, label
from quality_analysis import (load_asset, analyze, annotation_shapes, export_pair,
                              find_mtf, Cancelled, opencv_reference)
from quality_readout import (curvature_profile, available_lines, line_name,
                             metric_text, comparison_text, render_curvature, quality_narrative)
from quality_visuals import display_shapes, render_overlay


class CompareView(tk.Canvas):
    def __init__(self, parent, owner, side):
        super().__init__(parent, bg=DARK, highlightthickness=0, width=1, height=180)
        self.owner=owner; self.side=side; self.photo=None; self.transform=None; self.drag=None
        self.bind('<Configure>',lambda e:owner.schedule_redraw())
        self.bind('<MouseWheel>',self.wheel)
        self.bind('<Button-1>',self.press)
        self.bind('<B1-Motion>',self.move)
        self.bind('<Double-Button-1>',lambda e:owner.set_zoom('1:1' if owner.zoom.get()=='适应' else '适应'))
        self.bind('<Motion>',self.hover)

    def press(self,e):
        self.drag=(e.x,e.y,*self.owner.center)

    def move(self,e):
        asset=self.owner.assets[self.side]
        if self.drag and asset and self.transform:
            x,y,cx,cy=self.drag;scale=self.transform[2]
            self.owner.center=[max(0,min(1,cx-(e.x-x)/(scale*asset['image'].width))),
                               max(0,min(1,cy-(e.y-y)/(scale*asset['image'].height)))]
            self.owner.redraw()

    def wheel(self,e):
        self.owner.step_zoom(1 if e.delta>0 else -1)
        return 'break'

    def hover(self,e):
        if not self.transform:return
        ox,oy,scale=self.transform;x=(e.x-ox)/scale;y=(e.y-oy)/scale
        asset=self.owner.assets[self.side]
        if not asset or not 0<=x<asset['image'].width or not 0<=y<asset['image'].height:return
        text=f"{'左' if self.side==0 else '右'}图  x={x:.1f}, y={y:.1f} px"
        result=self.owner.results[self.side]
        if result:
            edges=result['mtf'].get('edges',[])
            nearby=sorted(edges,key=lambda p:(p['x']-x)**2+(p['y']-y)**2)
            if nearby and math.hypot(nearby[0]['x']-x,nearby[0]['y']-y)*scale<18:
                text+=f"  |  MTF50={nearby[0]['mtf50_cpp']:.4f} c/p"
        self.owner.coordinates.set(text)

    def draw(self):
        if not self.winfo_exists():return
        self.delete('all');w=max(1,self.winfo_width());h=max(1,self.winfo_height())
        asset=self.owner.assets[self.side]
        if asset is None:
            self.transform=None
            self.create_text(w/2,h/2-12,text='导入原图' if self.side==0 else '导入对比图',fill='#D2E1F2',font=(FONT,14,'bold'))
            self.create_text(w/2,h/2+23,text='可从本地文件或当前完整照片载入',fill='#83A2C5',font=(FONT,9),width=max(80,w-20))
            return
        image=asset['image'];mode=self.owner.zoom.get()
        siblings=[v for v in self.owner.views if v.winfo_exists() and v.master.master==self.master.master]
        fitw=min([w]+[max(1,v.winfo_width()) for v in siblings])
        fith=min([h]+[max(1,v.winfo_height()) for v in siblings])
        if mode=='棋盘特写' and self.owner.board_crop(self.side):
            cx,cy,spanx,spany=self.owner.board_crop(self.side)
            scale=max(.005,min((fitw-16)/spanx,(fith-16)/spany))
            cx+=(self.owner.center[0]-.5)*image.width;cy+=(self.owner.center[1]-.5)*image.height
        else:
            scale=max(.005,min((w-16)/image.width,(h-16)/image.height)) if mode in ('适应','棋盘特写') else {'1:1':1,'2×':2,'4×':4}[mode]
            cx,cy=self.owner.center;cx*=image.width;cy*=image.height
        ox=w/2-cx*scale;oy=h/2-cy*scale
        self.transform=(ox,oy,scale)
        # Only resample visible native pixels, even at 4x; keep drag memory bounded.
        x0=max(0,math.floor(-ox/scale));y0=max(0,math.floor(-oy/scale))
        x1=min(image.width,math.ceil((w-ox)/scale));y1=min(image.height,math.ceil((h-oy)/scale))
        if x1>x0 and y1>y0:
            crop=image.crop((x0,y0,x1,y1))
            crop=crop.resize((max(1,round((x1-x0)*scale)),max(1,round((y1-y0)*scale))),Image.Resampling.LANCZOS)
            self.photo=ImageTk.PhotoImage(crop,master=self)
            self.create_image(ox+x0*scale,oy+y0*scale,image=self.photo,anchor='nw')
        layers=self.owner.layer_values();selection=curvature_profile(self.owner.results,self.owner.selected_line)['selected']
        shapes=display_shapes(self.owner.results[self.side],selection,self.owner.display_mode.get(),
                              self.owner.gain_value(),self.side,layers)
        if shapes:
            self.overlay_photo=ImageTk.PhotoImage(render_overlay((w,h),shapes,(ox,oy,scale),show_text=self.owner.mtf_text.get()),master=self)
            self.create_image(0,0,image=self.overlay_photo,anchor='nw')
            if self.owner.display_mode.get()=='偏差放大':
                caption=f'白：直线参考  彩：二阶趋势 ×{self.owner.gain_value()}  点：实测（仅标记放大）'
                self.create_rectangle(7,7,min(w-7,460),31,fill=DARK,outline='')
                self.create_text(14,19,text=caption,fill='#E4EDF8',anchor='w',font=(FONT,9))


class QualityPanel(tk.Frame):
    def __init__(self,parent,app,root):
        super().__init__(parent,bg=BG)
        self.app=app;self.root=Path(root);self.assets=[None,None];self.results=[None,None]
        self.events=queue.Queue();self.cancel=threading.Event();self.busy=False;self.capture_pending=False;self._analyze_after_load=False;self.closed=False;self.generation=0
        self.center=[.5,.5];self.views=[];self.windows=[];self.curve_drawers=[];self.export_folder=None;self.profile_canvases=[]
        self.selected_line=None;self.line_options={}
        self._redraw_timer=None
        self.zoom=tk.StringVar(value='适应');self.coordinates=tk.StringVar(value='滚轮缩放 · 拖动双窗同步移动 · 双击原尺寸')
        self.status=tk.StringVar(value='导入左右图像后点击分析；测量使用原尺寸、未标注的像素。')
        self.target=tk.StringVar(value='棋盘格');self.cols=tk.StringVar(value='9');self.rows=tk.StringVar(value='6')
        self.do_mtf=tk.BooleanVar(value=True);self.linear=tk.BooleanVar(value=False)
        self.auto_analyze=tk.BooleanVar(value=True)
        self.display_mode=tk.StringVar(value='偏差放大');self.gain=tk.StringVar(value='50×')
        self.executable=tk.StringVar(value=find_mtf())
        self.preferences=self.root/'host/camera_console/quality_settings.json'
        try:
            saved=json.loads(self.preferences.read_text(encoding='utf-8-sig'))
            self.executable.set(find_mtf(saved.get('mtf_executable','')))
            self.linear.set(bool(saved.get('linear_input',False)))
        except (OSError,ValueError,AttributeError):pass
        self.layers={k:tk.BooleanVar(value=k in ('fitted','corners')) for k in ('fitted','corners','residuals','mtf')}
        self.full_grid=tk.BooleanVar(value=False);self.line_choice=tk.StringVar(value='自动：原图偏差最大线')
        self.interpretation=tk.StringVar(value=comparison_text(self.results))
        self.mtf_text=tk.BooleanVar(value=False)
        self._build();self._timer=self._root().after(80,self.poll)
        self.bind('<Destroy>',lambda e:self.close() if e.widget==self else None,add='+')

    def _build(self):
        head=tk.Frame(self,bg=BG);head.pack(fill='x',pady=(1,7))
        label(head,'图像质量',size=13,bold=True).pack(side='left')
        ttk.Button(head,text='连接设置',command=self.app.show_photo_devices,style='Quiet.TButton').pack(side='left',padx=9)
        ttk.Button(head,text='工具设置',command=self.settings).pack(side='right')
        ttk.Button(head,text='放大对比窗',command=self.large_window).pack(side='right',padx=5)
        options=tk.Frame(self,bg=WHITE,highlightbackground=BORDER,highlightthickness=1);options.pack(fill='x',pady=(0,7))
        row=tk.Frame(options,bg=WHITE);row.pack(fill='x',padx=9,pady=7)
        label(row,'图卡',size=9).pack(side='left')
        ttk.Combobox(row,textvariable=self.target,values=('棋盘格','斜边图'),state='readonly',width=7).pack(side='left',padx=(5,10))
        label(row,'内角点 列×行',size=9).pack(side='left')
        for i,var in enumerate((self.cols,self.rows)):
            if i:label(row,'×').pack(side='left')
            ttk.Spinbox(row,from_=3,to=30,textvariable=var,width=3).pack(side='left',padx=3)
        ttk.Checkbutton(row,text='MTF50 / SFR',variable=self.do_mtf).pack(side='left',padx=8)
        ttk.Checkbutton(row,text='拍完自动分析',variable=self.auto_analyze).pack(side='left',padx=8)
        row2=tk.Frame(options,bg=WHITE);row2.pack(fill='x',padx=9,pady=(0,7))
        self.capture_buttons={}
        for side in (0,1):
            button=ttk.Button(row2,text='拍摄到 '+('A' if side==0 else 'B'),command=lambda n=side:self.app.capture_quality(n),style='Primary.TButton')
            button.pack(side='left',padx=(0,5));self.capture_buttons[side]=button
        self.analyze_button=ttk.Button(row2,text='分析左右图',command=self.start_analysis);self.analyze_button.pack(side='left')
        self.cancel_button=ttk.Button(row2,text='取消',command=self.cancel_job,state='disabled');self.cancel_button.pack(side='left',padx=5)
        self.export_button=ttk.Button(row2,text='导出报告与对比图',command=self.export,state='disabled');self.export_button.pack(side='left')
        self.progress=ttk.Progressbar(row2,mode='indeterminate',length=50);self.progress.pack(side='right',fill='x',expand=True,padx=(8,0))
        nav=tk.Frame(self,bg=BG);nav.pack(fill='x',pady=(0,5))
        mode=ttk.Combobox(nav,textvariable=self.display_mode,values=('偏差放大','干净照片','检测标记'),state='readonly',width=8)
        mode.pack(side='left',padx=(0,5));mode.bind('<<ComboboxSelected>>',lambda e:self.redraw())
        gain=ttk.Combobox(nav,textvariable=self.gain,values=('10×','20×','50×','100×'),state='readonly',width=5)
        gain.pack(side='left',padx=(0,8));gain.bind('<<ComboboxSelected>>',lambda e:self.redraw())
        label(nav,'缩放',size=9,color=MUTED).pack(side='left')
        combo=ttk.Combobox(nav,textvariable=self.zoom,values=('适应','棋盘特写','1:1','2×','4×'),state='readonly',width=8)
        combo.pack(side='left',padx=5);combo.bind('<<ComboboxSelected>>',lambda e:self.set_zoom(self.zoom.get()))
        menu_button=ttk.Menubutton(nav,text='检测标记设置');menu_button.pack(side='left',padx=4)
        menu=tk.Menu(menu_button,tearoff=False);menu_button.configure(menu=menu)
        for key,title in (('fitted','直线参考'),('corners','角点'),('residuals','实际偏差'),('mtf','MTF点')):
            menu.add_checkbutton(label=title,variable=self.layers[key],command=self.redraw)
        menu.add_checkbutton(label='整张网格',variable=self.full_grid,command=self.redraw)
        ttk.Button(nav,text='SFR 曲线',command=self.curves_window,style='Quiet.TButton').pack(side='right')
        images=tk.Frame(self,bg=BG);images.pack(fill='both',expand=True)
        images.columnconfigure((0,1),weight=1,uniform='quality');images.rowconfigure(0,weight=1)
        self.file_titles=[];self.source_titles=[];self.metric_titles=[]
        for side in (0,1):
            frame=tk.Frame(images,bg=WHITE,highlightbackground=BORDER,highlightthickness=1)
            frame.grid(row=0,column=side,sticky='nsew',padx=(0,4) if side==0 else (4,0))
            frame.pack_propagate(False)
            tools=tk.Frame(frame,bg=WHITE);tools.pack(fill='x',padx=7,pady=(7,3))
            label(tools,'A · 参考图' if side==0 else 'B · 对比图',bold=True,size=10).pack(side='left')
            ttk.Button(tools,text='导入',command=lambda n=side:self.choose(n),style='Quiet.TButton').pack(side='right')
            ttk.Button(tools,text='当前照片',command=lambda n=side:self.current(n),style='Quiet.TButton').pack(side='right')
            filevar=tk.StringVar(value='尚未选择');self.file_titles.append(filevar)
            label(frame,variable=filevar,color=MUTED,size=8,anchor='w',wraplength=200).pack(fill='x',padx=9,pady=(0,3))
            source=tk.StringVar(value='来源 —');self.source_titles.append(source)
            label(frame,variable=source,color=BLUE,size=8,anchor='w',wraplength=200).pack(fill='x',padx=9,pady=(0,5))
            metrics=tk.StringVar(value=metric_text(None));self.metric_titles.append(metrics)
            label(frame,variable=metrics,size=9,anchor='w',justify='left',wraplength=200).pack(side='bottom',fill='x',padx=9,pady=7)
            view=CompareView(frame,self,side);view.pack(fill='both',expand=True);self.views.append(view)
        self.analysis_area=tk.Frame(self,bg=BG);self.analysis_area.pack(fill='x',pady=(5,0))
        self.analysis_area.columnconfigure(0,weight=3,uniform='analysis');self.analysis_area.columnconfigure(1,weight=2,uniform='analysis')
        self.profile_frame=tk.Frame(self.analysis_area,bg=WHITE,highlightbackground=BORDER,highlightthickness=1)
        self.profile_frame.grid(row=0,column=0,sticky='nsew',padx=(0,4))
        bar=tk.Frame(self.profile_frame,bg=WHITE);bar.pack(fill='x',padx=8,pady=(3,0))
        label(bar,'实际偏差',bold=True,size=9).pack(side='left')
        self.line_combo=ttk.Combobox(bar,textvariable=self.line_choice,values=('自动：原图偏差最大线',),state='readonly',width=20)
        self.line_combo.pack(side='left',padx=8);self.line_combo.bind('<<ComboboxSelected>>',self.select_line)
        canvas=tk.Canvas(self.profile_frame,bg=WHITE,height=95,highlightthickness=0)
        canvas.pack(fill='x');canvas.bind('<Configure>',lambda e:self.draw_profiles())
        self.profile_canvases.append(canvas)
        prose=tk.Frame(self.analysis_area,bg=WHITE,highlightbackground=BORDER,highlightthickness=1)
        prose.grid(row=0,column=1,sticky='nsew',padx=(4,0));prose.pack_propagate(False)
        label(prose,'分析结论',bold=True,size=9,anchor='w').pack(fill='x',padx=9,pady=(6,2))
        scroll=ttk.Scrollbar(prose);scroll.pack(side='right',fill='y')
        self.narrative=tk.Text(prose,height=5,wrap='word',relief='flat',bg=WHITE,fg=INK,font=(FONT,9),padx=9,pady=3,
                               yscrollcommand=scroll.set,state='disabled');self.narrative.pack(fill='both',expand=True)
        scroll.configure(command=self.narrative.yview)
        self.set_narrative(quality_narrative(self.assets,self.results))
        foot=tk.Frame(self,bg=BG);foot.pack(fill='x',pady=(3,0))
        label(foot,variable=self.status,size=9,color=INK,anchor='w',justify='left',wraplength=400).pack(fill='x',pady=(3,0))

    def gain_value(self):return int(self.gain.get().replace('×',''))
    def schedule_redraw(self):
        if self._redraw_timer:self._root().after_cancel(self._redraw_timer)
        self._redraw_timer=self._root().after(45,self.redraw)
    def set_narrative(self,text):
        self.narrative.configure(state='normal');self.narrative.delete('1.0','end');self.narrative.insert('end',text)
        self.narrative.configure(state='disabled');self.narrative.yview_moveto(0)
    def layer_values(self):
        values={k:v.get() for k,v in self.layers.items()}
        values['selected']=None if self.full_grid.get() else curvature_profile(self.results,self.selected_line)['selected']
        return values
    def board_crop(self,side):
        bounds=[]
        for result in self.results:
            corners=result['straightness'].get('corners',[]) if result else []
            if corners:
                xs,ys=zip(*corners);bounds.append(((min(xs)+max(xs))/2,(min(ys)+max(ys))/2,max(xs)-min(xs),max(ys)-min(ys)))
            else:bounds.append(None)
        if not bounds[side]:return None
        # Same crop span in native pixels for both views; retain a one-square margin.
        return (*bounds[side][:2],max(b[2] for b in bounds if b)*1.35,max(b[3] for b in bounds if b)*1.55)
    def select_line(self,event=None):
        self.selected_line=self.line_options.get(self.line_choice.get());self.redraw()
    def update_readouts(self):
        for side,result in enumerate(self.results):self.metric_titles[side].set(metric_text(result))
        self.interpretation.set(comparison_text(self.results))
        self.set_narrative(quality_narrative(self.assets,self.results))
        self.line_options={line_name(k):k for k in available_lines(self.results)}
        self.line_combo.configure(values=('自动：原图偏差最大线',*self.line_options))
        if self.selected_line not in self.line_options.values():
            self.selected_line=None;self.line_choice.set('自动：原图偏差最大线')
    def draw_profiles(self):
        model=curvature_profile(self.results,self.selected_line)
        for canvas in self.profile_canvases[:]:
            if not canvas.winfo_exists():self.profile_canvases.remove(canvas);continue
            canvas.delete('all')
            canvas.photo=ImageTk.PhotoImage(render_curvature(model,(max(350,canvas.winfo_width()),max(90,canvas.winfo_height()))))
            canvas.create_image(0,0,image=canvas.photo,anchor='nw')
    def redraw(self):
        self._redraw_timer=None
        for view in self.views:
            if view.winfo_exists():view.draw()
        self.views=[v for v in self.views if v.winfo_exists()]
        self.curve_drawers=[(c,fn)for c,fn in self.curve_drawers if c.winfo_exists()]
        for canvas,fn in self.curve_drawers:fn()
        self.draw_profiles()
    def set_zoom(self,value):
        self.zoom.set(value);self.center=[.5,.5];self.redraw()
    def step_zoom(self,direction):
        values=('适应','棋盘特写','1:1','2×','4×');self.zoom.set(values[max(0,min(4,values.index(self.zoom.get())+direction))]);self.redraw()

    def _job(self,kind,fn):
        if self.busy or self.capture_pending:return
        self.busy=True;self.generation+=1;generation=self.generation;self.cancel=threading.Event()
        self.analyze_button.configure(state='disabled');self.export_button.configure(state='disabled');self.cancel_button.configure(state='normal')
        self.progress.start(12)
        self.app._sync_buttons()
        def work():
            try:self.events.put((generation,kind,fn(self.cancel)))
            except Exception as exc:self.events.put((generation,'error',str(exc)))
        threading.Thread(target=work,daemon=True,name='quality_'+kind).start()

    def load(self,side,path,auto_analyze=False):
        if self.busy or self.capture_pending:self.status.set('请先取消或等待当前分析完成');return
        self._analyze_after_load=bool(auto_analyze)
        self.status.set('正在读取完整图像…')
        self._job('loaded',lambda cancel:(side,load_asset(path)))

    def choose(self,side):
        if self.busy or self.capture_pending:return
        path=filedialog.askopenfilename(parent=self,title='选择原图' if side==0 else '选择 FPGA 结果或其他对比图',
            initialdir=self.app.output.get(),filetypes=[('图像','*.png *.jpg *.jpeg *.bmp *.tif *.tiff'),('全部文件','*.*')])
        if path:self.load(side,path)

    def current(self,side):
        path=self.app.current_photo_path
        if path:self.load(side,path)
        else:self.status.set('请先在“以太网照片”接收或打开一张完整照片，再送入对应窗口。')

    def _set_asset(self,side,asset):
        self.assets[side]=asset;self.results[side]=None
        self.file_titles[side].set(Path(asset['path']).name+f"  ·  {asset['size'][0]}×{asset['size'][1]}")
        self.source_titles[side].set(asset['source']);self.update_readouts()
        self.center=[.5,.5];self.redraw()

    def start_analysis(self):
        if self.busy or self.capture_pending:return
        if not any(self.assets):self.status.set('请先导入至少一幅原尺寸图像');return
        try:
            pattern=(int(self.cols.get()),int(self.rows.get()))
            if not all(3<=v<=30 for v in pattern):raise ValueError()
        except ValueError:self.status.set('内角点行列数需为 3～30 的整数');return
        assets=list(self.assets);exe=self.executable.get();do_mtf=self.do_mtf.get();linear=self.linear.get();checker=self.target.get()=='棋盘格'
        self.status.set('正在检测原尺寸角点并运行 MTF Mapper… 可取消，设备采集与控制仍可使用。')
        def run(cancel):
            results=[]
            for side,asset in enumerate(assets):
                if cancel.is_set():raise Cancelled('分析已取消')
                if asset:
                    self.events.put((self.generation,'progress',f"正在分析{'左' if side==0 else '右'}图…"))
                    results.append(analyze(asset,pattern,exe,do_mtf,checker,linear,cancel))
                else:results.append(None)
            return results
        self._job('analyzed',run)

    def cancel_job(self):
        if self.capture_pending:
            self.app.cancel_network();return
        if self.busy or self.capture_pending:
            self.cancel.set();self.status.set('正在取消，原双窗和已经保存的完整照片保留。')


    def poll(self):
        if self.closed:return
        while True:
            try:generation,kind,value=self.events.get_nowait()
            except queue.Empty:break
            if generation!=self.generation:continue
            if kind=='progress':self.status.set(value);continue
            self.busy=False;self.progress.stop();self.analyze_button.configure(state='normal');self.cancel_button.configure(state='disabled')
            if self.cancel.is_set():self.status.set('分析已取消，已有结果保留')
            elif kind=='loaded':
                side,asset=value;self._set_asset(side,asset);self.status.set('图像已载入。A/B为独立照片；请保持同场景、倍率和光照。')
                if self._analyze_after_load:self._root().after(80,self.start_analysis)
                self._analyze_after_load=False
            elif kind=='paired':
                for side,asset in enumerate(value['assets']):self._set_asset(side,asset)
                self.status.set('对比照片已保存：左为无增强原图，右为FPGA处理图。连续两次抓拍，非同帧。')
                if self.auto_analyze.get():self._root().after(80,self.start_analysis)
            elif kind=='analyzed':
                self.results=value;self.update_readouts();messages=[]
                for side,result in enumerate(value):
                    if not result:continue
                    g,m=result['straightness'],result['mtf']
                    for part in (g,m):
                        if part.get('message'):messages.append(('左图：' if side==0 else '右图：')+part['message'])
                self.status.set('；'.join(messages) if messages else '分析完成。请保持同场景、倍率与处理设置；独立抓拍不是同帧对照。')
                if any(r and r['straightness'].get('corners') for r in value):self.set_zoom('棋盘特写')
                self.redraw()
            elif kind=='exported':
                self.export_folder=value;self.status.set('报告已导出：'+str(value))
                self.app.footer.set('图像质量报告：'+str(value))
            else:self.status.set(str(value))
            self.export_button.configure(state='normal' if any(self.results) else 'disabled')
            self.app._sync_buttons()
        self._timer=self._root().after(80,self.poll)

    def export(self):
        if self.busy or self.capture_pending or not any(self.results):return
        directory=filedialog.askdirectory(parent=self,title='选择分析报告保存目录',initialdir=self.app.output.get())
        if directory:
            assets=list(self.assets);results=list(self.results);layers=self.layer_values()
            self.status.set('正在导出原图、标注图、CSV 与 HTML 报告…')
            display={'mode':self.display_mode.get(),'gain':self.gain_value()}
            self._job('exported',lambda cancel:export_pair(assets,results,directory,layers,display))

    def large_window(self):
        window=tk.Toplevel(self);window.title('图像质量 · 双窗同步对比');window.configure(bg=BG)
        window.geometry(f'{min(1600,self.winfo_screenwidth()-65)}x{min(960,self.winfo_screenheight()-90)}')
        top=tk.Frame(window,bg=WHITE);top.pack(fill='x',padx=12,pady=10)
        label(top,'双窗同步对比',bold=True,size=13).pack(side='left')
        for text in ('适应','棋盘特写','1:1','2×','4×'):ttk.Button(top,text=text,command=lambda z=text:self.set_zoom(z)).pack(side='left',padx=4)
        ttk.Checkbutton(top,text='显示 MTF 数值',variable=self.mtf_text,command=self.redraw).pack(side='left',padx=10)
        ttk.Button(top,text='SFR 曲线',command=self.curves_window).pack(side='right')
        row=tk.Frame(window,bg=BG);row.pack(fill='both',expand=True,padx=12)
        row.columnconfigure((0,1),weight=1,uniform='large');row.rowconfigure(0,weight=1)
        for side in (0,1):
            frame=tk.Frame(row,bg=WHITE);frame.grid(row=0,column=side,sticky='nsew',padx=(0,5) if side==0 else (5,0))
            frame.pack_propagate(False)
            label(frame,variable=self.file_titles[side],bold=True,anchor='w',wraplength=400).pack(fill='x',padx=9,pady=7)
            label(frame,variable=self.source_titles[side],color=BLUE,size=9,anchor='w').pack(fill='x',padx=9,pady=(0,5))
            label(frame,variable=self.metric_titles[side],anchor='w',size=10).pack(side='bottom',fill='x',padx=9,pady=8)
            view=CompareView(frame,self,side);view.pack(fill='both',expand=True);self.views.append(view)
        label(window,variable=self.interpretation,size=9,anchor='w').pack(fill='x',padx=14,pady=4)
        canvas=tk.Canvas(window,bg=WHITE,height=155,highlightthickness=0);canvas.pack(fill='x',padx=12,pady=(0,8))
        canvas.bind('<Configure>',lambda e:self.draw_profiles());self.profile_canvases.append(canvas)
        self.windows.append(window);self.redraw()

    def help_window(self):
        window=tk.Toplevel(self);window.title('图像质量 · 怎么看');window.configure(bg=WHITE);window.geometry('680x430')
        label(window,'先看直不直，再看清不清晰',size=14,bold=True,anchor='w').pack(fill='x',padx=22,pady=(20,10))
        text=('① 弯曲偏差 RMS / 最远：角点离最佳直线有多远，单位是原图像素，越小越直。RMS反映总体偏差，“最远”是最大的采样距离。\n\n'
              '② 弯曲偏差放大图：蓝色是左图，橙色是右图；越贴近灰色0线越直。两图共用同一刻度，照片本身没有被拉弯或放大误差。默认找左图偏差最大的线，也可逐行、逐列查看。\n\n'
              '③ MTF50：反映边缘清晰度，同倍率、同区域、同处理设置下较高通常较清晰。“未测得”表示缺少可靠测量，不等于清晰度为0。棋盘矫正得很正时，反而可能没有适合MTF的斜边。\n\n'
              '注意：这里测的是棋盘角点的直线偏差，不是整幅镜头的畸变率，也不评价梯形是否变成矩形。图卡只占中央时，无法证明画面四角的矫正效果。独立抓拍需保持相机、图卡与光照不动。')
        label(window,text,size=10,justify='left',anchor='nw',wraplength=630).pack(fill='both',expand=True,padx=22)
        ttk.Button(window,text='明白了',command=window.destroy).pack(anchor='e',padx=22,pady=12)
        self.windows.append(window)

    def curves_window(self):
        window=tk.Toplevel(self);window.title('SFR 曲线 · 有效斜边独立统计');window.geometry('780x540');window.configure(bg=WHITE)
        label(window,'左右图有效斜边的中位 SFR 曲线',size=13,bold=True).pack(pady=(15,3))
        label(window,'两组边缘未自动一一对应；曲线反映各自采样结果。',size=9,color=MUTED).pack()
        canvas=tk.Canvas(window,bg=WHITE,highlightthickness=0);canvas.pack(fill='both',expand=True,padx=12,pady=12)
        def draw(event=None):
            import numpy as np
            canvas.delete('all');w=max(300,canvas.winfo_width());h=max(200,canvas.winfo_height());x0,y0,x1,y1=55,25,w-25,h-45
            canvas.create_line(x0,y0,x0,y1,x1,y1,fill=MUTED)
            for f in (0,.1,.2,.3,.4,.5):
                x=x0+(x1-x0)*f/.5;canvas.create_line(x,y0,x,y1,fill='#EBF0F8');canvas.create_text(x,y1+16,text=f'{f:.1f}',fill=MUTED)
            for a in (0,.5,1,1.5):
                y=y1-(y1-y0)*a/1.5;canvas.create_line(x0,y,x1,y,fill='#EBF0F8');canvas.create_text(x0-20,y,text=str(a),fill=MUTED)
            for side,color in ((0,'#2563EB'),(1,'#DE568F')):
                result=self.results[side];edges=result['mtf'].get('edges',[]) if result else []
                if not edges:continue
                curve=np.median([e['sfr'] for e in edges],axis=0);points=[]
                for i,value in enumerate(curve[:33]):points.extend((x0+(x1-x0)*(i/64)/.5,y1-(y1-y0)*min(1.5,max(0,value))/1.5))
                canvas.create_line(*points,fill=color,width=2)
                canvas.create_text(x1-90,y0+14+side*22,text=('A 左图' if side==0 else 'B 右图')+f' · {len(edges)} 边',fill=color)
            canvas.create_text((x0+x1)/2,h-9,text='空间频率 / cycles per pixel',fill=INK)
        canvas.bind('<Configure>',draw);self.curve_drawers.append((canvas,draw));self.windows.append(window);window.after(80,draw)

    def settings(self):
        window=tk.Toplevel(self);window.title('图像质量 · 工具设置');window.configure(bg=WHITE);window.geometry('670x350')
        label(window,'MTF Mapper 命令行程序',bold=True,anchor='w').pack(fill='x',padx=18,pady=(18,6))
        row=tk.Frame(window,bg=WHITE);row.pack(fill='x',padx=18)
        ttk.Entry(row,textvariable=self.executable).pack(side='left',fill='x',expand=True)
        def browse():
            path=filedialog.askopenfilename(parent=window,title='选择 bin 下的 mtf_mapper.exe',filetypes=[('MTF Mapper','mtf_mapper.exe')])
            if path:self.executable.set(path)
        ttk.Button(row,text='选择…',command=browse).pack(side='right',padx=(7,0))
        ttk.Checkbutton(window,text='输入像素为线性亮度（默认按 sRGB 假设）',variable=self.linear).pack(anchor='w',padx=18,pady=13)
        label(window,'测量前后图应使用相同的亮度解释。若相机 Gamma / ISP 曲线未知，MTF 结果应标注其假设。\n本工具不自动锐化、缩放、去畸变或修改源照片。',size=9,color=MUTED,justify='left',wraplength=620,anchor='w').pack(fill='x',padx=18)
        ttk.Button(window,text='查看 SFR 对比曲线',command=self.curves_window).pack(anchor='w',padx=18,pady=14)
        ttk.Button(window,text='由左图 + 标定生成 OpenCV 软件参考 → 右图',command=self.make_reference).pack(anchor='w',padx=18)
        def save():
            self.preferences.write_text(json.dumps({'mtf_executable':self.executable.get(),'linear_input':self.linear.get()},ensure_ascii=False,indent=2),encoding='utf-8')
            window.destroy()
        ttk.Button(window,text='保存设置',command=save).pack(side='right',padx=18,pady=12)
        self.windows.append(window)

    def make_reference(self):
        if self.busy or self.capture_pending:return
        if not self.assets[0]:self.status.set('请先载入左图，再生成软件参考');return
        path=filedialog.askopenfilename(parent=self,title='选择真实相机标定 JSON（K/D 或 intr，须含标定尺寸）',filetypes=[('JSON','*.json')])
        if path:
            asset=self.assets[0]
            self.status.set('正在由左图生成 OpenCV 镜头校正参考；结果将明确标为软件参考。')
            self._job('loaded',lambda cancel:(1,opencv_reference(asset,path,self.root/'captures/quality_references')))

    def close(self):
        self.capture_pending=False
        self.closed=True;self.cancel.set();self.generation+=1
        if self._redraw_timer:
            try:self._root().after_cancel(self._redraw_timer)
            except tk.TclError:pass
        if self._timer:
            try:self._root().after_cancel(self._timer)
            except tk.TclError:pass
