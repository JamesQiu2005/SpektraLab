import { describe,it,expect,vi } from 'vitest';
import { document, fields, merge, Refused, validate } from './schema';
import { newSidecar } from '../src/shared/sidecar';
import { StockCatalog } from '../src/shared/stocks';
import { checkTool,mcp,tools } from './tools';
import { parse } from './cli';
import { renderPreferences, RENDER_PREFERENCES_DEFAULT } from '../src/shared/renderPreferences';
const catalog=new StockCatalog([{id:'film',name:'Film',stage:'filming',use:'still',hasPreviewLUT:false},{id:'paper',name:'Paper',stage:'printing',use:'still',hasPreviewLUT:false}]);
describe('Agent edit contract',()=>{
  it('lists every stored leaf, including explicitly read-only derived fields',()=>{
    const paths=new Set(fields(catalog).map(f=>f.path));
    function walk(v:unknown,p:string){if(paths.has(p))return;if(v&&typeof v==='object'&&!Array.isArray(v)){for(const[k,x]of Object.entries(v))walk(x,p?`${p}.${k}`:k)}else throw new Error('Missing schema: '+p)}
    walk(document(newSidecar()),'');
    expect(fields(catalog).find(f=>f.path==='params.sceneLatitude.active')?.readOnly).toContain('Fit');
    expect(fields(catalog).find(f=>f.path==='params.contrastMask.active')?.readOnly).toContain('withdrawn');
  });
  it('validates the entire merge patch before mutation, preserving unknown stored sidecar data',()=>{
    const original=document(newSidecar()),before=structuredClone(original);
    const patch={params:{filmStock:'film',effects:{couplers:1.5}},adjustments:{exposure:.3}};
    expect(validate(patch,catalog)).toEqual(['params.filmStock','params.effects.couplers','adjustments.exposure']);
    const merged=merge(original,patch);expect(merged.adjustments.exposure).toBe(.3);expect(merged.params.grainActive).toBe(original.params.grainActive);expect(original).toEqual(before);
    for(const bad of [{params:{unknown:true}},{params:{effects:{couplers:1.6}}},{params:{printStock:'film'}},{params:{filmFormatMM:36}},{params:{sceneLatitude:{active:true}}},{geometry:null},{decode:{temperature:50000}},{adjustments:{exposure:Infinity}},JSON.parse('{"params":{"__proto__":{}}}')])expect(()=>validate(bad,catalog)).toThrow(Refused);
  });
  it('rejects malformed curves and accepts UI boundary values, never clamps',()=>{
    expect(()=>validate({adjustments:{curves:{rgb:{points:[[0,0],[.5,.8],[1,1]]}}}},catalog)).not.toThrow();
    for(const points of [[[0,0],[0,1],[1,1]],[[.1,0],[1,1]],[[0,0],[1,1.1]],[[0,0],[.5,.4],[.4,.5],[1,1]]])expect(()=>validate({adjustments:{curves:{rgb:{points}}}},catalog)).toThrow();
    expect(()=>validate({params:{filmEdge:{cameraSeed:2147483647,frameNumber:99,gate:'kicked',fog:4},dateBack:{face:'dots',placement:'rebate',size:.4,brightnessEV:-2}}},catalog)).not.toThrow();
    expect(()=>validate({adjustments:{curves:{rgb:{points:Array.from({length:257},(_,i)=>[i/256,i/256])}}}},catalog)).toThrow('2–256');
  });
  it('shares pixel-affecting GUI preferences and refuses malformed saved settings',()=>{
    expect(renderPreferences(RENDER_PREFERENCES_DEFAULT)).toEqual({recalculateEffectsAfterCrop:false,diBlueCompensation:false});
    const value={recalculateEffectsAfterCrop:true,diBlueCompensation:true};expect(renderPreferences(value)).toEqual(value);expect(renderPreferences(value)).not.toBe(value);
    for(const invalid of [null,{}, {diBlueCompensation:false},{...value,recalculateEffectsAfterCrop:1}])expect(()=>renderPreferences(invalid)).toThrow();
  });
});
describe('User CLI/MCP shared tools',()=>{
  it('parses the documented CLI into the same strict tool arguments',async()=>{
    expect(await parse(['edit','photo.ARW','--patch','-','--preview','preview.jpg'],async()=>'{"adjustments":{"exposure":0.2}}')).toMatchObject({name:'edit_image',args:{patch:{adjustments:{exposure:.2}},preview:true}});
    expect(await parse(['process','photo.ARW'])).toMatchObject({name:'process_image',args:{preview:false}});
    expect(await parse(['place','photo.ARW','--highlight','1','--shadow','0'])).toMatchObject({args:{highlight:1,shadow:0}});
    await expect(parse(['preview','photo.ARW'])).rejects.toThrow('needs -o');
    await expect(parse(['edit','photo.ARW','--patch','{bad}'])).rejects.toThrow('valid JSON');
    await expect(parse(['place','photo.ARW','--highlight','NaN','--shadow','0'])).rejects.toThrow();
    await expect(parse(['export','photo.ARW','--unknown','x'])).rejects.toThrow('Unknown option');
  });
  it('has a one-to-one command/tool table and rejects extra/missing/invalid arguments',()=>{
    expect(tools).toHaveLength(12);expect(new Set(tools.map(t=>t.command)).size).toBe(12);
    expect(()=>checkTool('place_scene',{path:'a',highlight:7,shadow:0})).toThrow();
    expect(()=>checkTool('preview_image',{path:'a',long_edge:64.5})).toThrow();
    expect(()=>checkTool('edit_image',{path:'a',patch:{},overwrite:true})).toThrow();
    expect(()=>checkTool('export_image',{})).toThrow();
    expect(()=>checkTool('process_image',{path:'a',preview:'yes'})).toThrow();
  });
  it('reports tool failures as MCP isError, without invoking operations for bad arguments',async()=>{
    const call=vi.fn().mockRejectedValue(new Refused('Access is off')),image=vi.fn();
    const rpc=(method:string,params:unknown={})=>mcp({jsonrpc:'2.0',id:1,method,params},call,image);
    const refused=await rpc('tools/call',{name:'get_edit',arguments:{path:'a'}});expect(refused).toMatchObject({result:{isError:true,content:[{type:'text',text:'Refused: Access is off'}]}});
    expect(await rpc('tools/call',{name:'preview_image',arguments:{path:'a',long_edge:999999}})).toMatchObject({result:{isError:true}});expect(call).toHaveBeenCalledOnce();
    expect(await rpc('initialize')).toMatchObject({result:{protocolVersion:'2025-06-18',capabilities:{tools:{},prompts:{}}}});
    expect(await mcp({jsonrpc:'2.0',method:'notifications/initialized'},call,image)).toBeNull();
    expect(await rpc('bad')).toMatchObject({error:{code:-32601}});
    expect(await rpc('prompts/get',{name:'edit_photo',arguments:{path:'a'}})).toHaveProperty('result.messages');
  });
});
