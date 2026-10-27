import { describe, expect, it } from 'vitest';
import { engineGeometry, gateGeometry, printGeometry, frameProjection, pairProjection, dateProjection, mapUV } from './filmFrame';
import { GEOMETRY_DEFAULT, outputSize, sourcePoint } from './geometry';
import { FILM_PARAMS_DEFAULT, featureGate } from './params';

const p = { ...FILM_PARAMS_DEFAULT, filmEdge: { ...FILM_PARAMS_DEFAULT.filmEdge, active: true } };
describe('film frame geometry ownership', () => {
  it('maps each developed half-frame gate to its own source-preview rectangle', () => {
    const f=pairProjection({valid:true,vertical:false,gates:[
      [.1,.2,.45,.2,.45,.8,.1,.8],[.55,.2,.9,.2,.9,.8,.55,.8]]},
      [[0,0,18/37,1],[19/37,0,18/37,1]],{width:4000,height:3500})!;
    expect(mapUV(f.original,{x:.275,y:.5}).x).toBeCloseTo(9/37);
    expect(mapUV(f.second!.original,{x:.725,y:.5}).x).toBeCloseTo(28/37);
    const centre=mapUV(f.second!.gate,{x:.725,y:.5});
    expect(centre.x).toBeCloseTo(.5,12);expect(centre.y).toBeCloseTo(.5,12);
    expect(mapUV(f.gate,{x:.725,y:.5}).x).toBeGreaterThan(1);
  });
  it('aligns the original with a rotated film gate and leaves its rebate outside the picture', () => {
    const layout = { valid: true, vertical: true, gates: [[0.8, 0.1, 0.8, 0.9, 0.2, 0.9, 0.2, 0.1]] };
    const projection = frameProjection(layout, { width: 3000, height: 4000 }, GEOMETRY_DEFAULT, { width: 3500, height: 4500 })!;
    const p = mapUV(projection.original, { x: 0.2, y: 0.1 });
    expect(p.x).toBeCloseTo(0); expect(p.y).toBeCloseTo(0);
    const middle = mapUV(projection.original, { x: 0.5, y: 0.5 });
    expect(middle.x).toBeCloseTo(0.5); expect(middle.y).toBeCloseTo(0.5);
    expect(mapUV(projection.gate, { x: 0, y: 0.5 }).x).toBeLessThan(0);
  });
  it('maps a turned pair to its separate top/bottom source rectangles',()=>{
    const f=pairProjection({valid:true,vertical:true,gates:[
      [.8,.1,.8,.45,.2,.45,.2,.1],[.8,.55,.8,.9,.2,.9,.2,.55]]},
      [[0,0,1,18/37],[0,19/37,1,18/37]],{width:3500,height:4000})!;
    for(const [map,y] of [[f.original,.275],[f.second!.original,.725]] as const){
      const p=mapUV(map,{x:.5,y});expect(p.x).toBeCloseTo(.5,12);
      expect(p.y).toBeCloseTo(y<.5?9/37:28/37,12);
    }
    expect(mapUV(f.second!.gate,{x:.5,y:.275}).y).toBeLessThan(0);
  });
  it('centres a 135 gate in a 2:1 crop without moving its centre', () => {
    const g = gateGeometry(p, GEOMETRY_DEFAULT, { width: 4000, height: 2000 });
    expect(g.crop.width).toBeCloseTo(36.25 / 24.3 / 2);
    expect(g.crop.x + g.crop.width / 2).toBeCloseTo(0.5);
    expect(g.crop.height).toBe(1);
  });
  it('keeps square, panoramic and turned portrait gates on their physical ratio', () => {
    for (const [format, ratio] of [['120_6x6', 1], ['135_xpan', 65 / 24], ['120_6x17', 3]] as const) {
      const q = { ...p, filmEdge: { ...p.filmEdge, format } };
      const g = gateGeometry(q, { ...GEOMETRY_DEFAULT, quarterTurns: 1 }, { width: 2000, height: 4000 });
      const size = outputSize(g, { width: 2000, height: 4000 });
      expect(size.width / size.height).toBeCloseTo(ratio, 2);
    }
  });
  it('sends crop, turn and flips before development, then samples the entire rendered edge', () => {
    const g = { ...GEOMETRY_DEFAULT, quarterTurns: 1, flipH: true };
    const d = engineGeometry(p, g, { width: 4000, height: 2000 });
    expect(d.geometry_quarter_turns).toBe(1);
    expect(d.geometry_flip_h).toBe(true);
    expect(sourcePoint(printGeometry(p, g), { x: 0, y: 0 }, { width: 3000, height: 4000 })).toEqual({ x: 0, y: 0 });
    expect(printGeometry(FILM_PARAMS_DEFAULT, g)).toBe(g);
    expect(engineGeometry(p, g, { width: 4000, height: 2000 }, featureGate(['overscan'])).geometry_crop_w).toBe(1);
  });
  it('exposes a bare date after a free crop and turn, without imposing a film gate or cropping twice', () => {
    const date = { ...FILM_PARAMS_DEFAULT, dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true } };
    const g = { ...GEOMETRY_DEFAULT, crop: { x: 0.2, y: 0.1, width: 0.5, height: 0.6 }, quarterTurns: 1, flipV: true };
    const d = engineGeometry(date, g, { width: 6000, height: 4000 });
    expect(d.geometry_crop_x).toBe(0.2);
    expect(d.geometry_crop_w).toBe(0.5);
    expect(d.geometry_crop_h).toBe(0.6);
    expect(d.geometry_quarter_turns).toBe(1);
    expect(d.geometry_flip_v).toBe(true);
    expect(printGeometry(date, g)).toEqual(GEOMETRY_DEFAULT);
    expect(engineGeometry(date, g, { width: 6000, height: 4000 }, featureGate(['date_imprint'])).geometry_crop_w).toBe(1);
    expect(printGeometry({ ...date, dateBack: { ...date.dateBack, camera: null } }, g)).toBe(g);
    const projected = dateProjection({ width: 6000, height: 4000 }, g);
    expect(projected.native).toEqual({ width: 2400, height: 3000 });
    for (const point of [{ x: 0, y: 0 }, { x: 0.25, y: 0.75 }, { x: 1, y: 1 }]) {
      const original = mapUV(projected.original, point);
      const expected = sourcePoint(g, point, { width: 6000, height: 4000 });
      expect(original.x).toBeCloseTo(expected.x); expect(original.y).toBeCloseTo(expected.y);
      expect(mapUV(projected.gate, point)).toEqual(point);
    }
  });
});
