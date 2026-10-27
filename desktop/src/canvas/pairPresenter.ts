// The original Mac order: one negative's prints -> each grade -> pairCoverage.
// Film simulation remains in Vulkan; the existing WebGL Layer 2 grades pixels.
import {GLRenderer} from './glRenderer';
import type {RenderReply,RgbaImage} from '../host/client';
import type {PairDocument} from '@shared/pairs';
import {type FilmParams,jsonEqual} from '@shared/params';
import {type Adjustments,isNeutral} from '@shared/adjustments';
import {GEOMETRY_DEFAULT} from '@shared/geometry';
import {composePairPixels,filmPrint,printDelta,type Rect} from '@shared/pairPresentation';
let renderer:GLRenderer|null=null;
function grade(src:RgbaImage,a:Adjustments):Uint8Array {
  if(!a.enabled||isNeutral(a))return src.data;
  renderer??=new GLRenderer(new OffscreenCanvas(1,1));
  if(src.width>renderer.maxTexture||src.height>renderer.maxTexture)throw new Error('Pair print exceeds the WebGL texture limit');
  renderer.setImage(src);
  const size={width:src.width,height:src.height};
  const out=renderer.renderOutput({viewport:size,offset:{x:0,y:0},outSize:size,sourceSize:size,display:GEOMETRY_DEFAULT,editingCrop:null,adjustments:a,compare:0,split:.5,surround:0},size.width,size.height);
  if(!out)throw new Error('Could not grade the pair print');return out;
}
export async function presentPair(base:RenderReply,doc:PairDocument,p:FilmParams,a:Adjustments,rects:Rect[],render:(delta:ReturnType<typeof printDelta>)=>Promise<RgbaImage>):Promise<RenderReply> {
  const film=filmPrint(p),layers:(Uint8Array|null)[]=[];
  for(const h of [doc.left,doc.right]){
    if(!h){layers.push(null);continue;}
    const ownPrint=h.print&&!jsonEqual(h.print,film),ownGrade=h.adjustments&&!jsonEqual(h.adjustments,a);
    if(!ownPrint&&!ownGrade){layers.push(null);continue;}
    const src=ownPrint?await render(printDelta(p,h.print!)):base;
    if(src.width!==base.width||src.height!==base.height)throw new Error('Pair print layer size mismatch');
    layers.push(grade(src,h.adjustments??a));
  }
  return {...base,data:composePairPixels(grade(base,a),base,layers,rects),pregraded:true};
}
