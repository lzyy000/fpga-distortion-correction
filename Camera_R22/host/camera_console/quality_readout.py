"""Readable quality results and a shared native-pixel curvature plot.

The plot changes the display scale only. It never warps the image or changes
the straightness measurement. Connected samples are not dense edge estimates.
"""
import math
import numpy as np
from PIL import Image, ImageDraw
from quality_analysis import _font

COLORS = ('#2563EB', '#D97706')


def ordered_lines(result, axis):
    lines = result['straightness'].get('lines', []) if result else []
    coordinate = 1 if axis == 'row' else 0
    return sorted((line for line in lines if line['axis'] == axis),
                  key=lambda line: np.mean(np.asarray(line['points'])[:, coordinate]))


def available_lines(results):
    anchor = next((r for r in results if r and r['straightness'].get('lines')), None)
    return [(axis, index + 1) for axis in ('row', 'column')
            for index in range(len(ordered_lines(anchor, axis)))]


def line_name(key):
    return ('第 %d 行（从上数）' if key[0] == 'row' else '第 %d 列（从左数）') % key[1]


def curvature_profile(results, selected=None):
    keys = available_lines(results)
    anchor = next((r for r in results if r and r['straightness'].get('lines')), None)
    if not keys:
        return {'selected': None, 'profiles': [None, None], 'limit_px': .5,
                'note': '分析完整棋盘后显示弯曲偏差；未检出时不画零误差。'}
    if selected not in keys:
        selected = max(keys, key=lambda k: ordered_lines(anchor, k[0])[k[1]-1]['max_px'])
    profiles = []
    mismatch = False
    for result in results:
        lines = ordered_lines(result, selected[0])
        if (not result or selected[1] > len(lines) or
                result['straightness'].get('pattern') != anchor['straightness'].get('pattern')):
            profiles.append(None)
            mismatch |= bool(result and lines)
            continue
        line = lines[selected[1]-1]
        points = np.asarray(line['points'], dtype=float)
        projections = np.asarray(line['projections'], dtype=float)
        coordinate = 0 if selected[0] == 'row' else 1
        order = np.argsort(points[:, coordinate])
        segment = np.asarray(line['segment'], dtype=float)
        direction = segment[1] - segment[0]
        direction /= max(float(np.linalg.norm(direction)), 1e-12)
        if direction[coordinate] < 0:
            direction *= -1
        normal = (np.array([-direction[1], direction[0]]) if coordinate == 0
                  else np.array([direction[1], -direction[0]]))
        signed = (points - projections) @ normal
        along = projections @ direction
        fraction = (along - along.min()) / max(float(np.ptp(along)), 1e-12)
        profiles.append({'fraction': fraction[order].tolist(),
                         'signed_px': signed[order].tolist(),
                         'rms_px': line['rms_px'], 'max_px': line['max_px']})
    maximum = max((abs(v) for p in profiles if p for v in p['signed_px']), default=0)
    # Same vertical scale for A and B, with a half-pixel floor and 20% headroom.
    limit = max(.5, math.ceil(maximum * 1.2 * 10) / 10)
    return {'selected': selected, 'profiles': profiles, 'limit_px': limit,
            'note': ('棋盘规格不同，未配对另一图。' if mismatch else '') +
                    '纵轴为原图像素；两图同刻度。图只显示选中线，卡片统计整个棋盘。只测角点，点间连线辅助读数。'}


def metric_text(result):
    if not result:
        return '弯曲偏差 RMS — px · 最远 — px\n清晰度 MTF50：待分析'
    g, m = result['straightness'], result['mtf']
    number = lambda v: '—' if v is None else f'{v:.4f}'
    geometry = f"弯曲偏差 RMS {number(g.get('rms_px'))} px · 最远 {number(g.get('max_px'))} px（越小越直）"
    value = m.get('median_mtf50_cpp')
    if value is not None:
        mtf = f"清晰度 MTF50 {value:.4f} c/p · {m.get('edge_count', 0)} 条斜边（同倍率下越高越清晰）"
    else:
        reason = {'NO_VALID_EDGES': '无可靠斜边', 'SKIPPED': '未勾选测量',
                  'NOT_INSTALLED': '未配置测量工具', 'ERROR': '工具执行失败'}.get(m.get('status'), '暂无有效结果')
        mtf = f'清晰度未测得：{reason}；不代表清晰度为 0'
    return geometry + '\n' + mtf


