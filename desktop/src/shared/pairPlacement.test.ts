import {it,expect} from 'vitest';
import {placedRect,draggedPlacement,zoomedPlacement} from './pairPlacement';
const fit={scale:1,x:0,y:0,quarterTurns:0},source={width:4000,height:3000};
it('moves the picture with the pointer while the cut moves in the opposite direction',()=>{
  const p=draggedPlacement({...fit,scale:2},{x:.1,y:-.2},source);
  expect(p.x).toBeCloseTo(-112.5/1437.5,12);expect(p.y).toBeCloseTo(.4,12);
  const filled={width:3000,height:4000};expect(draggedPlacement(fit,{x:.5,y:.5},filled)).toEqual(fit);
});
it('keeps the source point under the zoom anchor until an edge constrains it',()=>{
  const anchor={x:.25,y:.75},p=zoomedPlacement(fit,2,anchor,source);
  expect(p.scale).toBe(2);expect(p.x).toBeCloseTo(-281.25/1437.5,12);expect(p.y).toBeCloseTo(.5,12);
  const a=placedRect(fit,source),b=placedRect(p,source);
  expect(a.x+anchor.x*a.width).toBeCloseTo(b.x+anchor.x*b.width,9);
  expect(a.y+anchor.y*a.height).toBeCloseTo(b.y+anchor.y*b.height,9);
});
it('honours turn/aspect, slack, finite scale and the original bounds',()=>{
  const p=zoomedPlacement({...fit,quarterTurns:1},100,{x:0,y:1},source,4/3);
  expect(p.scale).toBe(4);expect(Math.abs(p.x)).toBeLessThanOrEqual(1);expect(Math.abs(p.y)).toBeLessThanOrEqual(1);
  const r=placedRect(p,{width:source.height,height:source.width},4/3);
  expect(r.width/r.height).toBeCloseTo(4/3,12);
  expect(zoomedPlacement(fit,NaN,{x:.5,y:.5},source)).toEqual(fit);
  expect(zoomedPlacement(fit,0,{x:.5,y:.5},source)).toEqual(fit);
});
