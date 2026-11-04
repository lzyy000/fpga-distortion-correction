"""Workspace and quality actions; the R22 UART/UDP control paths stay in console."""
from pathlib import Path
import datetime, traceback
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from fusion_widgets import BLUE, WHITE, MUTED, BG, ImageView
from quality_analysis import load_asset


class WorkspaceActions:
    def callback_error(self,kind,error,tb):
        text=''.join(traceback.format_exception(kind,error,tb))
        report=self.project/'reports/camera_console_errors.log'
        try:
            report.parent.mkdir(parents=True,exist_ok=True)
            with report.open('a',encoding='utf-8') as stream:stream.write(datetime.datetime.now().isoformat()+'\n'+text+'\n')
        except OSError:pass
        self.bottom_state.set('界面操作失败：'+str(error))

    @property
    def current_photo_path(self):return self.last_photo_path

    def _workspace_layout(self):
        current=self.workspace.pages[self.workspace.current]
        quality=current==self.quality_tab
        compact_photo=current==self.photo_tab and self.root.winfo_height()<840
        if quality:
            self.sidebar_frame.grid_remove();self.workspace.grid_configure(column=0,columnspan=2)
        else:
            self.sidebar_frame.grid();self.workspace.grid_configure(column=1,columnspan=1)
        if quality or (compact_photo and self.side_tabs.current!=2):self.metrics_frame.grid_remove()
        else:self.metrics_frame.grid()
        if quality or (compact_photo and self._logs_visible is not True):self.logs_card.grid_remove()
        else:self.logs_card.grid()
        if quality or compact_photo:
            self.header_frame.pack_forget()
            if not self.compact_header.winfo_manager():self.compact_header.pack(before=self.body_frame,fill='x')
        else:
            self.compact_header.pack_forget()
            if not self.header_frame.winfo_manager():self.header_frame.pack(before=self.body_frame,fill='x')

    def _responsive(self,event=None):
        if event is not None and event.widget!=self.root:return
        if not hasattr(self,'logs_tabs'):return
        expanded=self.root.winfo_height()>=840 if self._logs_visible is None else self._logs_visible
        if expanded:
            if not self.logs_tabs.content.winfo_manager():self.logs_tabs.content.pack(fill='both',expand=True)
        else:self.logs_tabs.content.pack_forget()
        self.log_toggle.configure(text='收起日志' if expanded else '展开日志')
        self._workspace_layout()

    def toggle_logs(self):
        self._logs_visible=not bool(self.logs_tabs.content.winfo_manager());self._responsive()

    def show_photo_devices(self):
        self.workspace.select(self.photo_tab);self.side_tabs.select(0)

    def save_log(self):
        directory=self.project/'reports';directory.mkdir(parents=True,exist_ok=True)
        name=filedialog.asksaveasfilename(parent=self.root,title='保存上位机日志',initialdir=directory,
             initialfile='console_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S')+'.log',defaultextension='.log')
        if not name:return
        try:
            text='\n\n'.join('['+key+']\n'+widget.get('1.0','end-1c') for key,widget in self.logs.items())
            Path(name).write_text(text,encoding='utf-8');self.bottom_state.set('日志已保存：'+name)
        except OSError as exc:messagebox.showerror('保存日志',str(exc),parent=self.root)

    def _sync_buttons(self):
        if not hasattr(self,'quality_panel') or self.closing:return
        panel=self.quality_panel;locked=panel.busy or panel.capture_pending
        ready=self.net_ready and self.network_client is not None and not self.network_busy
        self.capture_button.configure(state='normal' if ready else 'disabled')
        self.cancel_capture_button.configure(state='normal' if self.network_busy and self.network_client else 'disabled')
        for button in panel.capture_buttons.values():button.configure(state='normal' if ready and not locked else 'disabled')
        panel.analyze_button.configure(state='disabled' if locked else 'normal')
        panel.cancel_button.configure(state='normal' if locked else 'disabled')
        panel.export_button.configure(state='normal' if any(panel.results) and not locked else 'disabled')

    def capture_quality(self,side):
        panel=self.quality_panel
        if side not in (0,1):raise ValueError('Invalid comparison side')
        if panel.busy or panel.capture_pending:return
        if not self.net_ready or self.network_client is None:
            panel.status.set('请先在设备连接中核验以太网，再拍摄至 A 或 B。');return
        if self.capture(quality_side=side):
            panel.capture_pending=True;panel.progress.start(12)
            panel.status.set(f'正在拍摄至 {"A" if side==0 else "B"}：使用板卡当前处理状态；不同次抓拍不是同帧。')
            self._sync_buttons()

    def _finish_quality_capture(self,path=None,error=None):
        target=self.quality_capture_side;self.quality_capture_side=None
        panel=self.quality_panel
        if target is None:return
        panel.capture_pending=False;panel.progress.stop()
        if path is not None:panel.load(target,path,auto_analyze=panel.auto_analyze.get())
        else:panel.status.set(error or '抓拍已取消，已有对比图与结果保留。')
        self._sync_buttons()

    def cancel_network(self):
        if self.network_busy and self.network_client is not None:
            self._finish_quality_capture(error='抓拍已取消，已有对比图保留；再次拍照前请重新连接以太网。')
            self.toggle_network();self._sync_buttons()

    def _photo_completed(self,path,metadata):
        self.current_photo_meta=metadata
        flags=metadata.get('geometry_flags',0)
        parts=[]
        if flags&8:parts.append('旋转稳像')
        elif flags&1:parts.append('IMU 小抖动防抖')
        if flags&4:parts.append('鱼眼畸变处理')
        elif flags&2:parts.append('Brown 畸变矫正')
        self.photo_badge.set(' / '.join(parts) if parts else '完整帧已校验','green')
        self._finish_quality_capture(path=path)

    def send_quality(self,side):
        self.workspace.select(self.quality_tab);self.quality_panel.current(side)

    def open_photo(self,path=None):
        if path is None:
            path=filedialog.askopenfilename(parent=self.root,title='打开照片',initialdir=self.output.get(),
                filetypes=[('图像','*.png *.jpg *.jpeg *.bmp *.tif *.tiff'),('全部文件','*.*')])
        if not path:return
        try:
            asset=load_asset(path);self.original_image=asset['image'];self.last_photo_path=Path(path)
            self.current_photo_meta=asset['metadata'];self.preview_resize()
            self.photo_info.set(f"{asset['size'][0]} × {asset['size'][1]} · {Path(path).name}")
            self.quality_info.set(asset['source']);self.photo_badge.set('本地照片','blue')
            self.bottom_state.set('已打开：'+str(path))
        except Exception as exc:messagebox.showerror('打开照片',str(exc),parent=self.root)

    def open_recent_menu(self):
        directory=Path(self.output.get());photos=sorted(directory.glob('*.png'),key=lambda p:p.stat().st_mtime,reverse=True)[:12] if directory.is_dir() else []
        menu=tk.Menu(self.root,tearoff=False)
        if not photos:menu.add_command(label='保存目录暂无照片',state='disabled')
        for path in photos:menu.add_command(label=path.name,command=lambda p=path:self.open_photo(p))
        try:menu.tk_popup(self.history_button.winfo_rootx(),self.history_button.winfo_rooty()+self.history_button.winfo_height())
        finally:menu.grab_release()

    def open_large_photo(self):
        if self.original_image is None:
            self.bottom_state.set('请先接收或打开一张完整照片。');return
        window=tk.Toplevel(self.root);window.title('完整帧照片 · 100% / 适应窗口');window.geometry('1200x780');window.configure(bg=BG)
        toolbar=tk.Frame(window,bg=WHITE);toolbar.pack(fill='x',padx=12,pady=10)
        view=ImageView(window,zoomable=True);view.pack(fill='both',expand=True,padx=12,pady=(0,12))
        ttk.Button(toolbar,text='适应窗口',command=view.fit).pack(side='left')
        ttk.Button(toolbar,text='100% / 适应',command=view.toggle_zoom).pack(side='left',padx=6)
        view.set_image(self.original_image)
