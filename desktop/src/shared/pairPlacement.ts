import type {PairHole,PairSide} from './pairs';
import type {Point,Size} from './geometry';
import {clamp} from './params';
export type Placement=PairHole['placement'];
export interface PlacementDraft {selection:string;side:PairSide;before:PairHole;live:Placement;settling:boolean}
const turned=(s:Size,p:Placement)=>Math.abs(p.quarterTurns)%2?{width:s.height,height:s.width}:s;
/** Source is already quarter-turned here, just as HalfFramePair.sourceRect. */
export function placedRect(p:Placement,s:Size,aspect=.75){
  let width=s.width,height=s.height;if(width/height>aspect)width=height*aspect;else height=width/aspect;
  width/=clamp(p.scale,1,4);height/=clamp(p.scale,1,4);
  return {x:(s.width-width)*(1+clamp(p.x,-1,1))/2,y:(s.height-height)*(1+clamp(p.y,-1,1))/2,width,height};
}
/** Model/Session.swift placement(draggedBy:): d is a fraction of the hole. */
export function draggedPlacement(p:Placement,d:Point,source:Size,aspect=.75):Placement {
  const s=turned(source,p),cut=placedRect(p,s,aspect),sx=(s.width-cut.width)/2,sy=(s.height-cut.height)/2;
  return {...p,x:sx>.5?clamp(p.x-d.x*cut.width/sx,-1,1):p.x,y:sy>.5?clamp(p.y-d.y*cut.height/sy,-1,1):p.y};
}
/** Original anchor-preserving zoom; the source edge wins over the anchor. */
export function zoomedPlacement(p:Placement,factor:number,a:Point,source:Size,aspect=.75):Placement {
  if(!Number.isFinite(factor)||factor<=0)return p;
  const s=turned(source,p),was=placedRect(p,s,aspect),from=clamp(p.scale,1,4),scale=clamp(from*factor,1,4);
  if(scale===from||was.width<=0||was.height<=0)return p;
  const w=was.width*from/scale,h=was.height*from/scale,cx=was.x+a.x*was.width-a.x*w+w/2,cy=was.y+a.y*was.height-a.y*h+h/2;
  const sx=(s.width-w)/2,sy=(s.height-h)/2;
  return {...p,scale,x:sx>.5?clamp((cx-s.width/2)/sx,-1,1):0,y:sy>.5?clamp((cy-s.height/2)/sy,-1,1):0};
}
