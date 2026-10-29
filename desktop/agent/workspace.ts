import { readFile, mkdtemp, rm, stat } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { FileService, NativeHost, absolute, here } from './io';
import { setFiles } from './platform';
import { setHost } from './host';
import type { ToolArgs } from './tools';
import { Refused, document, fields, merge, validate } from './schema';
import { StockCatalog } from '../src/shared/stocks';
import { newSidecar, decodeSidecar, encodeSidecar, type Sidecar } from '../src/shared/sidecar';
import { normalizeStockPair, featureGate, fullDelta, filmFrameNamed, type FeatureGate } from '../src/shared/params';
import { fitted } from '../src/shared/geometry';
import { gateFramed, edgeEffective } from '../src/shared/filmEdge';
import { decodeWire, isRawPath, WB_KELVIN } from '../src/shared/whiteBalance';
import { decodePair, isPairPath, pairFitRegion, type HalfFramePair } from '../src/shared/pair';
import { latitudeRequest, applyLatitudeFit, type LatitudeReply } from '../src/shared/latitude';
import { captureExportFrames, exportFrame, type FrameToExport } from '../src/export/exporter';
import { decodeRecipes, type ExportRecipe } from '../src/export/recipes';
import type { HelloResult, OpenResult, ProbeResult } from '../src/shared/protocol';
import { RENDER_PREFERENCES_DEFAULT, renderPreferences, type RenderPreferences } from '../src/shared/renderPreferences';

