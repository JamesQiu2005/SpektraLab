import type { PairInfo } from './protocol';
import { type FilmParams, filmFormatMM,clamp } from './params';
import { type Geometry, GEOMETRY_DEFAULT, decodeGeometry, encodeGeometry } from './geometry';
import { type DecodeSettings, DECODE_DEFAULT, decodeSidecar } from './sidecar';
import { resolveImprints } from './imprints';
import {type Adjustments,decodeAdjustments} from './adjustments';

export interface PrintTrim {brightnessStops:number;yFilterShift:number;mFilterShift:number;preflashExposure:number}
export type PairScope='frame'|'film';
export type PairLayer='film'|PairSide;

export interface PairHole { path: string; placement: {scale:number;x:number;y:number;quarterTurns:number};
  geometry: Geometry; decode: DecodeSettings; autoExposure: boolean; exposureEV: number; meterMethod?: string|null;
  print?:PrintTrim|null; adjustments?:Adjustments|null;printScope?:PairScope;exposureScope?:PairScope;
  meteredEV?:number;meteredFor?:string;
  [key:string]:unknown }
export interface PairDocument { schemaVersion: number; folder: string; left: PairHole|null; right: PairHole|null;
  spacingMM:number;onStrip:boolean;turned:boolean; [key:string]:unknown }
export type PairSide='left'|'right';
export const isPairPath=(p:string)=>p.toLowerCase().endsWith('.spektrapair');
const object=(v:unknown):Record<string,unknown>=>v&&typeof v==='object'&&!Array.isArray(v)?v as Record<string,unknown>:{};
const n=(v:unknown,d:number,min:number,max:number)=>typeof v==='number'&&Number.isFinite(v)?Math.min(max,Math.max(min,v)):d;
export function pairHole(path:string, geometry:Geometry=GEOMETRY_DEFAULT, decode:DecodeSettings=DECODE_DEFAULT):PairHole {
  return {path,geometry,decode,placement:{scale:1,x:0,y:0,quarterTurns:0},autoExposure:true,exposureEV:0};
}
export function decodePair(value:unknown):PairDocument {
  const v=object(value);
  if(v.schemaVersion!==undefined&&v.schemaVersion!==1) throw new Error('Unsupported half-frame pair version');
  if(typeof v.folder!=='string') throw new Error('A half-frame pair needs its folder');
  const hole=(input:unknown):PairHole|null=>{
    if(input===null||input===undefined) return null;
    const h=object(input),p=object(h.placement);
    if(typeof h.path!=='string'||!h.path||isPairPath(h.path)) throw new Error('A pair hole must reference a photograph');
    const raw=object(h.geometry),c=raw.crop;
    const g=Array.isArray(c)&&c.length===4?{...raw,crop:{x:c[0],y:c[1],width:c[2],height:c[3]}}:raw;
    return {...h,path:h.path,geometry:{...raw,...decodeGeometry(g)},decode:{...object(h.decode),...decodeSidecar({decode:h.decode}).decode},
      ...(h.print?{print:{...object(h.print),brightnessStops:n(object(h.print).brightnessStops,0,-3,3),yFilterShift:n(object(h.print).yFilterShift,0,-1,1),mFilterShift:n(object(h.print).mFilterShift,0,-1,1),preflashExposure:n(object(h.print).preflashExposure,0,0,.03)}}:{}),
      ...(h.adjustments?{adjustments:{...object(h.adjustments),...decodeAdjustments(h.adjustments)}}:{}),
      printScope:h.printScope==='frame'?'frame':'film',exposureScope:h.exposureScope==='film'?'film':'frame',
      placement:{...p,scale:n(p.scale,1,1,4),x:n(p.x,0,-1,1),y:n(p.y,0,-1,1),quarterTurns:n(p.quarterTurns,0,-1000,1000)},
      autoExposure:h.autoExposure!==false,exposureEV:n(h.exposureEV,0,-32,32)};
  };
  return {...v,schemaVersion:1,folder:v.folder,left:hole(v.left),right:hole(v.right),spacingMM:n(v.spacingMM,1,.5,2),onStrip:v.onStrip===true,turned:v.turned===true};
}
/** Same Mac Codable geometry on disk; no WebGL-only object leaks into a recipe. */
export function encodePair(p:PairDocument) {
  const hole=(h:PairHole|null)=>h?{...h,geometry:{...h.geometry,...encodeGeometry(h.geometry)}}:null;
  return {...p,left:hole(p.left),right:hole(p.right)};
}
export function pairParams(p:FilmParams,info:PairInfo|null,doc?:PairDocument|null):FilmParams {
  const filmEdge={...p.filmEdge,pair:true,format:'135_half'};
  const q=resolveImprints({...p,filmEdge,autoExposure:false},info?.sources[0]?.metadata??null,4/3);
  const b=resolveImprints(q,info?.sources[1]?.metadata??null,4/3);
  const gap=p.filmEdge.active?1:doc?.spacingMM??1;
  const physical=clamp((36+gap)*filmFormatMM(p.filmSide,p.sideLengthMM,24/18)/24,4,200);
  return {...q,filmFormatMM:physical,pairSplit:.5,dateBack:{...q.dateBack,camera:'135_half',textB:b.dateBack.text,framing:'',frameScale:1}};
}
