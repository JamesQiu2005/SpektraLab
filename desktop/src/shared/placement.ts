// Original PlacementFit / PlacementWindow arithmetic from Model/Latitude.swift.
import type { SceneLatitudeSettings } from './params';
export interface FitMeasure {highlight:{scene_extreme_ev:number;medium_boundary_ev:number};shadow:{scene_extreme_ev:number;medium_boundary_ev:number}}
export type PlacementSide='highlight'|'shadow';
export interface FitIssue {code:string;side:string}
function departure(d:number,h:number,m:number):number {
  if(d<=0)return 0;
  if(m===2){const r=Math.sqrt(h*h+d*d);return -d*d*d/(r*(h+r));}
  if(m===1)return -d*d/(h+d);
  return d*(h/Math.pow(Math.pow(h,m)+Math.pow(d,m),1/m)-1);
}
function knee(a:number,c:number,n:number,m:number):number|null {
  const t=a-n;if(!(n>0&&t<c))return null;
  const landing=(k:number)=>k+((a-k)+departure(a-k,c-k,m));
  let lo=t-Math.sqrt(Math.max(0,(a-t)*(c-t)))-64,hi=t;
  if(!(landing(lo)<t))return null;
  for(let i=0;i<200&&hi-lo>1e-12;i++){const mid=.5*(lo+hi);if(landing(mid)>t)hi=mid;else lo=mid;}
  return .5*(lo+hi);
}
export function fitPlacement(at:FitMeasure,highlight:number,shadow:number,base:SceneLatitudeSettings):{value?:SceneLatitudeSettings;issue?:FitIssue} {
  const issues:FitIssue[]=[],add=(code:string,side:string)=>issues.push({code,side});
  type Knee={k:number;r:number};
  let top:Knee|null=null,bottom:Knee|null=null;
  if(highlight>0){const k=knee(at.highlight.scene_extreme_ev,at.highlight.medium_boundary_ev,highlight,base.rolloff);
    if(k===null)add('pull_back_below_minimum','highlight');else top={k,r:at.highlight.medium_boundary_ev-k};}
  if(shadow>0){
    if(!(shadow>at.shadow.medium_boundary_ev-at.shadow.scene_extreme_ev))add('pull_back_below_minimum','shadow');
    else if(shadow>=base.maxLift)add('pull_back_exceeds_max_lift','shadow');
    else {const l=shadow*base.maxLift/Math.sqrt(base.maxLift*base.maxLift-shadow*shadow),k=knee(-at.shadow.scene_extreme_ev,-at.shadow.medium_boundary_ev,l,base.rolloff);
      if(k===null)add('pull_back_below_minimum','shadow');else bottom={k:-k,r:-k-at.shadow.medium_boundary_ev};}
  }
  for(const [p,side] of [[top,'highlight'],[bottom,'shadow']] as const)if(p){if(p.r<.5)add('room_below_minimum',side);if(p.r>24||Math.abs(p.k)>24)add('out_of_range',side);}
  if(top&&bottom&&!(bottom.k<top.k))add('knees_cross','both');
  if(issues[0])return {issue:issues[0]};
  return {value:{...base,active:!!(top||bottom),highlightPullBack:highlight,shadowPullBack:shadow,
    highlightRoom:top?.r??0,shadowRoom:bottom?.r??0,highlightKnee:top?.k??base.highlightKnee,shadowKnee:bottom?.k??base.shadowKnee}};
}
export function placementWindow(at:FitMeasure,side:PlacementSide,other:number,base:SceneLatitudeSettings):[number,number]|null {
  const valid=(v:number)=>!!fitPlacement(at,side==='highlight'?v:other,side==='shadow'?v:other,base).value;
  const min=side==='highlight'?at.highlight.scene_extreme_ev-at.highlight.medium_boundary_ev:at.shadow.medium_boundary_ev-at.shadow.scene_extreme_ev;
  let bad=Math.max(min,0),first:number|null=null;
  for(let x=Math.floor(bad/.125)*.125+.125;x<=8+1e-9;x+=.125){if(valid(x)){first=x;break;}bad=x;}
  if(first===null)return null;
  let good=first;while(good-bad>.005){const mid=(bad+good)/2;if(valid(mid))good=mid;else bad=mid;}
  const least=Math.min(Math.ceil(good/.01)/100,first);let most=8;
  if(!valid(8)){good=first;bad=8;while(bad-good>.005){const mid=(bad+good)/2;if(valid(mid))good=mid;else bad=mid;}most=Math.max(Math.floor(good/.01)/100,least);}
  return [least,most];
}
