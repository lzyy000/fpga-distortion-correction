"""Small native Tk widgets for the blue/white R29 desktop console."""
import tkinter as tk
from tkinter import ttk
from PIL import Image,ImageTk

BG='#F3F6FB';WHITE='#FFFFFF';INK='#173250';MUTED='#718399';BLUE='#2563EB'
PALE='#EAF1FF';BORDER='#DCE5F1';GREEN='#12816D';RED='#C74758';AMBER='#B57517';DARK='#102238'
FONT='Microsoft YaHei UI'

def styles(root):
    root.configure(bg=BG)
    s=ttk.Style(root);s.theme_use('clam')
    s.configure('.',font=(FONT,10),background=WHITE,foreground=INK)
    s.configure('TFrame',background=WHITE)
    s.configure('TLabel',background=WHITE,foreground=INK)
    s.configure('TEntry',padding=(8,6),fieldbackground=WHITE,bordercolor=BORDER,lightcolor=BORDER,darkcolor=BORDER)
    s.configure('TCombobox',padding=(7,5),fieldbackground=WHITE,background=WHITE,bordercolor=BORDER,arrowsize=13)
    s.map('TCombobox',fieldbackground=[('readonly',WHITE)],selectbackground=[('readonly',PALE)],selectforeground=[('readonly',INK)])
    s.configure('TButton',padding=(11,7),background=PALE,foreground='#27528B',borderwidth=0,focuscolor=BLUE)
    s.map('TButton',background=[('disabled','#F0F3F8'),('active','#DCE8FF'),('pressed','#CDDDFB')],foreground=[('disabled','#A1AEBF')])
    s.configure('Primary.TButton',background=BLUE,foreground=WHITE,font=(FONT,10,'bold'),padding=(15,9))
    s.map('Primary.TButton',background=[('disabled','#C9D7ED'),('active','#1D54D0'),('pressed','#1947AD')],foreground=[('disabled','#F8FAFC')])
    s.configure('Quiet.TButton',background=WHITE,foreground=MUTED,padding=(8,6))
    s.map('Quiet.TButton',background=[('active',PALE)])
    s.configure('TNotebook',background=BG,borderwidth=0,tabmargins=(0,0,0,8))
    s.configure('TNotebook.Tab',padding=(17,9),background='#EAF0F8',foreground=MUTED,borderwidth=0)
    s.map('TNotebook.Tab',background=[('selected',WHITE),('active','#E3ECFA')],foreground=[('selected',BLUE)])
    s.configure('Side.TNotebook',background=WHITE,tabmargins=(0,0,0,4))
    s.configure('Side.TNotebook.Tab',padding=(12,9),font=(FONT,9))
    s.configure('Logs.TNotebook',background=WHITE,tabmargins=(8,4,0,0))
    s.configure('Logs.TNotebook.Tab',padding=(13,5),font=(FONT,9))
    s.configure('Horizontal.TProgressbar',background=BLUE,troughcolor='#E9EFF8',borderwidth=0,thickness=6)
    s.configure('Horizontal.TScale',background=WHITE,troughcolor='#E6EDF8',sliderlength=16)
    s.configure('Vertical.TScrollbar',background='#CCD9EB',troughcolor=WHITE,borderwidth=0,arrowsize=10)

    root.update_idletasks()

def label(parent,text='',variable=None,size=10,color=INK,bold=False,**kw):
    widget=tk.Label(parent,text=text,textvariable=variable,font=(FONT,size,'bold'if bold else 'normal'),
                    fg=color,bg=parent.cget('bg'),**kw)
    if 'wraplength'in kw:
        def wrap(e):
            if e.width>150 and abs(int(widget.cget('wraplength'))-e.width)>3:widget.configure(wraplength=e.width-2)
        widget.bind('<Configure>',wrap)
    return widget