def comparison_text(results):
    values = [r['straightness'].get('rms_px') if r else None for r in results]
    if all(v is not None for v in values):
        return f'棋盘弯曲 RMS：左 {values[0]:.4f} → 右 {values[1]:.4f} px；越小越直。仅反映本次角点采样。'
    return '看弯曲偏差判断直不直；看 MTF50 判断清不清晰。两项分别评价。'


def quality_narrative(assets,results):
    """Describe observed changes, and keep provenance separate from causation."""
    if not all(results):return '拍摄到 A/B 或导入两张图片后，分析这里会说明哪里变直、哪里变化较小，以及清晰度是否有可靠结果。'
    notes=[]
    metas=[(a or {}).get('metadata',{}) for a in assets]
    roles=(metas[0].get('capture_source') in (0,2) and metas[1].get('capture_source')==1
           and metas[1].get('processing')=='fpga_display_result')
    disabled_baseline=(all(m.get('capture_source')==1 for m in metas)
                       and metas[0].get('applied_modes') is not None and metas[1].get('applied_modes') is not None
                       and metas[0]['applied_modes']&0x61==0 and metas[1]['applied_modes']&0x61!=0)
    roles=roles or disabled_baseline
    if roles:
        notes.append(('来源：两图都是FPGA输出；左图几何矫正关闭，右图开启，可作开关对照。' if disabled_baseline else '来源：左为原图，右为FPGA处理图。')+
                     '两次抓拍不是同帧，请保持图卡与相机静止。')
        modes=metas[1].get('applied_modes')
        if modes is not None:
            names=('镜头畸变','双窗显示','滤波','夜景','直方图均衡','动态矫正','平面透视')
            active=[name for bit,name in enumerate(names) if modes&(1<<bit)]
            notes.append('右图处理：'+('、'.join(active) if active else '记录显示功能均关闭；本组不能证明矫正已开启')+'。')
            if modes&2:notes.append('右图包含板卡双窗画面；检测可能选中其中一块棋盘，请核对成像倍率和检测区域。')
    else:
        left,right=(m.get('capture_source') for m in metas)
        if left==right and left in (0,1,2):
            category={0:'无增强原图',1:'处理结果',2:'增强原图'}[left]
            notes.append(f'来源提醒：两张都是{category}，只能描述采样差异，不能归因于矫正。请确认两图各自拍摄时的处理开关。')
        else:notes.append('来源提醒：尚未核验为左原图/右处理图组合，以下是两张图片的采样差异。')
    source_notes=notes[:] if roles else []
    if roles:notes=[]
    ga,gb=(r['straightness'] for r in results)
    if ga.get('rms_px') is None or gb.get('rms_px') is None:
        notes.append('直线度：未在两图都识别出完整棋盘，暂时不能评价哪里变直。')
    elif ga.get('pattern')!=gb.get('pattern'):
        notes.append('直线度：两图棋盘规格不同，未进行逐行/列比较。')
    else:
        a,b=ga['rms_px'],gb['rms_px'];delta=a-b
        if abs(delta)<.01 or (a>0 and abs(delta)/a<.03):
            notes.append(f'整体：RMS {a:.4f}→{b:.4f}px，变化较小；单次采样不足以判断稳定提升。')
        else:
            change=f'{abs(delta)/a*100:.1f}%' if a>1e-9 else f'{abs(delta):.4f}px'
            notes.append(f"整体：本次角点偏差RMS{'减少' if delta>0 else '增加'}{change}（{a:.4f}→{b:.4f}px），右图采样线{'更直' if delta>0 else '偏差更大'}。")
        for axis,title in (('row','横线'),('column','竖线')):
            la,lb=ordered_lines(results[0],axis),ordered_lines(results[1],axis)
            ra=float(np.sqrt(np.mean([v*v for line in la for v in line['distances_px']])))
            rb=float(np.sqrt(np.mean([v*v for line in lb for v in line['distances_px']])))
            verb='偏差减小' if ra-rb>.01 else '偏差增加' if rb-ra>.01 else '变化较小'
            notes.append(f'{title}：{verb}，RMS {ra:.4f}→{rb:.4f}px。')
        changes=[(la['rms_px']-lb['rms_px'],(axis,i+1),la,lb)
                 for axis in ('row','column')
                 for i,(la,lb) in enumerate(zip(ordered_lines(results[0],axis),ordered_lines(results[1],axis)))]
        if changes:
            best=max(changes,key=lambda v:v[0])
            if best[0]>.01:
                prefix='改善较明显的位置' if roles else '偏差减小的位置（仅采样差异）'
                notes.append(f'{prefix}：{line_name(best[1])}，此线RMS {best[2]["rms_px"]:.4f}→{best[3]["rms_px"]:.4f}px；可在选线框查看。')
    ma,mb=(r['mtf'] for r in results)
    va,vb=ma.get('median_mtf50_cpp'),mb.get('median_mtf50_cpp')
    if ma.get('status')==mb.get('status')=='SKIPPED':
        notes.append('清晰度：本次未启用MTF50测量。')
    elif va is None or vb is None:
        missing='两图' if va is None and vb is None else '左图' if va is None else '右图'
        notes.append(f'清晰度：{missing}没有可靠MTF50结果，无法比较是否更清晰；未测得不等于清晰度为零。')
    else:
        trend='较高' if vb-va>.002 else '较低' if va-vb>.002 else '接近'
        notes.append(f'清晰度：右图MTF50中位值{trend}（{va:.4f}→{vb:.4f}c/p）。两图边缘未逐一配对，需在同倍率、同区域确认。')
    notes.extend(source_notes)
    notes.append('范围：结论仅适用于棋盘覆盖区域；角点偏差还包含检测和图卡误差，不是整幅镜头畸变率，也不评价梯形是否变为矩形。')
    return '\n'.join(notes)