export interface Result { body:unknown; preview?:string; temporary?:string }
export class Workspace {
  files=new FileService(); engine:NativeHost|null=null; catalog:StockCatalog|null=null;
  hello!:HelloResult; gate!:FeatureGate; path=''; sid=''; sidecar!:Sidecar; pair:HalfFramePair|null=null;
  info!:ProbeResult; opened!:OpenResult; frame!:FrameToExport; decodeKey=''; sourceStamp='';
  rendering:RenderPreferences={...RENDER_PREFERENCES_DEFAULT};
  constructor(){setFiles(this.files)}
  async status(){return this.files.call<Record<string,unknown>>('status')}
  async start(){
    if(!this.catalog){const file=process.env.SPEKTRALAB_AGENT_CATALOG??join(here,'StockCatalog.json');this.catalog=new StockCatalog(JSON.parse(await readFile(file,'utf8')).stocks)}
    if(!this.engine){this.engine=new NativeHost();setHost(this.engine);this.hello=await this.engine.result<HelloResult>('hello');this.gate=featureGate(this.hello.capabilities?.backend?.unsupported_features,this.rendering.diBlueCompensation,this.hello.view_options?.includes('no_film'))}
  }
  async load(path:string){
    await this.start();path=absolute(path);
    this.sidecar=decodeSidecar(await this.files.call('sidecar_load',{path}));
    this.pair=isPairPath(path)?decodePair(JSON.parse(await readFile(path,'utf8'))):null;
    if(isPairPath(path)&&!this.pair)throw new Refused('Invalid half-frame pair document');
    this.info=await this.engine!.result<ProbeResult>('probe',{path});
    const md=await stat(path),stamp=JSON.stringify([md.size,md.mtimeMs]);
    if((this.path!==path||this.sourceStamp!==stamp)&&this.sid){await this.engine!.result('close',{session:this.sid});this.sid=''}
    this.sourceStamp=stamp;
    this.path=path; // Read-only inspection also works for a partially filled pair.
  }
  async prepare(){
    const [item]=await captureExportFrames([this.path],{path:this.path,sidecar:this.sidecar,session:this.sid||undefined,
      native:{width:this.info.width,height:this.info.height},metadata:this.info.metadata,pair:this.pair,pairInfo:this.info.pair_info},this.catalog!,this.gate,this.rendering.recalculateEffectsAfterCrop);
    if(!item||'error'in item)throw new Refused(item&&'error'in item?item.error:'Cannot prepare frame');
    this.frame=item.frame;this.sidecar.params=structuredClone(this.frame.params);
  }
  async develop(filmOnly=false){
    const noFilm=this.sidecar.noFilm&&!filmOnly;
    if(noFilm&&(this.pair||isPairPath(this.path)||this.sidecar.params.filmEdge.pair))throw new Refused('Developing without film simulation is unavailable for half-frame pairs. Enable film simulation.');
    if(noFilm&&!this.gate.noFilm)throw new Refused('This engine cannot develop without film simulation. Update the engine or select a film stock.');
    await this.prepare();const params=fullDelta(this.frame.params,this.gate,this.catalog!);
    const decode=decodeWire(this.sidecar.decode,isRawPath(this.path));const key=JSON.stringify(decode);
    if(!this.sid){this.opened=await this.engine!.result<OpenResult>(this.pair?'open_pair':'open',{path:this.path,params,pair:this.frame.pair,decode:decode??undefined});this.sid=this.opened.session}
    else if(this.pair)this.opened=await this.engine!.result<OpenResult>('update_pair',{session:this.sid,params,pair:this.frame.pair});
    else if(key!==this.decodeKey)this.opened=await this.engine!.result<OpenResult>('redecode',{session:this.sid,decode:decode??undefined});
    this.decodeKey=key;this.frame.session=this.sid;
    // DI prepares the film negative even when ordinary output bypasses it.
    await this.engine!.result('render_view',{session:this.sid,params,adjustments:this.frame.adjustments,...(noFilm?{no_film:true}:{}),
      geometry:filmOnly?this.frame.filmGeometry:this.frame.geometry,
      source_geometry:filmOnly?this.frame.filmSourceGeometry:this.frame.sourceGeometry,tier:'preview',display:'srgb',long_edge:64,generation:1});
  }
  async save(){await this.files.call('sidecar_save',{path:this.path,value:encodeSidecar(this.sidecar)})}
  async edit(patch:unknown){
    const leaves=validate(patch,this.catalog!);const has=(prefix:string)=>leaves.some(k=>k===prefix||k.startsWith(prefix+'.'));
    const want=merge(document(this.sidecar),patch),p=want.params;
    if(this.catalog!.isPositive(p.filmStock)&&(has('params.printStock')||(has('params.scanFilm')&&!p.scanFilm)))throw new Refused('Slide films are scanned and take no paper.');
    if(has('params.printStock')&&!this.catalog!.canPrint(p.filmStock,p.printStock))throw new Refused('Film and paper emulsion types must match.');
    for(const[active,supported,label]of [[p.filmEdge.active,this.gate.overscan,'Film Edge'],[p.dateBack.active,this.gate.dateImprint,'Date Back'],[p.digitalIntermediate,this.gate.digitalIntermediate,'Digital Intermediate']] as const)
      if(active&&!supported)throw new Refused(`${label} is unavailable in this engine.`);
    if(has('decode')&&!isRawPath(this.path))throw new Refused('Decode edits need a RAW photograph; pair-hole decode edits use the app.');
    if(has('geometry.crop')&&(want.geometry.crop.width<=.01||want.geometry.crop.height<=.01))throw new Refused('Crop must exceed1% on both sides.');
    if(has('params.filmStock')){p.scanFilm=this.catalog!.isPositive(p.filmStock);if(!has('params.printStock'))p.printStock=this.catalog!.stock(p.filmStock)?.targetPrint??p.printStock}
    if(has('params.filmFrame')||has('params.filmSide')){const f=filmFrameNamed(p.filmFrame);if(f.id!=='Custom')p.sideLengthMM=p.filmSide==='short'?f.short:f.long}
    if(has('params.sideLengthMM'))p.filmFrame='Custom';
    if((has('decode.temperature')||has('decode.tint'))&&!has('decode.whiteBalance'))want.decode.whiteBalance='Custom';
    else if(has('decode.whiteBalance')&&!has('decode.temperature')){const k=WB_KELVIN[want.decode.whiteBalance as keyof typeof WB_KELVIN];if(k)want.decode.temperature=k}
    want.params=normalizeStockPair(p,this.catalog!);
    if(has('geometry')){if(has('geometry.crop'))want.geometry.intendedSize={width:want.geometry.crop.width,height:want.geometry.crop.height};want.geometry=fitted(want.geometry,this.info)}
    if(edgeEffective(want.params.filmEdge,this.gate))want.geometry=gateFramed(want.geometry,want.params.filmEdge,this.info);
    // Sidecar is saved only after the real decoder/pipeline accepts the edit.
    this.sidecar={...this.sidecar,...want,noFilm:has('params.filmStock')?false:this.sidecar.noFilm,state:'stale'};await this.develop();await this.save();return {written:leaves,edit:document(this.sidecar)};
  }
  async preview(output?:string,longEdge=1024):Promise<Result>{
    await this.develop();const temporary=output?undefined:await mkdtemp(join(tmpdir(),'spektralab-agent-'));
    const path=output?absolute(output):join(temporary!,'preview.jpg');
    if(resolve(path).toLowerCase()===resolve(this.path).toLowerCase())throw new Refused('The source photograph cannot be overwritten.');
    await this.engine!.result('export_frame',{session:this.sid,source_path:this.path,pair:this.frame.pair,params:fullDelta(this.frame.params,this.gate,this.catalog!),
      adjustments:this.frame.adjustments,...(this.frame.noFilm?{no_film:true}:{}),geometry:this.frame.geometry,source_geometry:this.frame.sourceGeometry,
      path,format:'jpeg',quality:92,color_space:'srgb',long_edge:longEdge,overwrite:false});
    return {body:{preview:path},preview:path,temporary};
  }
  async call(name:string,args:ToolArgs):Promise<Result>{
    await this.files.call('begin');
    try{
      this.rendering=renderPreferences(await this.files.call('rendering'));
      await this.start();
      this.gate=featureGate(this.hello.capabilities?.backend?.unsupported_features,this.rendering.diBlueCompensation,this.hello.view_options?.includes('no_film'));
      if(name==='get_schema')return{body:{version:1,sections:['params','adjustments','geometry','decode'],fields:fields(this.catalog!)}};
      if(name==='list_stocks')return{body:{films:this.catalog!.films,papers:this.catalog!.papers}};
      if(name==='list_recipes')return{body:{recipes:decodeRecipes(await this.files.call('recipes'))}};
      if(name==='edit_image')validate(args.patch,this.catalog!); // Refuse malformed edits before decode.
      await this.load(args.path!);
      let body:unknown;
      if(name==='describe_image')return{body:{path:this.path,...this.info,state:this.sidecar.state,film:this.sidecar.params.filmStock,paper:this.sidecar.params.scanFilm?null:this.sidecar.params.printStock}};
      if(name==='get_edit')return{body:document(this.sidecar)};
      if(name==='edit_image')body=await this.edit(args.patch);
      else if(name==='reset_edit'){const defaults=structuredClone(newSidecar());this.sidecar={...this.sidecar,params:defaults.params,adjustments:defaults.adjustments,geometry:defaults.geometry,placementNeedsFit:false,state:'unprocessed'};await this.develop();await this.save();body={edit:document(this.sidecar)}}
      else if(name==='process_image'){await this.develop();const solved=await this.engine!.result<{solved_params?:{exposure_compensation_ev?:number}}>('solve',{session:this.sid,target:'both'});this.sidecar.params.yFilterShift=0;this.sidecar.params.mFilterShift=0;this.sidecar.state='processed';if(typeof solved.solved_params?.exposure_compensation_ev==='number')this.sidecar.solvedEV=solved.solved_params.exposure_compensation_ev;await this.develop();await this.save();body={info:this.info,state:this.sidecar.state}}
      else if(name==='measure_latitude'||name==='place_scene'){
        await this.develop();const settings=structuredClone(this.sidecar.params.sceneLatitude);
        if(name==='place_scene'){settings.highlightPullBack=args.highlight!;settings.shadowPullBack=args.shadow!}
        const request={...latitudeRequest(settings),...(this.pair?{region:pairFitRegion(this.pair,this.sidecar.params.placementIsRight)}:{})};
        const result:LatitudeReply=await this.engine!.result<LatitudeReply>('scene_latitude',{session:this.sid,request});
        if(name==='measure_latitude')return{body:result};
        const placed=applyLatitudeFit(settings,result.fit);if(!placed)throw new Refused('Scene Placement fit refused: '+JSON.stringify(result.fit.issues));
        this.sidecar.params.sceneLatitude=placed;this.sidecar.placementNeedsFit=false;await this.develop();await this.save();body=result;
      }else if(name==='preview_image')return await this.preview(args.output,args.long_edge??1024);
      else if(name==='export_image'){
        const recipes=decodeRecipes(await this.files.call('recipes'));
        const selected=args.recipe?recipes.find(r=>r.name===args.recipe):recipes[0];if(!selected)throw new Refused('No export recipe with that name');
        await this.develop(selected.format==='di');
        const recipe:ExportRecipe=structuredClone(selected);if(args.folder){recipe.folder={kind:'fixed',path:absolute(args.folder)};recipe.subfolder=''}
        const written=await exportFrame(recipe,this.frame,this.catalog!,this.hello.methods,{tiffOptions:this.hello.tiff_options});
        if(written.kind==='failed')throw new Error(written.message);return{body:{files:written.kind==='written'?[written.path]:[],outcome:written}};
      }else throw new Refused('Unknown tool: '+name);
      if(args.preview!==false){const p=await this.preview();return{...p,body}}
      return{body};
    }finally{await this.files.call('end')}
  }
  async stop(){if(this.engine){try{await this.engine.result('shutdown')}catch{ /* The child may already have exited. */ }this.engine.stop()}this.files.stop()}
}
export async function removeTemporary(result:Result){if(result.temporary)await rm(result.temporary,{recursive:true,force:true})}
