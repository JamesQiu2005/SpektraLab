import {expect,it} from 'vitest';
import {MockHost} from './core';
import {newPair,newHole} from '../src/shared/pair';
import {ADJUSTMENTS_DEFAULT} from '../src/shared/adjustments';
it('provides synthetic pair controls with stable session IDs and current gate metadata',async()=>{
  const host=new MockHost({nativeWidth:96,nativeHeight:64});
  const call=async(method:string,params:Record<string,unknown>)=>{const r=await host.handle({id:1,method,params});expect(r.header.ok).toBe(true);return{result:r.header.result as Record<string,unknown>,data:r.payload}};
  const pair=newPair('/photos');pair.left=newHole('/photos/a.png');pair.right=newHole('/photos/b.png');
  const opened=await call('open_pair',{path:'/photos/one.spektrapair',pair,params:{}});const session=opened.result.session;
  const view=await call('render_view',{session,tier:'full',display:'srgb',generation:1});
  expect(view.result.pair_info).toMatchObject({left:{available:true},right:{available:true},gates:expect.any(Array)});
  pair.right.adjustments={...ADJUSTMENTS_DEFAULT,exposure:1};
  expect((await call('update_pair',{session,pair,params:{}})).result.session).toBe(session);
  const changed=await call('render_view',{session,tier:'full',display:'srgb',generation:2});expect(changed.data).not.toEqual(view.data);
});