class _SmoothDraw:
    def __init__(self,image,scale):self.draw=ImageDraw.Draw(image);self.scale=scale
    def coordinates(self,values):
        return [tuple(c*self.scale for c in p) for p in values] if isinstance(values[0],(list,tuple)) else tuple(c*self.scale for c in values)
    def line(self,xy,**kw):
        kw['width']=max(1,kw.get('width',1)*self.scale);self.draw.line(self.coordinates(xy),**kw)
    def ellipse(self,xy,**kw):self.draw.ellipse(self.coordinates(xy),**kw)
    def text(self,xy,text,**kw):self.draw.text(self.coordinates(xy),text,**kw)


def render_curvature(model, size=(1200, 210)):
    width, height = map(int, size)
    ss=3;out = Image.new('RGB', (width*ss, height*ss), '#FFFFFF')
    draw = _SmoothDraw(out,ss)
    if not model['selected']:
        draw.text((16, height//2-9), model['note'], fill='#718399', font=_font(12*ss))
        return out.resize((width,height),Image.Resampling.LANCZOS)
    narrow=width<950
    x0, x1, y0, y1 = 60, width-16, (46 if narrow else 29), height-24
    mid = (y0+y1)/2
    limit = model['limit_px']
    font = _font(11*ss)
    for value in (-limit, 0, limit):
        y = mid-value/limit*(y1-y0)/2
        draw.line((x0, y, x1, y), fill='#99A9BB' if value == 0 else '#E5EBF3')
        draw.text((7, y-8), f'{value:+.2f}' if value else '0', fill='#718399', font=font)
    draw.text((7, 3), '偏差 / px', fill='#718399', font=font)
    draw.text((x0, height-22), '起点', fill='#718399', font=font)
    draw.text((x1-28, height-22), '终点', fill='#718399', font=font)
    draw.text((x0+45, height-22), '靠近 0 更直 · 两图同刻度 · 角点间折线', fill='#718399', font=font)
    for side, profile in enumerate(model['profiles']):
        if profile is None:
            continue
        color = COLORS[side]
        points = [(x0+t*(x1-x0), mid-v/limit*(y1-y0)/2)
                  for t, v in zip(profile['fraction'], profile['signed_px'])]
        if len(points) > 1:
            draw.line(points, fill=color, width=2)
        for x, y in points:
            draw.ellipse((x-3, y-3, x+3, y+3), fill=color)
        caption = f"{'A 左图' if side == 0 else 'B 右图'} · {line_name(model['selected'])} · 最远 {profile['max_px']:.4f}px"
        draw.text((x0 if narrow else x0+side*(x1-x0)//2,3+side*18 if narrow else 3),caption,fill=color,font=font)
    return out.resize((width,height),Image.Resampling.LANCZOS)