def card(parent,title=None,subtitle=None):
    f=tk.Frame(parent,bg=WHITE,highlightbackground=BORDER,highlightthickness=1)
    if title:label(f,title,size=12,bold=True,anchor='w').pack(fill='x',padx=16,pady=(14,3 if subtitle else 12))
    if subtitle:label(f,subtitle,size=9,color=MUTED,anchor='w',justify='left',wraplength=290).pack(fill='x',padx=16,pady=(0,12))
    return f

class Badge(tk.Label):
    def __init__(self,parent,text='未连接'):
        super().__init__(parent,font=(FONT,9),padx=10,pady=5)
        self.set(text)
    def set(self,text,tone='neutral'):
        colors={'neutral':('#EEF2F7',MUTED),'blue':(PALE,BLUE),'green':('#E4F4EE',GREEN),
                'amber':('#FFF3DB',AMBER),'red':('#FBEAED',RED)}
        bg,fg=colors[tone];self.configure(text=text,bg=bg,fg=fg)

class FlatTabs(tk.Frame):
    """Flat keyboard-focusable navigation, with the small Notebook API we use."""
    def __init__(self,parent,style='',height=None):
        background=WHITE if style else BG
        super().__init__(parent,bg=background)
        self.bar=tk.Frame(self,bg=background);self.bar.pack(fill='x',pady=(0,6 if not style else 2))
        self.content=tk.Frame(self,bg=background);self.content.pack(fill='both',expand=True)
        if height:self.content.configure(height=height);self.content.pack_propagate(False)
        self.pages=[];self.buttons=[];self.lines=[];self.current=None;self.background=background
    def add(self,frame,text):
        index=len(self.pages);self.pages.append(frame)
        holder=tk.Frame(self.bar,bg=self.background);holder.pack(side='left',padx=(0,3))
        button=tk.Button(holder,text=text,command=lambda:self.select(index),relief='flat',bd=0,
                         highlightthickness=0,padx=12,pady=9,bg=self.background,fg=MUTED,
                         activebackground=PALE,activeforeground=BLUE,font=(FONT,9),cursor='hand2',takefocus=1)
        button.pack(fill='x');line=tk.Frame(holder,bg=self.background,height=2);line.pack(fill='x')
        self.buttons.append(button);self.lines.append(line)
        if self.current is None:self.select(index)
    def select(self,value=None):
        if value is None:return self.current
        index=value if isinstance(value,int)else self.pages.index(value)
        if self.current is not None:self.pages[self.current].pack_forget()
        self.current=index;self.pages[index].pack(in_=self.content,fill='both',expand=True)
        for n,(button,line)in enumerate(zip(self.buttons,self.lines)):
            button.configure(fg=BLUE if n==index else MUTED,font=(FONT,9,'bold'if n==index else 'normal'),bg=WHITE if n==index else self.background)
            line.configure(bg=BLUE if n==index else self.background)
        callback=getattr(self,'on_select',None)
        if callable(callback):callback()
    def index(self,value):return value if isinstance(value,int)else self.pages.index(value)

class StrengthSlider(tk.Canvas):
    def __init__(self,parent,variable,command,from_=0,to=100):
        super().__init__(parent,width=140,height=22,bg=WHITE,highlightthickness=0,takefocus=1)
        self.variable=variable;self.command=command;self.disabled=True
        self.bind('<Configure>',lambda e:self.paint());variable.trace_add('write',lambda *a:self.paint())
        self.bind('<Button-1>',self.move);self.bind('<B1-Motion>',self.move)
        self.bind('<Left>',lambda e:self.step(-2));self.bind('<Right>',lambda e:self.step(2))
    def state(self,states):self.disabled='disabled'in states;self.paint()
    def step(self,amount):
        if not self.disabled:self.variable.set(max(0,min(100,self.variable.get()+amount)));self.command(str(self.variable.get()))
        return 'break'
    def move(self,e):
        if self.disabled:return 'break'
        self.focus_set();self.variable.set(max(0,min(100,(e.x-9)/max(1,self.winfo_width()-18)*100)));self.command(str(self.variable.get()));return 'break'
    def paint(self):
        self.delete('all');width=max(20,self.winfo_width());x=9+(width-18)*self.variable.get()/100
        color='#B5C8E7'if self.disabled else BLUE
        self.create_line(9,11,width-9,11,fill='#E6EDF8',width=4,capstyle='round')
        self.create_line(9,11,x,11,fill=color,width=4,capstyle='round')
        self.create_oval(x-6,5,x+6,17,fill=WHITE,outline=color,width=2)

