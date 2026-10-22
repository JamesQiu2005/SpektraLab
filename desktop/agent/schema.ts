// User-facing edit schema, pinned Mac AgentSchema.swift (f1440bd1).
// Values outside the UI ranges are refused, never silently clamped.
import { newSidecar, type Sidecar } from '../src/shared/sidecar';
import { EFFECT_RANGES, EXPOSURE_METHODS, FILM_FRAMES, FILM_EDGE_FORMATS } from '../src/shared/params';
import { WB_MODES } from '../src/shared/whiteBalance';
import type { StockCatalog } from '../src/shared/stocks';
export class Refused extends Error { readonly refused = true; }
export type Document = Pick<Sidecar, 'params'|'adjustments'|'geometry'|'decode'>;
export interface Field { path: string; type: string; min?: number; max?: number; enum?: readonly string[]; readOnly?: string; doc: string }
export function document(s: Sidecar): Document { return structuredClone({params:s.params,adjustments:s.adjustments,geometry:s.geometry,decode:s.decode}); }
export function fields(catalog: StockCatalog): Field[] {
  const out = new Map<string,Field>();
  const add=(path:string,type:string,range?:readonly number[],choices?:readonly string[])=>out.set(path,{path,type,doc:path.replaceAll('.',' / '),...(range?{min:range[0],max:range[1]}:{}),...(choices?{enum:choices}:{})});
  const numbers=(prefix:string,entries:Record<string,readonly number[]>)=>Object.entries(entries).forEach(([key,r])=>add(`${prefix}.${key}`,'number',r));
  const bools=(prefix:string,keys:string)=>keys.split(' ').forEach(k=>add(`${prefix}.${k}`,'boolean'));
  add('params.filmStock','string',undefined,catalog.films.map(s=>s.id));add('params.printStock','string',undefined,catalog.papers.map(s=>s.id));
  numbers('params',{exposureCompensationEV:[-4,4],sideLengthMM:[1,500],printBrightnessStops:[-3,3],yFilterShift:[-1,1],mFilterShift:[-1,1],preflashExposure:[0,.03]});
  bools('params','autoExposure grainActive halationActive glareActive scanFilm digitalIntermediate extendedDynamicRange printEffects');
  add('params.autoExposureMethod','string',undefined,EXPOSURE_METHODS);add('params.filmFrame','string',undefined,[...FILM_FRAMES.map(f=>f.id),'Custom']);add('params.filmSide','string',undefined,['short','long']);
  numbers('params.effects',EFFECT_RANGES);bools('params.effects','grainLayered antihalationRemoved couplersActive');
  bools('params.filmEdge','active');add('params.filmEdge.format','string',undefined,FILM_EDGE_FORMATS);
  for(const [key,values] of Object.entries({view:['strip','carrier'],gate:['auto','square','rounded','eared','shouldered','kicked'],holes:['white','black']}))add(`params.filmEdge.${key}`,'string',undefined,values);
  for(const key of ['cameraSeed','frameSeed'])add(`params.filmEdge.${key}`,'integer',[0,2147483647]);
  add('params.filmEdge.frameNumber','integer',[0,99]);numbers('params.filmEdge',{fog:[0,4],leaks:[0,4]});
  bools('params.dateBack','active withData');
  for(const [key,values] of Object.entries({face:['lcd','dots','data'],order:['us','japan'],placement:['frame','rebate'],corner:['tl','tr','bl','br']}))add(`params.dateBack.${key}`,'string',undefined,values);
  numbers('params.dateBack',{insetXMM:[0,30],insetYMM:[0,30],size:[.4,3],brightnessEV:[-2,8]});
  bools('adjustments','enabled');numbers('adjustments',{temperature:[-100,100],tint:[-100,100],exposure:[-3,3],contrast:[-50,50],brightness:[-50,50],saturation:[-100,100],highlights:[-100,100],shadows:[-100,100],blackPoint:[0,50],whitePoint:[0,50]});
  numbers('adjustments.vignette',{amount:[-100,100],midpoint:[0,100]});
  for(const c of ['rgb','luma','red','green','blue'])add(`adjustments.curves.${c}.points`,'points');
  for(const z of ['master','shadows','midtones','highlights'])numbers(`adjustments.colorBalance.${z}`,{hue:[0,360],saturation:[0,1],luminance:[-1,1]});
  numbers('geometry.crop',{x:[0,1],y:[0,1],width:[0,1],height:[0,1]});numbers('geometry',{angle:[-45,45]});add('geometry.quarterTurns','integer',[0,3]);bools('geometry','flipH flipV');
  add('geometry.aspect','string',undefined,['free','original','originalPortrait','square','r3x2','r2x3','r4x3','r3x4','r16x9','r9x16','r5x4','r4x5','r7x5','r5x7']);
  add('decode.whiteBalance','string',undefined,WB_MODES);numbers('decode',{temperature:[2000,12000],tint:[-150,150]});bools('decode','lensCorrection');
  function walk(v:unknown,path:string) {
    if (out.has(path))return;
    if(v&&typeof v==='object'&&!Array.isArray(v))for(const[k,x]of Object.entries(v))walk(x,path?`${path}.${k}`:k);
    else out.set(path,{path,type:typeof v,doc:path,readOnly:path.startsWith('params.sceneLatitude')?'Use place_scene: a solved placement must pass the engine Fit.':path.startsWith('params.contrastMask')?'Tone Mask is withdrawn in this version.':'Derived by the application.'});
  }
  walk(document(newSidecar()),'');
  for(const key of ['geometry.lockedRatio','geometry.intendedSize'])if(!out.has(key))out.set(key,{path:key,type:'derived',doc:key,readOnly:'Derived by crop and film edge.'});
  return [...out.values()];
}
export function validate(patch:unknown,catalog:StockCatalog):string[] {
  const map=new Map(fields(catalog).map(f=>[f.path,f])),leaves:string[]=[];
  const branches=new Set([...map.keys()].flatMap(p=>p.split('.').slice(0,-1).map((_,i)=>p.split('.').slice(0,i+1).join('.'))));
  const object=(x:unknown):x is Record<string,unknown>=>!!x&&typeof x==='object'&&!Array.isArray(x);
  if(!object(patch))throw new Refused('The patch must be an object.');
  function walk(v:unknown,path:string) {
    const f=map.get(path);if(!f){if(!branches.has(path)||!object(v))throw new Refused(`${path} is not an editable field or object.`);for(const[k,x]of Object.entries(v))walk(x,`${path}.${k}`);return;}
    if(f.readOnly)throw new Refused(`${path} is read-only: ${f.readOnly}`);
    if(f.type==='points'){
      if(!Array.isArray(v)||v.length<2||v.length>256||v.some(p=>!Array.isArray(p)||p.length!==2||p.some(x=>typeof x!=='number'||!Number.isFinite(x)||x<0||x>1))||v[0][0]!==0||v.at(-1)[0]!==1||v.some((p,i)=>i>0&&p[0]<=v[i-1][0]))throw new Refused(`${path} needs 2–256 ascending [x,y] points within 0..1, starting 0 ending 1.`);
    }else if(f.type==='number'||f.type==='integer'){
      if(typeof v!=='number'||!Number.isFinite(v)||(f.type==='integer'&&!Number.isInteger(v))||v<f.min!||v>f.max!)throw new Refused(`${path} must be ${f.type} in ${f.min}..${f.max}.`);
    }else if(typeof v!==f.type||(f.enum&&!f.enum.includes(v as string)))throw new Refused(`${path} must be ${f.enum?.join(', ')??f.type}.`);
    leaves.push(path);
  }
  for(const[k,v]of Object.entries(patch))walk(v,k);return leaves;
}
export function merge<T>(original:T,patch:unknown):T {
  if(!patch||typeof patch!=='object'||Array.isArray(patch))return structuredClone(patch) as T;
  const out=structuredClone(original) as Record<string,unknown>;
  for(const[k,v]of Object.entries(patch)) { if(k==='__proto__'||k==='prototype'||k==='constructor')throw new Refused('Invalid object key');out[k]=v&&typeof v==='object'&&!Array.isArray(v)?merge(out[k]??{},v):structuredClone(v); }
  return out as T;
}
