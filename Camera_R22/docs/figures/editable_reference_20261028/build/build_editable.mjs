import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { Presentation, PresentationFile } from "file:///C:/Users/HP/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/@oai/artifact-tool/dist/artifact_tool.mjs";

const base = "D:/FPGA/project/camera-1080p30-raw8-r12/camera-1080p30-raw8-r12/docs/figures/editable_reference_20261028";
const build=path.join(base,"build");
const output=path.join(base,"output");
const skill="C:/Users/HP/.codex/plugins/cache/openai-primary-runtime/presentations/26.1024.11018/skills/presentations";
const python="C:/Users/HP/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe";
const P=Presentation.create({slideSize:{width:1536,height:1100}});
const s=P.slides.add();
s.background.fill="#FFFFFF";
const ink="#102D4C", pale="#F9DFE0", green="#D9EFDA", red="#FF0000";
const tfont="Microsoft YaHei";
let id=0;

function box(name,x,y,w,h,fill=pale,stroke=ink,style="solid",width=2.3) {
  return s.shapes.add({name,geometry:"rect",position:{left:x,top:y,width:w,height:h},fill,
      line:{style,fill:stroke,width}});
}
function text(name,x,y,w,h,txt,size=23,bold=false,align="center") {
  const shape=s.shapes.add({name,geometry:"textbox",position:{left:x,top:y,width:w,height:h},
     fill:"none",line:{fill:"none",width:0}});
  shape.text=txt;
  shape.text.style={typeface:tfont,fontSize:size,bold,color:ink,alignment:align,
    verticalAlignment:"middle",autoFit:"shrinkText",wrap:"none",insets:0};
  return shape;
}
function line(name,x1,y1,x2,y2,opts={}) {
  const x=Math.min(x1,x2),y=Math.min(y1,y2);
  const w=Math.abs(x2-x1),h=Math.abs(y2-y1);
  if(w && h) throw new Error("only orthogonal lines");
  const reverse=(w?x2<x1:y2<y1);
  const tail=opts.end && !reverse || opts.start && reverse ? {type:"triangle",width:"med",length:"med"}:undefined;
  const head=opts.start && !reverse || opts.end && reverse ? {type:"triangle",width:"med",length:"med"}:undefined;
  return s.shapes.add({name,geometry:"connector",kind:"straight",
    position:{left:x,top:y,width:w,height:h},
    line:{style:"solid",fill:ink,width:opts.width??2.4},head,tail});
}
function n(name,x,y,w,h,title,sub,ext=false,sz=24) {
  box(name+"框",x,y,w,h,ext?green:pale);
  if(sub) {
    text(name+"标题",x+7,y+6,w-14,37,title,sz,true);
    text(name+"说明",x+7,y+42,w-14,27,sub,19,false);
  } else {
    text(name+"文字",x+7,y+7,w-14,h-14,title,sz,true);
  }
}

// Reference frame. The partly cropped HDMI box is completed at the bottom.
box("FPGA红色虚线边界",235,166,1123,793,"none",red,"dashed",2.2);

// Main vertical acquisition spine.
line("相机到RAW",768,146,768,194,{end:true});
line("RAW到FIFO",768,262,768,292,{end:true});
line("FIFO到图像总线",768,365,768,399);
line("图像总线",412,399,1276,399);
line("总线到矫正区域",412,399,412,431,{end:true});
line("总线到稳像区域",768,399,768,431,{end:true});
line("总线到增强区域",1127,399,1127,431,{end:true});

// Upper-right host control branch exactly follows the chosen picture.
line("上位机到软核",1197,146,1197,210,{end:true});
line("软核配置总线竖线",1276,282,1276,399);
line("配置总线横段",1276,352,1320,352);
line("配置总线竖段",1320,352,1320,667);
for(const [i,y] of [499,585,667].entries())
  line("配置到增强"+i,1320,y,1267,y,{end:true});

// Calibration and IMU inputs, preserving the specific image's lines.
line("标定参数到映射表",213,499,288,499,{end:true});
line("映射表到稳像",552,505,654,505,{end:true});
line("映射表到畸变矫正",403,547,403,602,{end:true});
line("IMU到畸变矫正",213,635,298,635,{end:true});
line("稳像到透射变换",769,547,769,602,{end:true});

// Enhancement pixel bus and its left arrows.
line("增强像素输入总线",940,399,940,667);
for(const [i,y] of [499,585,667].entries())
  line("像素到增强"+i,940,y,1003,y,{end:true});

