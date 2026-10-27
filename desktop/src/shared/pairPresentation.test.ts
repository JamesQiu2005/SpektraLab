import {it,expect} from 'vitest';
import {composePairPixels,printDelta,pairHasPresentation} from './pairPresentation';
import {FILM_PARAMS_DEFAULT} from './params';
import {decodePair} from './pairs';
import {ADJUSTMENTS_DEFAULT} from './adjustments';
it('cuts only each frame rectangle, with the original 1.5px coverage and film outside',()=>{
  const size={width:12,height:4},base=new Uint16Array(192).fill(10000),left=new Uint16Array(192).fill(50000),right=new Uint16Array(192).fill(30000);
  const out=composePairPixels(base,size,[left,right],[[0,0,.25,1],[.75,0,.25,1]]);
  expect(out[4*(1*12+1)]).toBe(50000);expect(out[4*(1*12+10)]).toBe(30000);
  expect(out[4*(1*12+5)]).toBe(10000);
  expect(out[4*(1*12)]).toBe(43333);
  expect(base[0]).toBe(10000);
});
it('keeps print-only overrides on the print layer and detects genuine per-hole changes',()=>{
  const d=printDelta(FILM_PARAMS_DEFAULT,{brightnessStops:1,yFilterShift:.2,mFilterShift:-.1,preflashExposure:.01});
  expect(Object.keys(d).sort()).toEqual(['m_filter_shift','preflash_exposure','print_exposure','y_filter_shift']);
  const pair=decodePair({folder:'x',left:{path:'a'}});
  expect(pairHasPresentation(pair,FILM_PARAMS_DEFAULT,ADJUSTMENTS_DEFAULT)).toBe(false);
  pair.left!.adjustments={...ADJUSTMENTS_DEFAULT,exposure:1};
  expect(pairHasPresentation(pair,FILM_PARAMS_DEFAULT,ADJUSTMENTS_DEFAULT)).toBe(true);
});