class Progress(tk.Canvas):
    def __init__(self,parent,maximum=100):
        super().__init__(parent,height=5,bg='#E9EFF8',highlightthickness=0)
        self.value=0;self.maximum=maximum;self.bind('<Configure>',lambda e:self.paint())
    def __setitem__(self,key,value):
        if key=='value':self.value=value;self.paint()
        else:super().__setitem__(key,value)
    def paint(self):
        self.delete('all');width=self.winfo_width()*max(0,min(1,self.value/self.maximum))
        if width:self.create_rectangle(0,0,width,6,fill=BLUE,outline=BLUE)

class Switch(tk.Canvas):
    def __init__(self,parent,variable,command):
        super().__init__(parent,width=45,height=28,bg=WHITE,highlightthickness=0,takefocus=1,cursor='hand2')
        self.variable=variable;self.command=command;self.disabled=True
        variable.trace_add('write',lambda *args:self.paint())
        self.bind('<Button-1>',lambda e:self.invoke());self.bind('<space>',lambda e:self.invoke())
        self.bind('<Return>',lambda e:self.invoke());self.bind('<FocusIn>',lambda e:self.paint());self.bind('<FocusOut>',lambda e:self.paint())
        self.paint()
    def state(self,states=None):
        if states is None:return ('disabled',)if self.disabled else ()
        if 'disabled'in states:self.disabled=True
        if '!disabled'in states:self.disabled=False
        self.configure(cursor='arrow'if self.disabled else 'hand2');self.paint()
    def invoke(self):
        if self.disabled:return 'break'
        self.focus_set();self.variable.set(not self.variable.get());self.command();return 'break'
    def paint(self):
        self.delete('all');on=self.variable.get()
        fill=('#BCD0EE'if on else '#E2E8F1')if self.disabled else (BLUE if on else '#C5D0DF')
        self.create_rectangle(13,5,32,23,fill=fill,outline=fill)
        self.create_oval(4,5,22,23,fill=fill,outline=fill);self.create_oval(23,5,41,23,fill=fill,outline=fill)
        x=25 if on else 6;self.create_oval(x,7,x+14,21,fill=WHITE,outline=WHITE)
        if self.focus_get()==self:self.create_rectangle(1,1,44,27,outline=BLUE,dash=(2,2))

class ScrollPane(tk.Frame):
    def __init__(self,parent):
        super().__init__(parent,bg=WHITE)
        self.canvas=tk.Canvas(self,bg=WHITE,highlightthickness=0,width=300)
        bar=ttk.Scrollbar(self,orient='vertical',command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=bar.set);bar.pack(side='right',fill='y');self.canvas.pack(side='left',fill='both',expand=True)
        self.content=tk.Frame(self.canvas,bg=WHITE);self.window=self.canvas.create_window(0,0,window=self.content,anchor='nw')
        self.content.bind('<Configure>',lambda e:self.canvas.configure(scrollregion=self.canvas.bbox('all')))
        self.canvas.bind('<Configure>',lambda e:self.canvas.itemconfigure(self.window,width=e.width))
        self.bind_all('<MouseWheel>',self.wheel,add='+')
    def wheel(self,event):
        widget=self.winfo_containing(event.x_root,event.y_root)
        while widget is not None:
            if widget==self:
                if self.content.winfo_height()>self.canvas.winfo_height():self.canvas.yview_scroll(-int(event.delta/120),'units');return 'break'
                return
            widget=getattr(widget,'master',None)

