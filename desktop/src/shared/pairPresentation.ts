import {type FilmParams,fullDelta,jsonEqual} from './params';
import type {Adjustments} from './adjustments';
import type {PairDocument,PrintTrim} from './pairs';
import type {FrameLayout} from './filmFrame';
export type Rect=[number,number,number,number];
export const filmPrint=(p:FilmParams):PrintTrim=>({brightnessStops:p.printBrightnessStops,yFilterShift:p.yFilterShift,mFilterShift:p.mFilterShift,preflashExposure:p.preflashExposure});
export function printDelta(p:FilmParams,t:PrintTrim) {
  const d=fullDelta({...p,printBrightnessStops:t.brightnessStops,yFilterShift:t.yFilterShift,mFilterShift:t.mFilterShift,preflashExposure:t.preflashExposure});
  return {print_exposure:d.print_exposure!,y_filter_shift:d.y_filter_shift!,m_filter_shift:d.m_filter_shift!,preflash_exposure:d.preflash_exposure!};
}
export const pairHasPresentation=(doc:PairDocument,p:FilmParams,a:Adjustments)=>[doc.left,doc.right].some(h=>h&&((h.print&&!jsonEqual(h.print,filmPrint(p)))||(h.adjustments&&!jsonEqual(h.adjustments,a))));
export function samePairDecode(a:PairDocument,b:PairDocument) {
  const key=(p:PairDocument)=>JSON.stringify({spacingMM:p.spacingMM,onStrip:p.onStrip,turned:p.turned,holes:[p.left,p.right].map(h=>h?{
    path:h.path,geometry:h.geometry,placement:h.placement,decode:h.decode,autoExposure:h.autoExposure,exposureEV:h.exposureEV,meterMethod:h.meterMethod}:null)});
  return key(a)===key(b);
}
/** Same axis-aligned gate rectangles as Mac pairHoleRects, y down. */
export function presentationRects(layout:FrameLayout|null,rects:number[][]):Rect[] {
  if(!layout?.valid)return rects.map(r=>r.slice(0,4) as Rect);
  return layout.gates.map(q=>{const xs=[q[0]!,q[2]!,q[4]!,q[6]!],ys=[q[1]!,q[3]!,q[5]!,q[7]!];return [Math.min(...xs),Math.min(...ys),Math.max(...xs)-Math.min(...xs),Math.max(...ys)-Math.min(...ys)];});
}
/** Original pairCoverage + ordered mix; inputs have already been graded. */
export function composePairPixels<T extends Uint8Array|Uint16Array>(base:T,size:{width:number;height:number},layers:(T|null)[],rects:Rect[]):T {
  const out=base.slice() as T,{width:w,height:h}=size;
  if(base.length!==w*h*4)throw new Error('Invalid pair base pixels');
  for(let side=0;side<2;side++){
    const src=layers[side],r=rects[side];if(!src)continue;
    if(!r||src.length!==base.length)throw new Error('Pair print layer size mismatch');
    const x0=r[0]*w,y0=r[1]*h,x1=(r[0]+r[2])*w,y1=(r[1]+r[3])*h;
    for(let y=Math.max(0,Math.floor(y0-1));y<Math.min(h,Math.ceil(y1+1));y++)for(let x=Math.max(0,Math.floor(x0-1));x<Math.min(w,Math.ceil(x1+1));x++){
      const d=Math.min(x+.5-x0,x1-x-.5,y+.5-y0,y1-y-.5),a=Math.max(0,Math.min(1,d/1.5+.5));
      if(!a)continue;const i=(y*w+x)*4;
      for(let c=0;c<3;c++)out[i+c]=Math.round(out[i+c]!*(1-a)+src[i+c]!*a);
    }
  }return out;
}
