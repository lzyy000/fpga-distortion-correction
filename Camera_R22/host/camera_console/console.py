"""Desktop console: UART diagnostics and verified Ethernet snapshot reception."""
from pathlib import Path
import argparse
import datetime
import ipaddress
import json
import os
import queue
import re
import socket
import subprocess
import sys
import threading
import time
import traceback
import tkinter as tk
from tkinter import ttk, filedialog, messagebox

DEFAULT_PROJECT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--project',type=Path,default=Path(os.environ.get('FPGA_PROJECT_ROOT',DEFAULT_PROJECT)))
parser.add_argument('--ui-preview',action='store_true',help='Offline UI preview without device discovery')
parser.add_argument('--geometry')
parser.add_argument('--smoke-test',action='store_true',help='Create the UI and exit without opening devices')
options = parser.parse_args()
PROJECT = options.project.resolve()
settings_file = PROJECT/'scripts/local_tools.json'
if settings_file.is_file():
    tool_settings = json.loads(settings_file.read_text(encoding='utf-8-sig'))
    shared = os.environ.get('FPGA_SHARED_TOOLS') or tool_settings.get('shared_tools')
    if shared:
        sys.path.insert(0,str(Path(shared)/'python_packages'))
sys.path.insert(0,str(PROJECT/'tools/python_packages'))
import serial
from serial.tools import list_ports
from PIL import Image, ImageTk
from transport import SnapshotClient, SnapshotError
from storage import save_snapshot
from checkerboard import assess_file, calibrate_directory
from tuning import StrengthControl,MODE_DEFS,MODE_BITS,EIS_DEFAULTS,ROTATION_DEFAULTS

from fusion_widgets import BG, INK, MUTED, BLUE, WHITE, GREEN, RED, styles
from console_view import build_console
from console_actions import WorkspaceActions
CAM_PATTERN=re.compile(r'CAM dt_ms=(\d+) sensor=(\d+) cap=(\d+) display_new=(\d+) skipped=(\d+) flags=([0-9A-Fa-f]+) fifo_peak=(\d+)')

