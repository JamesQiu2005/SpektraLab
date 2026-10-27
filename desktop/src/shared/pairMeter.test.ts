import {it,expect} from 'vitest';
import {decodePair} from './pairs';
import type {PairInfo} from './protocol';
import {mergePairMeter} from './pairMeter';
const doc=()=>decodePair({folder:'C:/photos',left:{path:'C:/photos/a.ARW'},right:{path:'C:/photos/b.ARW'}});
const info=():PairInfo=>({complete:true,can_export:true,turned:false,on_strip:false,rects:[],sources:[
  {path:'C:/photos/a.ARW',present:true,metadata:{orientation:1},decode_error:'',exposure_ev:0,metered_ev:1.25,metered_for:'windows-pair-meter-v1:opaque'},
  {path:'C:/photos/b.ARW',present:true,metadata:{orientation:1},decode_error:'',exposure_ev:0,metered_ev:-.5,metered_for:'windows-pair-meter-v1:other'}]});
it('merges readings as metadata while preserving newer placement/print edits',()=>{
  const opened=doc(),live={...opened,left:{...opened.left!,placement:{...opened.left!.placement,x:.8},exposureEV:1,print:{brightnessStops:.5,yFilterShift:0,mFilterShift:0,preflashExposure:0}}};
  const merged=mergePairMeter(live,opened,info());
  expect(merged.left).toMatchObject({meteredEV:1.25,meteredFor:'windows-pair-meter-v1:opaque',exposureEV:1});
  expect(merged.left?.placement.x).toBe(.8);expect(merged.left?.print?.brightnessStops).toBe(.5);
  expect(merged.right?.meteredEV).toBe(-.5);expect(opened.left?.meteredEV).toBeUndefined();
  expect(mergePairMeter(merged,opened,info())).toBe(merged);
});
it('drops a late reading for a source, decode, owner crop or intent changed during open',()=>{
  const opened=doc();
  for(const patch of [{path:'C:/other.ARW'},{decode:{...opened.left!.decode,temperature:3200}},
    {geometry:{...opened.left!.geometry,crop:{x:.1,y:0,width:.9,height:1}}},{meterMethod:'protect_highlights'},{autoExposure:false}]) {
    const live={...opened,left:{...opened.left!,...patch}};
    expect(mergePairMeter(live,opened,info()).left?.meteredEV).toBeUndefined();
  }
});
it('rejects absent, mismatched, foreign and nonfinite reading metadata',()=>{
  const opened=doc();
  for(const patch of [{present:false},{path:'C:/other.ARW'},{metered_for:'foreign'},{metered_ev:Infinity},{metered_ev:1e100}]) {
    const r=info();Object.assign(r.sources[0]!,patch);
    expect(mergePairMeter(opened,opened,r).left?.meteredEV).toBeUndefined();
  }
});
