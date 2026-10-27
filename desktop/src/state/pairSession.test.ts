// State/persistence tests use a stand-in transport; native pixels are tested separately.
import {beforeEach,it,expect,vi} from 'vitest';
import {decodePair} from '@shared/pairs';
import {newSidecar} from '@shared/sidecar';
import {featureGate,fullDelta} from '@shared/params';
const io=vi.hoisted(()=>({save:vi.fn(async (_path:string,_doc:unknown)=>{}),open:vi.fn(async()=>({session:'pair-new',width:4,height:4,kind:'pair',metadata:{orientation:1},params:{}}))}));
vi.mock('../platform',()=>({platform:()=>({pairSave:io.save,sidecarSave:async()=>'',log:()=>{}}),baseName:(p:string)=>p,dirName:(p:string)=>p}));
vi.mock('../host/client',()=>({HostCallError:class extends Error{},host:()=>({open:io.open,close:async()=>{},setParams:async()=>{},
  render:async()=>({width:4,height:4,data:new Uint8Array(64),tier:'live'}),thumbnail:async()=>{throw new Error('not needed');},
  transport:{request:async()=>({result:null})}})}));
import {sessionStore,updatePairHole,flushPairChanges,setPairSide,setGeometry,setDecode,retryPairSave,undo,redo,setPairFilm,setAdjustments,editingAdjustments,setEnlarger,editingPrint,setPairExposure,retainPairReadings,togglePairPlacing,previewPairPlacement,commitPairPlacement,endPairPlacing} from './session';
import type {PairInfo} from '@shared/protocol';
let pairTestClock=0;
beforeEach(async()=>{
  await flushPairChanges(false).catch(()=>{});vi.clearAllMocks();
  pairTestClock+=10000;vi.spyOn(performance,'now').mockReturnValue(pairTestClock);
  sessionStore.setState({selection:'C:/validation/p.spektrapair',pairDocument:decodePair({folder:'C:/photos',left:{path:'C:/photos/a.ARW'},right:{path:'C:/photos/b.ARW'}}),
    pairInfo:null,pairSide:'left',pairLayer:'film',pairPlacing:false,pairPlacementDraft:null,pairUpdating:false,pairSaveError:null,batchExporting:false,sidecar:newSidecar(),undo:[],redo:[],engineSession:null,
    hostState:{phase:'ready',hello:null as never},gate:featureGate(['overscan','date_imprint']),nativeSize:null});
});
it('holds pointer moves in a preview and saves a single undoable placement on release',async()=>{
  togglePairPlacing();const original=sessionStore.getState().pairDocument!.left!.placement;
  for(const x of [.1,.2,.4])previewPairPlacement('left',{...original,scale:2,x});
  expect(sessionStore.getState().pairDocument!.left!.placement).toEqual(original);
  expect(sessionStore.getState().undo).toHaveLength(0);expect(io.save).not.toHaveBeenCalled();expect(io.open).not.toHaveBeenCalled();
  commitPairPlacement();commitPairPlacement();await flushPairChanges(false);
  expect(sessionStore.getState().undo).toHaveLength(1);expect(io.save).toHaveBeenCalledTimes(1);
  expect(sessionStore.getState().pairDocument!.left!.placement.x).toBe(.4);
  undo();await flushPairChanges(false);expect(sessionStore.getState().pairDocument!.left!.placement).toEqual(original);
  redo();await flushPairChanges(false);expect(sessionStore.getState().pairDocument!.left!.placement.x).toBe(.4);
});
it('commits the previous hole before switching the preview to the other hole',async()=>{
  togglePairPlacing();const original=sessionStore.getState().pairDocument!.left!.placement;
  previewPairPlacement('left',{...original,x:.6});setPairSide('right');
  previewPairPlacement('right',{...original,x:-.3});endPairPlacing();await flushPairChanges(false);
  expect(sessionStore.getState().pairDocument!.left!.placement.x).toBe(.6);
  expect(sessionStore.getState().pairDocument!.right!.placement.x).toBe(-.3);
  expect(sessionStore.getState().undo).toHaveLength(2);expect(sessionStore.getState().pairPlacing).toBe(false);
});
it('flushes input begun before the export lock while refusing new pointer input',async()=>{
  togglePairPlacing();const original=sessionStore.getState().pairDocument!.left!.placement;
  previewPairPlacement('left',{...original,scale:2});sessionStore.setState({batchExporting:true});
  previewPairPlacement('left',{...original,scale:4});togglePairPlacing();undo();
  await flushPairChanges(false);
  expect(sessionStore.getState().pairDocument!.left!.placement.scale).toBe(2);
  expect(sessionStore.getState().undo).toHaveLength(1);
});
it('drops stale source input and no-op gestures without creating an undo or write',async()=>{
  togglePairPlacing();const h=sessionStore.getState().pairDocument!.left!;
  previewPairPlacement('left',h.placement);commitPairPlacement();expect(sessionStore.getState().undo).toHaveLength(0);
  previewPairPlacement('left',{...h.placement,x:.3});
  sessionStore.setState({pairDocument:{...sessionStore.getState().pairDocument!,left:{...h,path:'C:/photos/replaced.ARW'}}});
  await flushPairChanges(false);expect(sessionStore.getState().pairPlacementDraft).toBeNull();
  expect(io.save).not.toHaveBeenCalled();expect(sessionStore.getState().undo).toHaveLength(0);
});
it('saves the last edit atomically before leaving and never writes a source photo',async()=>{
  updatePairHole(h=>({...h,exposureEV:.5}));updatePairHole(h=>({...h,exposureEV:1}));
  expect(sessionStore.getState().pairUpdating).toBe(true);
  await flushPairChanges(false);
  expect(io.save).toHaveBeenCalledTimes(1);
  expect(io.save).toHaveBeenCalledWith('C:/validation/p.spektrapair',expect.objectContaining({left:expect.objectContaining({exposureEV:1})}));
  expect(sessionStore.getState().pairUpdating).toBe(false);
});
it('retains a failed save, rejects export flush and can retry the same recipe',async()=>{
  io.save.mockRejectedValueOnce(new Error('disk full'));
  updatePairHole(h=>({...h,exposureEV:2}));
  await expect(flushPairChanges(false)).rejects.toThrow('disk full');
  expect(sessionStore.getState().pairSaveError).toBe('disk full');
  await expect(flushPairChanges()).rejects.toThrow('disk full');
  retryPairSave();await flushPairChanges(false);
  expect(sessionStore.getState().pairSaveError).toBeNull();
  expect(io.save).toHaveBeenLastCalledWith('C:/validation/p.spektrapair',expect.objectContaining({left:expect.objectContaining({exposureEV:2})}));
});
it('changes the selected hole without changing either physical curve or rendering',()=>{
  const p=sessionStore.getState().sidecar.params;
  sessionStore.setState({sidecar:{...newSidecar(),params:{...p,filmEdge:{...p.filmEdge,pair:true},sceneLatitude:{...p.sceneLatitude,highlightKnee:3},sceneLatitudeOther:{...p.sceneLatitudeOther,highlightKnee:6}}}});
  const before=fullDelta(sessionStore.getState().sidecar.params);
  setPairSide('right');
  expect(sessionStore.getState().sidecar.params.sceneLatitude.highlightKnee).toBe(6);
  expect(fullDelta(sessionStore.getState().sidecar.params)).toEqual(before);
  expect(io.open).not.toHaveBeenCalled();
});
it('guards whole-piece crop/decode and pair edits during batch export',()=>{
  const before=sessionStore.getState();
  setGeometry(g=>({...g,quarterTurns:1}));setDecode(d=>({...d,temperature:3200}));
  expect(sessionStore.getState().sidecar).toBe(before.sidecar);
  sessionStore.setState({batchExporting:true});updatePairHole(h=>({...h,exposureEV:3}));setPairSide('right');undo();
  expect(sessionStore.getState().pairDocument).toBe(before.pairDocument);
  expect(sessionStore.getState().pairSide).toBe('left');
});
it('keeps a newer recipe busy while an older write completes, then saves in order',async()=>{
  let finish:()=>void=()=>{};
  io.save.mockImplementationOnce(()=>new Promise<void>(r=>{finish=r;}));
  updatePairHole(h=>({...h,exposureEV:.2}));const first=flushPairChanges(false);
  await vi.waitFor(()=>expect(io.save).toHaveBeenCalledTimes(1));
  updatePairHole(h=>({...h,exposureEV:.8}));const second=flushPairChanges(false);
  finish();await first;
  await second;
  expect(io.save.mock.calls.map(c=>(c[1] as {left:{exposureEV:number}}).left.exposureEV)).toEqual([.2,.8]);
  expect(sessionStore.getState().pairDocument?.left?.exposureEV).toBe(.8);
  expect(sessionStore.getState().pairUpdating).toBe(false);
});
it('edits a hole grade independently and film selection reads the film grade',async()=>{
  setPairSide('right');setAdjustments(a=>({...a,exposure:1}));
  expect(editingAdjustments(sessionStore.getState()).exposure).toBe(1);
  expect(sessionStore.getState().sidecar.adjustments.exposure).toBe(0);
  expect(sessionStore.getState().pairDocument?.left?.adjustments).toBeUndefined();
  setPairFilm();expect(editingAdjustments(sessionStore.getState()).exposure).toBe(0);
  await flushPairChanges(false);expect(io.open).not.toHaveBeenCalled();
});
it('enlarger + Film freezes the other hole, shifts the rebate and preserves offsets on film edits',async()=>{
  setPairSide('left');setEnlarger('brightnessStops',.5);
  expect(editingPrint(sessionStore.getState()).brightnessStops).toBe(.5);
  expect(sessionStore.getState().pairDocument?.right?.print?.brightnessStops).toBe(0);
  expect(sessionStore.getState().sidecar.params.printBrightnessStops).toBe(.5);
  setPairFilm();setEnlarger('brightnessStops',1);
  expect(sessionStore.getState().pairDocument?.left?.print?.brightnessStops).toBe(1);
  expect(sessionStore.getState().pairDocument?.right?.print?.brightnessStops).toBe(.5);
  await flushPairChanges(false);
});
it('frame exposure with + Film changes film print without changing the other hole exposure',async()=>{
  updatePairHole(h=>({...h,exposureScope:'film'}),false);setPairExposure(1);
  expect(sessionStore.getState().pairDocument?.left?.exposureEV).toBe(1);
  expect(sessionStore.getState().pairDocument?.right?.exposureEV).toBe(0);
  expect(sessionStore.getState().sidecar.params.printBrightnessStops).toBe(1);
  expect(sessionStore.getState().pairDocument?.right?.print?.brightnessStops).toBe(0);
  await flushPairChanges(false);
});
it('persists native readings without undo or a duplicate develop and retains pending edits',async()=>{
  const opened=sessionStore.getState().pairDocument!;
  const info:PairInfo={complete:true,can_export:true,turned:false,on_strip:false,rects:[],sources:[
    {path:opened.left!.path,present:true,metadata:{orientation:1},decode_error:'',exposure_ev:0,metered_ev:1.5,metered_for:'windows-pair-meter-v1:test'}]};
  retainPairReadings(info,opened);await flushPairChanges();
  expect(io.save).toHaveBeenLastCalledWith('C:/validation/p.spektrapair',expect.objectContaining({left:expect.objectContaining({meteredEV:1.5,meteredFor:'windows-pair-meter-v1:test'})}));
  expect(io.open).not.toHaveBeenCalled();expect(sessionStore.getState().undo).toHaveLength(0);
  // A real crop/move still owns its render when a meter result arrives late.
  updatePairHole(h=>({...h,placement:{...h.placement,x:.6}}));
  retainPairReadings({...info,sources:[{...info.sources[0]!,metered_ev:2}]},opened);
  await flushPairChanges();
  expect(io.save).toHaveBeenLastCalledWith('C:/validation/p.spektrapair',expect.objectContaining({left:expect.objectContaining({meteredEV:2,placement:expect.objectContaining({x:.6})})}));
  expect(io.open).toHaveBeenCalledTimes(1);
  expect(sessionStore.getState().undo).toHaveLength(1);
});
