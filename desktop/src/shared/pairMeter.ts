import type {PairDocument,PairHole} from './pairs';
import type {PairInfo} from './protocol';
import {jsonEqual} from './params';
// The Mac deliberately excludes placement/trim/print: an unchanged shot and
// metering intent keeps its reading while a person moves it under the hole.
const inputs=(h:PairHole)=>({path:h.path,decode:h.decode,crop:h.geometry.crop,turns:h.geometry.quarterTurns,meterMethod:h.meterMethod??null});
export function mergePairMeter(live:PairDocument,opened:PairDocument,info:PairInfo):PairDocument {
  let next=live;
  for(const [i,side] of (['left','right'] as const).entries()) {
    const h=live[side],before=opened[side],r=info.sources[i];
    if(!h||!before||!r?.present||!h.autoExposure||r.path!==before.path||!jsonEqual(inputs(h),inputs(before))||
      !r.metered_for?.startsWith('windows-pair-meter-v1:')||!Number.isFinite(r.metered_ev)||Math.abs(r.metered_ev)>64)continue;
    if(h.meteredFor===r.metered_for&&h.meteredEV===r.metered_ev)continue;
    next={...next,[side]:{...h,meteredEV:r.metered_ev,meteredFor:r.metered_for}};
  }
  return next;
}