def network_info():
    command = "$ErrorActionPreference='Stop'; $a=@(Get-NetAdapter -Physical | Select-Object Name,InterfaceDescription,Status,LinkSpeed,ifIndex); $i=@(Get-NetIPAddress -AddressFamily IPv4 | Select-Object InterfaceAlias,IPAddress,PrefixLength,InterfaceIndex); [pscustomobject]@{adapters=$a;addresses=$i} | ConvertTo-Json -Depth 4 -Compress"
    result = subprocess.run(['powershell.exe','-NoProfile','-Command',command],capture_output=True,
                            timeout=15,creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
    if result.returncode:
        raise RuntimeError('无法读取网卡信息；请确认有线网卡已启用')
    # Windows PowerShell redirects using the Windows ANSI encoding unless explicitly set.
    text = result.stdout.decode('utf-8','replace')
    if '\ufffd' in text:
        text = result.stdout.decode('gb18030','replace')
    return json.loads(text)

class CameraConsole(WorkspaceActions):
    def __init__(self,root,discover=True):
        self.root=root;self.project=PROJECT;self.quality_capture_side=None;self.current_photo_meta={};self.last_tune={}
        self.root.title('FPGA 视觉控制台 · 独立算法 / 图像质量'+(' · 界面检查' if options.ui_preview else ''))
        window_width=min(1500,self.root.winfo_screenwidth()-90)
        window_height=min(940,self.root.winfo_screenheight()-100)
        self.root.geometry(options.geometry or f'{window_width}x{window_height}'); self.root.minsize(1060,720); self.root.configure(bg=BG)
        self.tuning_requests=queue.Queue();self.tuning_ready=False;self.setting_tuning=False
        self.firmware_version=None;self.mode_desired=0;self.mode_pending=False;self.ghe_supported=False;self.eis_supported=False;self.fisheye_supported=False;self.rotation_supported=False
        self.events=queue.Queue(); self.serial_stop=threading.Event(); self.serial_device=None
        self.network_client=None; self.network_generation=0; self.network_busy=False
        self.net_ready=False; self.serial_connected=False; self.closing=False
        self.interface_by_ip={}
        self.ports_refresh_pending=False;self.network_refresh_pending=False
        self.next_network_refresh=time.monotonic()+10;self.last_port_snapshot=None
        self.original_image=None; self.preview_photo=None; self.last_photo_path=None; self.photo_count=0
        self.settings_path=PROJECT/'host/camera_console/settings.json'
        self.settings={'local_ip':'192.168.1.105','board_ip':'192.168.1.11','local_port':'8080','board_port':'8080',
                       'baud':'115200','output':str(PROJECT/'captures'),'serial_port':''}
        if self.settings_path.is_file():
            try:
                saved=json.loads(self.settings_path.read_text(encoding='utf-8-sig'))
                for key in self.settings:
                    if isinstance(saved.get(key),str):self.settings[key]=saved[key]
            except (OSError,ValueError):pass
        self.session_stamp=datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        self._styles(); self._build()
        self.root.report_callback_exception=self.callback_error
        self.root.protocol('WM_DELETE_WINDOW',self.close)
        self.root.after(80,self.poll_events)
        if discover:
            self.refresh_ports(); self.refresh_network()
            self.root.after(2000,self.poll_devices)
        self.log('network','工程目录：'+str(PROJECT))
        self.log('network','上位机已就绪。支持 CNP1 协议的位流可抓拍完整帧；保存后自动检查 9×6 内角点棋盘格。')

    def _styles(self):
        styles(self.root)

    def label(self,parent,text,**kw):
        return tk.Label(parent,text=text,bg=WHITE,fg=INK,font=('Microsoft YaHei UI',10),**kw)

    def card(self,parent,title,subtitle=None):
        card=tk.Frame(parent,bg=WHITE,highlightbackground='#dde5ee',highlightthickness=1)
        tk.Label(card,text=title,bg=WHITE,fg=INK,font=('Microsoft YaHei UI',12,'bold'),anchor='w').pack(fill='x',padx=18,pady=(15,5))
        if subtitle:tk.Label(card,text=subtitle,bg=WHITE,fg=MUTED,font=('Microsoft YaHei UI',9),anchor='w',justify='left').pack(fill='x',padx=18,pady=(0,10))
        return card

    def _build(self):
        build_console(self,PROJECT)

    def log(self,channel,text):
        widget=self.logs[channel];widget.configure(state='normal')
        widget.insert('end',datetime.datetime.now().strftime('%H:%M:%S')+'  '+text+'\n')
        if int(widget.index('end-1c').split('.')[0])>1400:widget.delete('1.0','200.0')
        widget.see('end');widget.configure(state='disabled')

    def emit(self,kind,value):self.events.put((kind,value))

    def refresh_ports(self):
        if self.ports_refresh_pending:return
        self.ports_refresh_pending=True
        def worker():
            try:self.emit('ports',list(list_ports.comports()))
            except Exception as exc:self.emit('ports_error',str(exc))
        threading.Thread(target=worker,daemon=True).start()

    def apply_ports(self,ports):
        self.port_combo.configure(values=[port.device for port in ports])
        self.port_descriptions={port.device:port.description for port in ports}
        snapshot=tuple(sorted(self.port_descriptions.items()))
        if snapshot!=self.last_port_snapshot:
            self.log('serial','串口设备：'+('、'.join(self.port_descriptions) or '暂未检测到；每 2 秒自动刷新'))
            self.last_port_snapshot=snapshot
        if not self.serial_connected:
            preferred=[port.device for port in ports if 'CP210' in port.description.upper()]
            if self.port.get() not in self.port_descriptions:self.port.set(preferred[0] if preferred else ports[0].device if ports else '')
            self.device_label.set(self.port_descriptions.get(self.port.get(),'没有检测到串口'))

    def refresh_network(self):
        if self.network_refresh_pending:return
        self.network_refresh_pending=True
        def worker():
            try:self.emit('adapters',network_info())
            except Exception as exc:self.emit('adapter_error',str(exc))
        threading.Thread(target=worker,daemon=True).start()

    def poll_devices(self):
        if self.closing:return
        self.refresh_ports()
        if time.monotonic()>=self.next_network_refresh:
            self.next_network_refresh=time.monotonic()+10
            self.refresh_network()
        self.root.after(2000,self.poll_devices)

    def strength_changed(self,key,value):
        percent=max(0,min(100,int(float(value)+.5)))
        self.strength_labels[key].set(f'{percent}%')
        if self.tuning_ready and not self.setting_tuning:
            self.strength_acks[key].set('等待板卡确认…')
            self.tuning_requests.put((key,percent))

    def show_strength(self,key,visible):
        if key not in self.strength_widgets:return
        scale,ack=self.strength_widgets[key]
        scale.pack_forget();ack.pack_forget()
        if visible:
            scale.pack(fill='x',padx=18,pady=(4,0),after=self.mode_rows[key])
            ack.pack(fill='x',padx=18,pady=(1,0),after=scale)

    def mode_clicked(self,key):
        if not self.tuning_ready or self.firmware_version not in (21,22) or self.mode_pending:return
        if key=='ghe' and not self.ghe_supported or key=='eis' and not self.eis_supported or key=='fisheye' and not self.fisheye_supported or key=='rotation' and not self.rotation_supported:return
        bit=MODE_BITS[key];enabled=not bool(self.mode_desired&bit)
        self.mode_desired=(self.mode_desired|bit) if enabled else (self.mode_desired&~bit)
        if enabled and key=='fisheye':self.mode_desired&=~MODE_BITS['correct']
        if enabled and key=='correct':self.mode_desired&=~MODE_BITS['fisheye']
        if enabled and key=='rotation':self.mode_desired&=~MODE_BITS['eis']
        if enabled and key=='eis':self.mode_desired&=~MODE_BITS['rotation']
        self.mode_pending=True
        for button in self.mode_buttons.values():button.configure(state='disabled')
        self.mode_buttons[key].configure(text='确认中…')
        self.show_strength(key,enabled)
        self.tuning_requests.put(('mode',key,enabled))

    def apply_eis(self):
        if not self.tuning_ready or not self.eis_supported:return
        try:
            values={key:int(round(float(var.get())*(1000 if key in ('zoom_milli','imu_delay_us','frame_offset_us') else 10 if key=='rs_milli' else 1))) for key,var in self.eis_vars.items()}
            for key,lo,hi in [('zoom_milli',1050,1600),('tau_ms',100,1500),('yaw_tau_ms',100,1500),('rs_milli',0,1000),('frame_offset_us',-50000,50000),('imu_delay_us',-50000,50000)]:
                if not lo<=values[key]<=hi:raise ValueError('参数超出输入范围')
        except (ValueError,OverflowError):
            messagebox.showerror('防抖参数','请输入范围内的数字；裁切1.05～1.60，平滑100～1500ms，卷帘0～100%，时刻偏移±50ms。');return
        self.eis_status.set('等待板卡逐项确认参数…')
        self.tuning_requests.put(('eis_params',values))

    def restore_eis(self):
        for key,value in EIS_DEFAULTS.items():
            divisor=1000 if key in ('zoom_milli','imu_delay_us','frame_offset_us') else 10 if key=='rs_milli' else 1
            self.eis_vars[key].set(f'{value/divisor:g}')
        self.apply_eis()

    def apply_rotation(self):
        if not self.tuning_ready or not self.rotation_supported:return
        try:
            values={key:int(round(float(var.get())*(1000 if key in ('rot_zoom_milli','rot_max_zoom_milli') else 10 if key=='rot_rs_milli' else 1))) for key,var in self.rotation_vars.items()}
            for key,lo,hi in [('rot_zoom_milli',1050,2500),('rot_max_zoom_milli',1050,3000),('rot_tau_ms',100,3000),('rot_horizon',0,1),('rot_rs_milli',0,1000)]:
                if not lo<=values[key]<=hi:raise ValueError('参数超出范围')
            if values['rot_max_zoom_milli']<values['rot_zoom_milli']:raise ValueError('最大裁切不能小于基准裁切')
        except (ValueError,OverflowError):
            messagebox.showerror('旋转稳像参数','请输入范围内的数字，且最大裁切不得小于基准裁切。');return
        self.rotation_status.set('等待板卡确认旋转稳像参数…');self.tuning_requests.put(('rotation_params',values))

    def restore_rotation(self):
        for key,value in ROTATION_DEFAULTS.items():
            divisor=1000 if key in ('rot_zoom_milli','rot_max_zoom_milli') else 10 if key=='rot_rs_milli' else 1
            self.rotation_vars[key].set(value/divisor if divisor!=1 else value)
        self.apply_rotation()

    def disable_tuning(self,message):
        self.tuning_ready=False
        for widget in self.eis_entries+[self.eis_apply,self.eis_restore]:widget.configure(state='disabled')
        self.eis_status.set('串口未确认；防抖参数不可写入')
        for widget in self.rotation_entries+[self.rotation_apply,self.rotation_restore]:widget.configure(state='disabled')
        self.rotation_status.set('串口未确认；旋转稳像参数不可写入')
        for scale in self.strength_scales.values():scale.configure(state='disabled')
        for button in self.mode_buttons.values():button.configure(state='disabled')
        self.mode_pending=False;self.firmware_version=None
        self.tuning_status.set(message)
        for variable in self.strength_acks.values():variable.set('未确认')

    def toggle_serial(self):
        if self.serial_connected:
            self.serial_stop.set();self.disable_tuning('串口正在断开');self.serial_button.configure(state='disabled');self.serial_state.set('正在断开…');return
        port=self.port.get()
        if not port:messagebox.showinfo('串口','没有可用的板卡串口');return
        try:baud=int(self.baud.get())
        except ValueError:messagebox.showerror('串口','波特率无效');return
        self.disable_tuning('正在确认板卡强度控制能力…')
        self.tuning_requests=queue.Queue();requests=self.tuning_requests
        self.serial_stop=threading.Event();stop=self.serial_stop
        self.serial_button.configure(state='disabled');self.serial_state.set('正在连接…')
        def worker():
            uart=None
            try:
                uart=serial.Serial(port=None,baudrate=baud,timeout=.05,write_timeout=.5)
                tuning=StrengthControl(self.emit)
                uart.dtr=False;uart.rts=False;uart.port=port;uart.open()
                self.serial_device=uart;self.emit('serial_open',port)
                directory=PROJECT/'reports';directory.mkdir(parents=True,exist_ok=True)
                filename=directory/('console_uart_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.log')
                self.emit('serial_line','日志保存：'+str(filename))
                pending=b''
                with filename.open('w',encoding='utf-8') as output:
                    while not stop.is_set():
                        while True:
                            try:item=requests.get_nowait()
                            except queue.Empty:break
                            if len(item)==3 and item[0]=='mode':
                                tuning.request_mode(item[1],item[2],time.monotonic())
                            elif len(item)==2 and item[0]=='rotation_params':
                                tuning.request_rotation(item[1],time.monotonic())
                            elif len(item)==2 and item[0]=='eis_params':
                                tuning.request_eis(item[1],time.monotonic())
                            else:
                                key,percent=item;tuning.request(key,percent,time.monotonic())
                        outgoing=tuning.tick(time.monotonic())
                        if outgoing is not None:uart.write(outgoing)
                        pending+=uart.read(max(1,min(uart.in_waiting,4096)))
                        if len(pending)>65536:
                            pending=b'';self.emit('serial_line','丢弃超长串口行；请核对波特率');continue
                        while b'\n' in pending:
                            line,pending=pending.split(b'\n',1);line=line.decode('utf-8','replace').strip()
                            if line:
                                output.write(line+'\n');output.flush()
                                if re.search(r'DVP R(?:19|20|21|22) ',line):
                                    tuning=StrengthControl(self.emit);self.emit('tune_reset',None)
                                    while not requests.empty():
                                        try:requests.get_nowait()
                                        except queue.Empty:break
                                tuning.receive(line);self.emit('serial_line',line)
            except Exception as exc:self.emit('serial_error',str(exc))
            finally:
                if uart:uart.close()
                self.serial_device=None;self.emit('serial_closed',None)
        threading.Thread(target=worker,daemon=True).start()

    def _network_values(self):
        local=str(ipaddress.IPv4Address(self.local_ip.get().strip()));board=str(ipaddress.IPv4Address(self.board_ip.get().strip()))
        local_port=int(self.local_port.get());board_port=int(self.board_port.get())
        if not 1<=local_port<=65535 or not 1<=board_port<=65535:raise ValueError('UDP 端口应为 1～65535')
        if not ipaddress.IPv4Address(local).is_global and local=='0.0.0.0':raise ValueError('请选择本机有线网卡 IP')
        interface_index=self.interface_by_ip.get(local)
        if interface_index is None:raise ValueError('尚未确认电脑 IP 所属的有线网卡；请点击“网卡刷新”后重试')
        return {'local_ip':local,'board_ip':board,'local_port':local_port,'board_port':board_port,'interface_index':interface_index}

    def toggle_network(self):
        if self.network_client is not None or self.network_busy:
            self._finish_quality_capture(error='以太网已断开；已有对比图保留。')
            self.network_generation+=1
            if self.network_client:self.network_client.close()
            self.network_client=None;self.network_busy=False;self.net_ready=False
            self.network_button.configure(text='连接以太网',state='normal');self.capture_button.configure(state='disabled')
            self.network_state.set('板卡图像通道未连接');self.net_status_label.configure(fg=MUTED);self.progress['value']=0
            self.log('network','以太网接收已停止');self.update_header();return
        try:values=self._network_values()
        except ValueError as exc:messagebox.showerror('网络配置',str(exc));return
        self.network_generation+=1;generation=self.network_generation;self.network_busy=True
        self.network_button.configure(text='正在检查…',state='disabled');self.network_state.set('正在核验板卡抓拍能力…')
        self.log('network',f"本机 {values['local_ip']}:{values['local_port']} → 板卡 {values['board_ip']}:{values['board_port']}")
        def worker():
            client=None
            try:
                client=SnapshotClient(**values);info=client.hello()
                self.emit('network_ready',(generation,client,info,values))
            except Exception as exc:
                if client:client.close()
                self.emit('network_error',(generation,str(exc)))
        threading.Thread(target=worker,daemon=True).start()

    def capture(self,quality_side=None):
        if not self.net_ready or self.network_busy or self.network_client is None:return
        directory=self.output.get().strip()
        if not directory:messagebox.showerror('保存位置','请选择照片保存目录');return
        generation=self.network_generation;client=self.network_client;connection=dict(self.connection)
        self.quality_capture_side=quality_side
        self.network_busy=True;self.capture_button.configure(state='disabled');self.progress['value']=0
        self.network_state.set('正在请求完整帧…');self.bottom_state.set('拍照中：接收、补包、整帧校验后保存 PNG')
        self.log('network','已请求拍摄一张 1920 × 1080 完整帧照片')
        def worker():
            try:
                result=client.capture(progress=lambda done,total:self.emit('progress',(generation,done,total)))
                if generation!=self.network_generation or self.closing:return
                image,path,metadata=save_snapshot(result,directory,connection)
                self.emit('photo',(generation,image,path,metadata))
                try:
                    quality,overlay=assess_file(path)
                    self.emit('quality',(generation,quality))
                except Exception as exc:self.emit('quality_error',(generation,str(exc)))
            except Exception as exc:self.emit('network_error',(generation,str(exc)))
        threading.Thread(target=worker,daemon=True).start()
        self._sync_buttons()
        return True

    def calibrate(self):
        directory=self.output.get().strip()
        self.quality_info.set('正在检测保存目录中的照片并计算标定参数…')
        self.log('network','标定开始：检测已有照片，筛选清晰完整棋盘格和不同姿势。')
        def worker():
            try:self.emit('calibration',calibrate_directory(directory))
            except Exception as exc:self.emit('calibration_error',str(exc))
        threading.Thread(target=worker,daemon=True).start()

    def choose_output(self):
        directory=filedialog.askdirectory(title='照片保存目录',initialdir=self.output.get() if Path(self.output.get()).is_dir() else str(PROJECT))
        if directory:self.output.set(directory)

    def open_output(self):
        directory=Path(self.output.get())
        try:
            directory.mkdir(parents=True,exist_ok=True);os.startfile(str(directory))
        except OSError as exc:messagebox.showerror('保存目录',str(exc))

    def preview_resize(self,event=None):
        self.preview.set_image(self.original_image)

    def update_header(self):
        self.serial_badge.set('串口 · 已连接' if self.serial_connected else '串口 · 未连接','green' if self.serial_connected else 'neutral')
        self.net_badge.set('以太网 · 就绪' if self.net_ready else '以太网 · 未连接','green' if self.net_ready else 'neutral')
        self._sync_buttons()
        self.header_state.set(('串口已连接' if self.serial_connected else '串口未连接')+'  /  '+('抓拍已就绪' if self.net_ready else '图像通道未就绪'))

    def poll_events(self):
        if self.closing:return
        for _ in range(300):
            try:kind,value=self.events.get_nowait()
            except queue.Empty:break
            if kind=='serial_open':
                self.serial_connected=True;self.serial_state.set('已连接 · '+value);self.serial_status_label.configure(fg=GREEN)
                self.serial_button.configure(text='断开串口',state='normal');self.port_combo.configure(state='disabled');self.baud_combo.configure(state='disabled');self.update_header()
            elif kind=='tune_ack':
                self.last_tune=dict(value)
                self.tuning_ready=True;self.setting_tuning=True
                self.firmware_version=value['firmware_version']
                self.ghe_supported=value.get('ghe_supported',False)
                self.eis_supported=value.get('eis_supported',False)
                self.fisheye_supported=value.get('fisheye_supported',False)
                self.rotation_supported=value.get('rotation_supported',False)
                for widget in self.rotation_entries+[self.rotation_apply,self.rotation_restore]:widget.configure(state='normal' if self.rotation_supported else 'disabled')
                if self.rotation_supported:
                    rs=value['rotation']
                    if value['first']:
                        for key in ROTATION_DEFAULTS:
                            divisor=1000 if key in ('rot_zoom_milli','rot_max_zoom_milli') else 10 if key=='rot_rs_milli' else 1
                            self.rotation_vars[key].set(rs[key]/divisor if divisor!=1 else rs[key])
                    state='运行' if rs['rotation_on'] and rs['rot_ready'] and rs['imu_age_ms']<=100 else '等待有效IMU' if rs['rotation_on'] else '关闭'
                    self.rotation_status.set(f"旋转稳像：{state} · 边界标志{rs['rot_limit']}\n已回读基准{rs['rot_zoom_milli']/1000:.2f}倍 / 最大目标{rs['rot_max_zoom_milli']/1000:.2f}倍\n实际裁切{rs['rot_actual_zoom_milli']/1000:.2f}倍 / 跟随{rs['rot_tau_ms']}ms")
                else:self.rotation_status.set('当前固件不支持旋转稳像；旧模式仍可使用')
                for widget in self.eis_entries+[self.eis_apply,self.eis_restore]:widget.configure(state='normal' if self.eis_supported else 'disabled')
                if self.eis_supported:
                    es=value['eis']
                    if value['first']:
                        for key in EIS_DEFAULTS:
                            divisor=1000 if key in ('zoom_milli','imu_delay_us','frame_offset_us') else 10 if key=='rs_milli' else 1
                            self.eis_vars[key].set(f'{es[key]/divisor:g}')
                    state='运行' if es['eis_on'] and es['eis_ready'] and es['imu_age_ms']<=100 else '等待有效IMU' if es['eis_on'] else '关闭'
                    self.eis_status.set(f"防抖：{state} · IMU {es['imu_age_ms']}ms\n已回读 {es['zoom_milli']/1000:.2f}倍 / 上下{es['tau_ms']}ms / 左右{es['yaw_tau_ms']}ms\n卷帘 {es['rs_milli']/10:g}% · 读出{es['readout_us']/1000:.2f}ms · 边界标志{es['limit']}")
                else:self.eis_status.set('当前固件无防抖功能；请编译并下载 R22 工程')
                for key in ('night','denoise','ghe'):
                    if key=='ghe' and not self.ghe_supported:
                        self.strength_scales[key].configure(state='disabled');self.show_strength(key,False);continue
                    if value['first']:
                        self.strength_vars[key].set(value[key]);self.strength_labels[key].set(f"{value[key]}%")
                    self.strength_scales[key].configure(state='normal')
                    target=int(float(self.strength_vars[key].get())+.5)
                    self.strength_acks[key].set(f"板卡已确认 {value[key]}%"+(' · 等待新值确认' if target!=value[key] else ''))
                    self.algorithm_states[key]=value[key+'_on']
                if self.firmware_version in (21,22):
                    confirmed=value['modes']
                    if value['first']:self.mode_desired=confirmed
                    elif self.mode_pending and value.get('target_modes') is not None:self.mode_desired=value['target_modes']
                    if self.mode_pending and confirmed==self.mode_desired:self.mode_pending=False
                    if not self.mode_pending:self.mode_desired=confirmed
                    for key,_,bit in MODE_DEFS:
                        on=bool(confirmed&bit);self.algorithm_states[key]=on
                        self.mode_buttons[key].configure(
                            text='确认中…' if self.mode_pending and bool(self.mode_desired&bit)!=on else ('关闭' if on else '开启'),
                            state='disabled' if self.mode_pending or (key=='ghe' and not self.ghe_supported) or (key=='eis' and not self.eis_supported) or (key=='fisheye' and not self.fisheye_supported) or (key=='rotation' and not self.rotation_supported) else 'normal')
                    for key in ('night','denoise','ghe'):self.show_strength(key,bool(self.mode_desired&MODE_BITS[key]) and (key!='ghe' or self.ghe_supported))
                    self.tuning_status.set('模式已回读；两种镜头模型互斥，两种稳像互斥；左原始、右处理')
                else:
                    for key in self.mode_buttons:self.mode_buttons[key].configure(state='disabled')
                    for key in ('night','denoise'):self.show_strength(key,True)
                    self.tuning_status.set('当前板卡支持强度滑条；上位机模式开关需下载 R21 位流')
                self.setting_tuning=False
            elif kind=='rotation_error':
                self.rotation_status.set(value);self.log('serial',value)
            elif kind=='eis_error':
                self.eis_status.set(value);self.log('serial',value)
            elif kind=='tune_reset':
                self.disable_tuning('板卡已重启，正在重新读取强度…')
            elif kind=='tune_error':
                self.disable_tuning(value);self.log('serial',value)
            elif kind=='serial_line':
                self.log('serial',value)
                night=re.search(r'NIGHT status=([0-9A-Fa-f]+)',value)
                denoise=re.search(r'DENOISE config=[0-9A-Fa-f]+ status=([0-9A-Fa-f]+)',value)
                if night:
                    status=int(night[1],16);self.algorithm_states['night']=bool(status&2);self.applied_states['night']=bool(status&1)
                if denoise:
                    status=int(denoise[1],16);self.algorithm_states['denoise']=bool(status&32);self.applied_states['denoise']=bool(status&64)
                if self.tuning_ready and (night or denoise) and self.firmware_version not in (21,22):
                    self.tuning_status.set('夜景：'+('开启' if self.algorithm_states['night'] else '关闭')+' · '+('非恒等曲线' if self.applied_states['night'] else '恒等/旁路')+'\n滤波：'+('开启' if self.algorithm_states['denoise'] else '关闭')+' · 新帧应用强度')
                match=CAM_PATTERN.search(value)
                if match:
                    dt,sensor,cap,display,skipped,flags,peak=match.groups();dt=int(dt)
                    if dt>0:
                        for key,number in [('sensor',sensor),('cap',cap),('display',display)]:self.metrics[key][0].set(f'{int(number)*1000/dt:.2f}')
                    self.bottom_state.set(f'采集监测  ·  丢帧 {skipped}  ·  FIFO 峰值 {peak}  ·  flags {flags}')
                bad=re.search(r'RAW good_new=(\d+) bad_new=(\d+)',value)
                if bad:self.metrics['bad'][0].set(bad[2]);self.metrics['bad'][1].configure(fg=RED if int(bad[2]) else GREEN)
                version=re.search(r'DVP (R\d+)',value)
                if version:self.device_label.set(version.group(1)+' · OV5640 · 完整帧网口抓拍')
            elif kind=='ports':
                self.ports_refresh_pending=False;self.apply_ports(value)
            elif kind=='ports_error':
                self.ports_refresh_pending=False;self.device_label.set('串口枚举失败：'+value)
                self.log('serial','串口枚举失败：'+value)
            elif kind=='serial_error':
                self.disable_tuning('串口出错，强度未确认')
                self.log('serial','连接/读取失败：'+value);self.serial_state.set('连接/读取失败，原因见串口日志');self.serial_status_label.configure(fg=RED)
                self.refresh_ports()
            elif kind=='serial_closed':
                self.disable_tuning('串口已断开；板卡保留最后设置，复位恢复默认值')
                self.serial_connected=False;self.serial_button.configure(text='连接串口',state='normal');self.port_combo.configure(state='readonly');self.baud_combo.configure(state='readonly')
                if self.serial_stop.is_set():self.serial_state.set('未连接');self.serial_status_label.configure(fg=MUTED)
                self.update_header()
            elif kind=='adapters':
                self.network_refresh_pending=False
                adapters=value.get('adapters',[]);addresses=value.get('addresses',[])
                wired=[a for a in adapters if not re.search(r'Wi-Fi|Wireless|WLAN',a.get('InterfaceDescription',''),re.I)]
                physical_indices={a.get('ifIndex') for a in wired}
                self.interface_by_ip={i['IPAddress']:i['InterfaceIndex'] for i in addresses if i.get('InterfaceIndex') in physical_indices}
                matches=[a for a in wired if any(i.get('IPAddress')==self.local_ip.get() and i.get('InterfaceIndex')==a.get('ifIndex') for i in addresses)]
                adapter=matches[0] if matches else next((a for a in wired if a.get('Status')=='Up'),wired[0] if wired else None)
                if adapter:
                    ips=[i.get('IPAddress') for i in addresses if i.get('InterfaceIndex')==adapter.get('ifIndex')]
                    status='已连接' if adapter['Status']=='Up' else '未连接'
                    self.adapter_state.set(f"{adapter['Name']} · {status} · {adapter['LinkSpeed']}\nIPv4：{', '.join(ips) or '未分配'}")
                    if self.local_ip.get() not in ips:self.log('network','填写的电脑 IP 不属于当前有线网卡；请核对后连接')
                else:self.adapter_state.set('没有检测到有线网卡')
            elif kind=='adapter_error':
                self.network_refresh_pending=False;self.adapter_state.set(value);self.log('network',value)
            elif kind=='network_ready':
                generation,client,info,connection=value
                if generation!=self.network_generation:client.close();continue
                self.network_client=client;self.network_busy=False;self.net_ready=True;self.connection=connection
                self.network_button.configure(text='断开以太网',state='normal');self.capture_button.configure(state='normal')
                capabilities=info.get('capabilities',[])
                night_capable='snapshot_night' in capabilities
                host_modes='host_modes' in capabilities
                self.snapshot_hint.set('0%无作用，100%为当前算法强度上限。\n'+
                    ('R21照片跟随滤波、夜景和均衡化开关及强度。' if 'global_histogram' in capabilities else
                     'R21照片跟随上位机夜景开关和强度。' if host_modes else
                     'R20照片跟随KEY4和夜景强度。' if night_capable else '当前位流照片不含夜景增强。'))
                self.network_state.set('板卡抓拍能力已确认 · 1920 × 1080'+
                    (' · R21模式控制' if host_modes else ' · 夜景跟随KEY4' if night_capable else ''))
                self.net_status_label.configure(fg=GREEN)
                self.log('network','板卡已就绪：'+str(info.get('firmware',info.get('device','FPGA'))));self.update_header()
            elif kind=='network_error':
                generation,error=value
                if generation!=self.network_generation:continue
                if self.network_client:self.network_client.close()
                self._finish_quality_capture(error='抓拍失败：'+error)
                self.network_client=None;self.network_busy=False;self.net_ready=False
                self.network_button.configure(text='重新连接以太网',state='normal');self.capture_button.configure(state='disabled')
                self.network_state.set('图像通道未就绪 · '+error);self.net_status_label.configure(fg=RED)
                self.bottom_state.set('以太网操作失败；没有保存不完整照片');self.log('network',error);self.update_header()
            elif kind=='progress':
                generation,done,total=value
                if generation!=self.network_generation:continue
                if self.quality_capture_side is not None:self.quality_panel.status.set(f'正在拍摄至 {"A" if self.quality_capture_side==0 else "B"} · 接收 {done/max(total,1)*100:.0f}%')
                self.progress['value']=done/total*100;self.network_state.set(f'正在接收：{done/1048576:.2f} / {total/1048576:.2f} MB')
            elif kind=='quality':
                generation,quality=value
                if generation!=self.network_generation:continue
                title={'KEEP':'可保留','REVIEW':'需复查','RETAKE':'建议重拍'}[quality['status']]
                advice=' '.join(quality['advice']+quality['warnings'])
                self.quality_info.set(f"{title} · 角点 {quality['corner_count']}/54 · {advice}")
                self.log('network',f"棋盘格检测：{title}；{advice}")
            elif kind=='quality_error':
                generation,error=value
                if generation==self.network_generation:self.quality_info.set('照片已保存，检测失败：'+error)
            elif kind=='calibration':
                result,path=value
                self.log('network',f"标定候选参数已保存：{path}；RMS={result['rms_pixels']:.4f} px；{len(result['views'])} 张")
                self.quality_info.set('标定候选已保存；'+(' '.join(result['warnings']) or '等待复核后接入 FPGA，尚未改变板卡算法。'))
            elif kind=='calibration_error':
                self.log('network','标定未完成：'+value);self.quality_info.set(value)
            elif kind=='photo':
                generation,image,path,metadata=value
                if generation!=self.network_generation:continue
                self.network_busy=False;self.photo_count+=1;self.original_image=image;self.last_photo_path=path
                self.preview_resize();self._photo_completed(path,metadata);self.progress['value']=100;self.capture_button.configure(state='normal')
                self.photo_info.set(f"1920 × 1080  ·  已保存 {self.photo_count} 张  ·  {path.name}")
                self.network_state.set('照片已完整接收并保存');self.net_status_label.configure(fg=GREEN)
                self.bottom_state.set('照片保存成功：'+str(path));self.log('network',f"保存成功：{path}  CRC32={metadata['crc32']}  补包轮数={metadata['retry_rounds']}")
        self._sync_buttons()
        self.root.after(80,self.poll_events)

    def close(self):
        self.quality_panel.close()
        self.closing=True;self.serial_stop.set();self.network_generation+=1
        if self.network_client:self.network_client.close()
        try:
            settings={key:getattr(self,key).get() for key in ['local_ip','board_ip','local_port','board_port','baud','output']}
            settings['serial_port']=self.port.get();self.settings_path.parent.mkdir(parents=True,exist_ok=True)
            if not (options.smoke_test or options.ui_preview):self.settings_path.write_text(json.dumps(settings,ensure_ascii=False,indent=2),encoding='utf-8')
        except OSError:pass
        self.root.destroy()

def main():
    root=tk.Tk();app=CameraConsole(root,discover=not (options.smoke_test or options.ui_preview))
    if options.smoke_test:
        root.after(1200,lambda:(print('GUI_SMOKE_PASS',flush=True),app.close()))
    root.mainloop()

if __name__=='__main__':
    try:main()
    except Exception:
        report=PROJECT/'reports/camera_console_startup_error.log'
        try:report.parent.mkdir(parents=True,exist_ok=True);report.write_text(traceback.format_exc(),encoding='utf-8')
        except OSError:pass
        try:messagebox.showerror('上位机启动失败','详细信息已保存：'+str(report))
        except Exception:pass
        raise
