import { describe,it,expect } from 'vitest';
import { fitPlacement, placementWindow } from './placement';
import { SCENE_LATITUDE_DEFAULT as base } from './params';
import oracle from './placementOracle.json';
describe('original Scene Placement fit',()=>{
  const m={highlight:{scene_extreme_ev:7,medium_boundary_ev:5},shadow:{scene_extreme_ev:-7,medium_boundary_ev:-5}};
  it('refuses small pullbacks and the bounded shadow lift, and resets to identity',()=>{
    expect(fitPlacement(m,1,0,base).issue?.code).toBe('pull_back_below_minimum');
    expect(fitPlacement(m,0,4,base).issue?.code).toBe('pull_back_exceeds_max_lift');
    expect(fitPlacement(m,0,0,base).value?.active).toBe(false);
  });
  it('clamps to the usable window and accepts its visible hundredth boundaries',()=>{
    const w=placementWindow(m,'highlight',0,base)!;
    expect(w[0]).toBeGreaterThan(2);expect(w[1]).toBeLessThanOrEqual(8);
    expect(fitPlacement(m,w[0],0,base).value?.active).toBe(true);
    expect(fitPlacement(m,w[1],0,base).value?.active).toBe(true);
  });
  it('agrees with the native C++ fit on 36 measured cases including refusals and four rolloffs',()=>{
    for(const c of oracle){
      const r=fitPlacement(c.fit,c.highlight,c.shadow,{...base,rolloff:c.rolloff});
      if(!c.fit.valid){expect(r.issue,JSON.stringify(c)).toEqual({code:c.fit.issues[0]!.code,side:c.fit.issues[0]!.side});continue;}
      expect(r.value,JSON.stringify(c)).toBeDefined();
      const d=c.fit.params_delta!;
      expect(r.value!.active).toBe(d.scene_latitude_active);
      for(const [key,wire] of [['highlightKnee','scene_latitude_highlight_knee'],['highlightRoom','scene_latitude_highlight_room'],['shadowKnee','scene_latitude_shadow_knee'],['shadowRoom','scene_latitude_shadow_room']] as const)
        expect(r.value![key]).toBeCloseTo(d[wire],10);
    }
  });
});
