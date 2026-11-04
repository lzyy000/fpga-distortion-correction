"""Antialiased diagnostic overlays. Source pixels and metrology stay unchanged."""
import numpy as np
from PIL import Image, ImageDraw
from quality_readout import ordered_lines


def display_shapes(result, selected, mode='偏差放大', gain=50, side=0, layers=None):
    if not result or mode == '干净照片':return []
    if mode == '检测标记':
        from quality_analysis import annotation_shapes
        return annotation_shapes(result, **(layers or {}))
    if not selected:return []
    lines=ordered_lines(result,selected[0]);index=selected[1]-1
    if index>=len(lines):return []
    line=lines[index]
    points=np.asarray(line['points']);projections=np.asarray(line['projections'])
    axis=0 if selected[0]=='row' else 1
    order=np.argsort(points[:,axis])
    magnified=projections+(points-projections)*gain
    # A labelled quadratic trend makes bowing readable without presenting the
    # corner detector's local jitter as continuous lens distortion. Measured
    # samples remain visible as dots; all reported metrics still use samples.
    q=projections[order];p=points[order]
    direction=q[-1]-q[0];direction/=max(float(np.linalg.norm(direction)),1e-12)
    normal=np.array([-direction[1],direction[0]])
    along=(q-q[0])@direction;span=max(float(along[-1]),1e-12)
    t=along/span;signed=(p-q)@normal
    coefficients=np.polynomial.polynomial.polyfit(t,signed,min(2,len(t)-1))
    dense=np.linspace(0,1,120)
    trend=q[0]+dense[:,None]*span*direction+np.polynomial.polynomial.polyval(dense,coefficients)[:,None]*gain*normal
    color=('#52ADFF','#FFAB5C')[side]
    shapes=[('line',line['segment'],'#D9E9F8',None),
            ('polyline',trend.tolist(),color,None)]
    for p,q in zip(projections,magnified):
        shapes.append(('line',[p.tolist(),q.tolist()],color,None))
        shapes.append(('dot',q.tolist(),color,None))
    return shapes


def render_overlay(size, shapes, transform=(0,0,1), supersample=3, show_text=False):
    """Render fractional screen coordinates on a separate 3x RGBA layer."""
    width,height=map(int,size);ss=supersample
    out=Image.new('RGBA',(max(1,width*ss),max(1,height*ss)),(0,0,0,0))
    draw=ImageDraw.Draw(out);ox,oy,scale=transform
    def point(p):return ((ox+p[0]*scale)*ss,(oy+p[1]*scale)*ss)
    for kind,coords,color,text in shapes:
        if kind in ('line','polyline'):
            draw.line([point(p) for p in coords],fill=color,width=ss if kind=='line' else 2*ss,joint='curve')
        else:
            x,y=point(coords)
            if not -10*ss<x<(width+10)*ss or not -10*ss<y<(height+10)*ss:continue
            if kind=='dot':draw.ellipse((x-2*ss,y-2*ss,x+2*ss,y+2*ss),fill=color)
            else:
                draw.line((x-2*ss,y,x+2*ss,y),fill=color,width=ss)
                draw.line((x,y-2*ss,x,y+2*ss),fill=color,width=ss)
            if show_text and text:
                from quality_analysis import _font
                draw.text((x+5*ss,y+2*ss),text,fill=color,font=_font(11*ss),stroke_width=ss,stroke_fill='#102238')
    return out.resize((width,height),Image.Resampling.LANCZOS)


def diagnostic_image(image,result,selected,mode='偏差放大',gain=50,side=0,layers=None):
    out=image.convert('RGBA')
    out.alpha_composite(render_overlay(image.size,display_shapes(result,selected,mode,gain,side,layers)))
    if mode=='偏差放大' and result:
        from quality_analysis import _font
        draw=ImageDraw.Draw(out)
        caption=f'二阶趋势 ×{gain} · 点为实测（仅标记放大）'
        draw.rectangle((8,8,600,44),fill='#102238')
        draw.text((16,12),caption,font=_font(20),fill='white')
    return out.convert('RGB')
