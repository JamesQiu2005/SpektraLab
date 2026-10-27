// Executes the actual frontend compositor/exporter against the native host.
// Opt-in fixture is a public synthetic pair; no mocked rendering or file writer.
import {it,expect,vi} from 'vitest';
import {spawn} from 'node:child_process';
import {existsSync,mkdtempSync,readFileSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {FrameDecoder,encodeFrame} from '@shared/framing';
import {decodePair,encodePair,pairParams} from '@shared/pairs';
import {ADJUSTMENTS_DEFAULT} from '@shared/adjustments';
import {FILM_PARAMS_DEFAULT,fullDelta} from '@shared/params';
import {GEOMETRY_DEFAULT} from '@shared/geometry';
import type {PairInfo} from '@shared/protocol';
import {StockCatalog} from '@shared/stocks';
import {DEFAULT_RECIPES,type ExportRecipe} from './recipes';
const io=vi.hoisted(()=>({request:undefined as undefined|((m:string,p:Record<string,unknown>,o?:{payload?:Uint8Array})=>Promise<{result:Record<string,unknown>;payload:Uint8Array}>)}));
vi.mock('../host/client',()=>({host:()=>({transport:{request:(m:string,p:Record<string,unknown>,o?:{payload?:Uint8Array})=>io.request!(m,p,o)}})}));
vi.mock('../platform',async()=>{
  const path=await import('node:path'),fs=await import('node:fs/promises');
  return {baseName:path.basename,dirName:path.dirname,joinPath:path.join,platform:()=>({ensureDir:async(p:string)=>{await fs.mkdir(p,{recursive:true});},pathExists:async(p:string)=>{try{await fs.access(p);return true;}catch{return false;}},log:()=>{}})};
});
import {exportFrame} from './exporter';
const dir=process.env.SPEKTRALAB_HOST_DIR,fixture=process.env.SPEKTRALAB_TEST_PAIR;
const exe=dir?join(dir,process.platform==='win32'?'spektralab-host.exe':'spektralab-host'):'';
function tiff16(path:string) {
  const b=readFileSync(path);expect(b.toString('ascii',0,2)).toBe('II');
  const ifd=b.readUInt32LE(4),count=b.readUInt16LE(ifd),tags=new Map<number,number[]>();
  for(let i=0;i<count;i++){
    const e=ifd+2+i*12,tag=b.readUInt16LE(e),type=b.readUInt16LE(e+2),n=b.readUInt32LE(e+4),size=type===3?2:4;
    if(tag===34675){expect(n).toBeGreaterThan(100);continue;}
    if(![256,257,258,259,273,277,279].includes(tag))continue;
    const at=n*size<=4?e+8:b.readUInt32LE(e+8);
    tags.set(tag,Array.from({length:n},(_,k)=>type===3?b.readUInt16LE(at+k*size):b.readUInt32LE(at+k*size)));
  }
  expect(tags.get(258)).toEqual([16,16,16]);expect(tags.get(259)).toEqual([1]);
  const bytes=Buffer.concat(tags.get(273)!.map((offset,i)=>b.subarray(offset,offset+tags.get(279)![i]!)));
  return {width:tags.get(256)![0]!,height:tags.get(257)![0]!,bytes};
}
it.skipIf(!fixture||!existsSync(exe))('exports separately printed/graded holes through real native JPEG, PNG and TIFF16',async()=>{
  const child=spawn(exe,['--resources',join(dir!,'engine')],{stdio:['pipe','pipe','inherit']});
  const decoder=new FrameDecoder(),pending=new Map<number,(v:{result:Record<string,unknown>;payload:Uint8Array})=>void>();
  let id=1;
  child.stdout.on('data',(b:Buffer)=>{for(const f of decoder.push(new Uint8Array(b))){const h=f.header as {id?:number;ok?:boolean;error?:unknown;result:Record<string,unknown>};if(h.id){expect(h.ok,JSON.stringify(h.error)).toBe(true);pending.get(h.id)?.({result:h.result,payload:f.payload});pending.delete(h.id);}}});
  io.request=(method,params,opts)=>new Promise(resolve=>{const rid=id++;pending.set(rid,resolve);child.stdin.write(encodeFrame({id:rid,method,params},opts?.payload));});
  try{
    const folder=mkdtempSync(join(tmpdir(),'spk-pair-export-')),doc=decodePair(JSON.parse(readFileSync(fixture!,'utf8')));
    doc.right!.adjustments={...ADJUSTMENTS_DEFAULT,exposure:1};
    const source=join(folder,'layered.spektrapair');writeFileSync(source,JSON.stringify(encodePair(doc)));
    const params=pairParams({...FILM_PARAMS_DEFAULT,autoExposure:false,filmFrame:'Custom',filmSide:'long',sideLengthMM:24,grainActive:false,glareActive:false,halationActive:false,filmEdge:{...FILM_PARAMS_DEFAULT.filmEdge,active:doc.onStrip}},null,doc);
    const opened=await io.request('open',{path:source,params:fullDelta(params),pair_presentation:'client'});
    const session=String(opened.result.session),pair=opened.result.pair as PairInfo,native={width:Number(opened.result.width),height:Number(opened.result.height)};
    const before=await io.request('get_params',{session});
    const base=await io.request('render',{session,tier:'full',format:'rgba16',display:'srgb'});
    const image=base.result.image as {width:number;height:number};
    const layout=doc.onStrip?(await io.request('overscan_geometry',{session})).result as {gates:number[][]}:null;
    const own=await io.request('render_layer',{session,tier:'full',format:'rgba16',display:'srgb',delta:{print_exposure:Math.pow(2,-.5)}});
    const expectedLeft=new Uint16Array(own.payload.slice().buffer),basePixels=new Uint16Array(base.payload.slice().buffer);
    let proof='';
    for(const format of ['jpeg','png','tiff'] as const){
      const recipe:ExportRecipe={...DEFAULT_RECIPES[0]!,format,bitDepth:16,colorSpace:'sRGB',folder:{kind:'fixed',path:folder},subfolder:'',longEdge:0};
      const outcome=await exportFrame(recipe,{path:source,session,params,adjustments:ADJUSTMENTS_DEFAULT,geometry:GEOMETRY_DEFAULT,native,pairDocument:doc,pairInfo:pair,pairComplete:true},new StockCatalog([]),['write_image','render_layer']);
      expect(outcome.kind,JSON.stringify(outcome)).toBe('written');
      if(outcome.kind==='written'&&format==='tiff')proof=outcome.path;
    }
    const file=tiff16(proof);expect([file.width,file.height]).toEqual([image.width,image.height]);
    for(const [side,r] of pair.rects.entries()){
      const q=layout?.gates[side];
      const x=Math.floor((q?(q[0]!+q[2]!+q[4]!+q[6]!)/4:r[0]!+r[2]!/2)*image.width),y=Math.floor((q?(q[1]!+q[3]!+q[5]!+q[7]!)/4:r[1]!+r[3]!/2)*image.height),pixel=y*image.width+x;
      for(let c=0;c<3;c++){
        const actual=file.bytes.readUInt16LE((pixel*3+c)*2);
        const expected=side===0?expectedLeft[pixel*4+c]!:Math.round(Math.min(1,Math.pow(Math.pow(basePixels[pixel*4+c]!/65535,2.2)*2,1/2.2))*65535);
        expect(Math.abs(actual-expected)).toBeLessThanOrEqual(2);
      }
    }
    expect((await io.request('get_params',{session})).result).toEqual(before.result);
    console.log(JSON.stringify({destination:folder,tiff:proof,width:file.width,height:file.height,note:'native prints + actual frontend 16-bit grade/composition + native encoders; not GUI click acceptance'}));
  }finally{child.stdin.end();}
},600_000);