// Returned image data and memory/display outputs.
line("矫正结果向下",433,684,433,736,{end:true});
line("透射结果向下",769,684,769,736,{end:true});
line("夜景结果向下",1131,707,1131,736,{end:true});
line("处理结果汇合线",433,736,1131,736);
line("汇合线到DMA",769,736,769,766,{end:true});
line("DDR双向访问",932,802,1296,802,{start:true,end:true});
line("DMA到显示组合",769,838,769,866,{end:true});
line("显示组合到HDMI",769,939,769,977,{end:true});

// Small labels, titles and editable blocks.
text("图名",405,6,726,49,"FPGA图像处理系统框图",44,true);
text("FPGA标签",257,180,135,38,"FPGA",35,true,"left");
text("UART文字",1209,145,60,24,"UART",19,false,"left");
text("配置文字",1289,313,48,27,"配置",21,true,"left");
text("数据总线文字",804,369,230,26,"图像像素流（FIFO）",21,true,"left");
text("左列标题",324,431,176,30,"畸变矫正",27,true);
text("中列标题",665,431,208,30,"稳像与变换",27,true);
text("右列标题",1025,431,209,30,"图像增强",27,true);
text("坐标表说明",410,555,166,28,"坐标表（经DDR）",20,true,"left");
n("OV5640",599,73,337,73,"OV5640图像采集","1080p30 · RAW8",true,25);
n("上位机",1072,74,257,73,"上位机",null,true,27);
n("RAW8颜色恢复",632,194,271,68,"RAW8颜色恢复","Bayer插值",false,24);
n("异步FIFO",632,292,271,73,"异步FIFO","跨时钟域 · 像素打包",false,24);
n("RISC-V软核",1061,210,276,72,"RISC-V软核与模式寄存器","独立开关 · 强度调节",false,21);
n("镜头标定参数",20,466,193,61,"镜头标定参数",null,true,24);
n("IMU实时数据",20,602,193,61,"IMU实时数据",null,true,24);
n("映射表生成器",288,466,264,81,"定点坐标映射表生成器","流水线定点运算",false,21);
n("畸变矫正",298,602,269,82,"畸变矫正","行缓存 · 双线性插值",false,24);
n("IMU旋转稳像",654,466,230,81,"IMU旋转稳像","实时姿态补偿",false,24);
n("透射变换",654,602,230,82,"透射变换","坐标映射 · 重采样",false,24);
n("滤波降噪",1003,466,264,72,"滤波降噪","空间窗口 · 历史帧融合",false,24);
n("全局直方图均衡化",1003,550,264,72,"全局直方图均衡化","直方图统计 · 增益映射",false,22);
n("夜景增强",1003,635,264,72,"夜景增强","亮度统计 · Gamma",false,24);
n("DMA仲裁和DDR3控制器",606,766,326,72,"DMA仲裁与DDR3控制器","突发读写 · 帧缓存调度",false,21);
n("显示组合与行缓冲",606,866,326,73,"显示组合与行缓冲","全屏／双视窗 · 按行预取",false,23);
n("外部DDR3",1296,766,224,72,"外部DDR3","图像帧 · 坐标映射表",true,24);
n("HDMI显示",638,977,260,73,"HDMI显示","1080p60刷新",true,24);

await fs.mkdir(build,{recursive:true});await fs.mkdir(output,{recursive:true});
const png=await P.export({slide:s,format:"png",scale:1});
await fs.writeFile(path.join(build,"preview.png"),new Uint8Array(await png.arrayBuffer()));
const draft=path.join(build,"draft.pptx");
await (await PresentationFile.exportPptx(P)).save(draft);
const {finalizePresentation}=await import(pathToFileURL(path.join(skill,"container_tools/artifact_tool_utils.mjs")).href);
const final=path.join(output,"FPGA系统框图_可编辑.pptx");
const result=await finalizePresentation({
  workspaceDir:base,candidatePath:draft,finalPath:final,pythonExecutable:python,
  integrityValidatorPath:path.join(skill,"container_tools/inspect_presentation_package_integrity.py"),
  layoutValidatorPath:path.join(skill,"container_tools/inspect_presentation_layout_geometry.py"),
  layoutArgs:["--expected-slide-size-emu","14630400,10477500"],
  explicitTotalSlideCount:1,
  fontPolicy:{basis:"design",families:["Microsoft YaHei"]},
  verifyArtifactToolImport:true,receiptPath:path.join(build,"validation.json")
});
console.log(JSON.stringify({final,shapeCount:s.shapes.items.length,result},null,2));