class ImageView(tk.Canvas):
    def __init__(self,parent,title='尚未拍摄',detail='连接以太网后，拍照并接收完整帧',zoomable=False):
        super().__init__(parent,bg=DARK,highlightthickness=0,height=220)
        self.source=None;self.photo=None;self.empty_title=title;self.empty_detail=detail
        self.transform=None;self.markers=[];self.zoomable=zoomable;self.actual_size=False;self.offset=(0,0);self._timer=None;self._drag=None
        self._image_cache_key=None;self.selected_marker=None
        self.bind('<Configure>',self.schedule)
        if zoomable:
            self.bind('<Double-Button-1>',lambda e:self.toggle_zoom());self.bind('<ButtonPress-1>',self.drag_start);self.bind('<B1-Motion>',self.drag_move)
    def schedule(self,event=None):
        if self._timer:self._root().after_cancel(self._timer)
        self._timer=self._root().after(60,self.draw)
    def set_image(self,image):
        if image is not self.source:self._image_cache_key=None
        self.source=image;self.offset=(0,0);self.draw()
    def fit(self):self.actual_size=False;self.offset=(0,0);self.draw()
    def toggle_zoom(self):self.actual_size=not self.actual_size;self.offset=(0,0);self.draw()
    def drag_start(self,e):self._drag=(e.x,e.y,*self.offset)
    def drag_move(self,e):
        if self.actual_size and self._drag:
            x,y,ox,oy=self._drag;self.offset=(ox+e.x-x,oy+e.y-y);self.draw()
    def image_point(self,x,y):
        if self.source is None or self.transform is None:return None
        ox,oy,scale=self.transform;u=(x-ox)/scale;v=(y-oy)/scale
        return (u,v)if 0<=u<self.source.width and 0<=v<self.source.height else None
    def draw(self):
        self._timer=None;self.delete('all');w=max(1,self.winfo_width());h=max(1,self.winfo_height())
        if self.source is None:
            self.transform=None;x,y=w/2,h/2-32
            self.create_rectangle(x-25,y-14,x+25,y+18,outline='#52769E',width=2)
            self.create_oval(x-9,y-8,x+9,y+10,outline='#7095BF',width=2)
            self.create_line(x-17,y-14,x-11,y-21,x+8,y-21,x+14,y-14,fill='#52769E',width=2)
            self.create_text(w/2,y+49,text=self.empty_title,fill='#DDE9F7',font=(FONT,17,'bold'))
            self.create_text(w/2,y+80,text=self.empty_detail,fill='#83A2C5',font=(FONT,10),width=max(100,w-40))
            return
        scale=1 if self.actual_size else min((w-24)/self.source.width,(h-24)/self.source.height)
        scale=max(.01,scale);size=(max(1,round(self.source.width*scale)),max(1,round(self.source.height*scale)))
        key=(id(self.source),size)
        if key!=self._image_cache_key:
            self.photo=ImageTk.PhotoImage(self.source.resize(size,Image.Resampling.LANCZOS),master=self);self._image_cache_key=key
        ox=(w-size[0])/2+self.offset[0];oy=(h-size[1])/2+self.offset[1]
        self.transform=(ox,oy,scale);self.create_image(ox,oy,image=self.photo,anchor='nw')
        if len(self.markers)>=2:
            vertices=[coordinate for x,y in self.markers for coordinate in(ox+x*scale,oy+y*scale)]
            if len(self.markers)==4:vertices+=vertices[:2]
            self.create_line(*vertices,fill='#D8B45A',width=1,dash=(4,3))
        for n,(x,y)in enumerate(self.markers):
            px=ox+x*scale;py=oy+y*scale;self.create_oval(px-5,py-5,px+5,py+5,fill='#FFCE62',outline=WHITE,width=1)
            if n==self.selected_marker:self.create_oval(px-9,py-9,px+9,py+9,outline='#76A8FF',width=2)
            self.create_text(px+12,py-12,text=str(n+1),fill=WHITE,font=(FONT,10,'bold'))
