import { expect, it } from 'vitest';
import { decodePair, pairParams } from './pairs';
import { FILM_PARAMS_DEFAULT, fullDelta } from './params';
import { engineGeometry } from './filmFrame';
import { GEOMETRY_DEFAULT } from './geometry';
it('uses a 37 mm piece for two 24 by 18 mm holes, with the Mac gap scale for bare pairs',()=>{
  const p={...FILM_PARAMS_DEFAULT,filmFrame:'Custom',filmSide:'long' as const,sideLengthMM:24};
  expect(pairParams(p,null).filmFormatMM).toBe(37);
  expect(pairParams({...p,filmEdge:{...p.filmEdge,active:false}},null,decodePair({folder:'x',spacingMM:2})).filmFormatMM).toBe(38);
});

it('keeps unknown Mac pair fields and source edits without adding unsupported print objects', () => {
  const p=decodePair({folder:'C:/photos', future:'keep',left:{path:'C:/photos/a.ARW', futureHole:42,
    geometry:{crop:[.1,.2,.5,.6]},decode:{whiteBalance:'Custom',temperature:3200,tint:10}}});
  expect(p.future).toBe('keep'); expect(p.left?.futureHole).toBe(42);
  expect(p.left?.geometry.crop.width).toBe(.5);
  expect(p.left?.decode.temperature).toBe(3200);
  expect(p.left?.print).toBeUndefined(); expect(p.right).toBeNull();
});

it('treats the complete pair as the negative and keeps each date and placement block distinct', () => {
  const p=pairParams({...FILM_PARAMS_DEFAULT, dateBack:{...FILM_PARAMS_DEFAULT.dateBack,active:true},
    sceneLatitudeOther:{...FILM_PARAMS_DEFAULT.sceneLatitudeOther,active:true,highlightKnee:2}},
    {complete:true,can_export:true,turned:false,on_strip:true,rects:[[0,0,.486,1],[.514,0,.486,1]],sources:[
      {path:'a',present:true,metadata:{datetime_original:'2026-10-01T00:00:00'},decode_error:'',exposure_ev:0,metered_ev:0},
      {path:'b',present:true,metadata:{datetime_original:'2026-10-03T00:00:00'},decode_error:'',exposure_ev:0,metered_ev:0}]});
  const wire=fullDelta(p);
  expect(wire.auto_exposure).toBe(false); expect(wire.overscan_pair).toBe(true);
  expect(wire.overscan_format).toBe('135_half');
  expect(wire.date_imprint_text).toBe("'26 10 1"); expect(wire.date_imprint_text_b).toBe("'26 10 3");
  expect(wire.scene_latitude_b_active).toBe(true);
  expect(wire.scene_latitude_b_highlight_knee).toBe(2);
  expect(engineGeometry(p,GEOMETRY_DEFAULT,{width:3700,height:2400}).geometry_crop_w).toBe(1);
});
