// Film Edge is exposed before development. Geometry therefore belongs to the
// engine while it is active; the canvas/file must not apply it a second time.
import { type FilmParams, type FeatureGate, ALL_FEATURES } from './params';
import { type Geometry, type Size, type Point, GEOMETRY_DEFAULT, centre, sourcePoint, isIdentity, outputSize } from './geometry';
import { dateCapability } from './imprints';

const GATES: Record<string, [number, number]> = {
  '135': [36.25, 24.3], '135_half': [18, 24], '135_xpan': [65, 24],
  '120_645': [41.5, 56], '120_6x6': [56, 56], '120_6x7': [69.5, 56],
  '120_6x8': [76, 56], '120_6x9': [84, 56], '120_6x12': [112, 56], '120_6x17': [168, 56],
};
export const hasFilmFrame = (p: FilmParams, gate: FeatureGate = ALL_FEATURES) => gate.overscan && p.filmEdge.active;
export const geometryInNegative = (p: FilmParams, gate: FeatureGate = ALL_FEATURES) =>
  hasFilmFrame(p, gate) || (gate.dateImprint && dateCapability(p, gate.overscan).active);
export const cutsFrame = (p: FilmParams, g: Geometry, gate: FeatureGate = ALL_FEATURES) =>
  hasFilmFrame(p, gate) || (geometryInNegative(p, gate) && !isIdentity(g));

export function gateGeometry(p: FilmParams, g: Geometry, native: Size): Geometry {
  const [a, b] = GATES[p.filmEdge.format] ?? GATES['135']!;
  const ratio = Math.max(a, b) / Math.min(a, b);
  const current = g.crop.width * native.width / (g.crop.height * native.height);
  const target = current >= 1 ? ratio : 1 / ratio;
  let { width, height } = g.crop;
  if (current > target) width = height * native.height * target / native.width;
  else height = width * native.width / target / native.height;
  const c = centre(g);
  return { ...g, crop: { x: c.x - width / 2, y: c.y - height / 2, width, height } };
}

export function engineGeometry(p: FilmParams, g: Geometry, native: Size | null, gate: FeatureGate = ALL_FEATURES) {
  if(p.filmEdge.pair) return wireGeometry(GEOMETRY_DEFAULT);
  const f = hasFilmFrame(p, gate) && native ? gateGeometry(p, g, native)
    : geometryInNegative(p, gate) ? g : GEOMETRY_DEFAULT;
  return wireGeometry(f);
}

/** A crop that must be exposed on the negative, including raw Cineon exports. */
export function wireGeometry(f: Geometry) {
  return {
    geometry_crop_x: f.crop.x, geometry_crop_y: f.crop.y,
    geometry_crop_w: f.crop.width, geometry_crop_h: f.crop.height,
    geometry_rotation_deg: f.angle, geometry_quarter_turns: ((f.quarterTurns % 4) + 4) % 4,
    geometry_flip_h: f.flipH, geometry_flip_v: f.flipV,
  };
}

export const printGeometry = (p: FilmParams, g: Geometry, gate: FeatureGate = ALL_FEATURES): Geometry => cutsFrame(p, g, gate) ? GEOMETRY_DEFAULT : g;

export type UVMap = [number, number, number, number, number, number];
export interface FrameProjection { native: Size; original: UVMap; gate: UVMap; filmEdge?: boolean; second?:{original:UVMap;gate:UVMap} }
export interface FrameLayout { valid: boolean; vertical: boolean; gates: number[][] }
export const mapUV = (m: UVMap, p: Point): Point => ({ x: m[0] * p.x + m[2] * p.y + m[4], y: m[1] * p.x + m[3] * p.y + m[5] });

/** Bare date: the crop is already in the negative, with no surrounding rebate. */
export function dateProjection(native: Size, g: Geometry): FrameProjection {
  const o = sourcePoint(g, { x: 0, y: 0 }, native);
  const x = sourcePoint(g, { x: 1, y: 0 }, native);
  const y = sourcePoint(g, { x: 0, y: 1 }, native);
  return { native: outputSize(g, native), filmEdge: false, gate: [1, 0, 0, 1, 0, 0],
    original: [x.x-o.x, x.y-o.y, y.x-o.x, y.y-o.y, o.x, o.y] };
}

export function frameProjection(layout: FrameLayout, native: Size, g: Geometry, canvas: Size): FrameProjection | null {
  const q = layout.gates?.[0];
  if (!layout.valid || !q || q.length !== 8) return null;
  const ax = q[2]! - q[0]!, ay = q[3]! - q[1]!, bx = q[6]! - q[0]!, by = q[7]! - q[1]!;
  const det = ax * by - ay * bx;
  if (Math.abs(det) < 1e-12) return null;
  const uv = (p: Point): Point => {
    const x = p.x - q[0]!, y = p.y - q[1]!;
    const u = (by * x - bx * y) / det, v = (-ay * x + ax * y) / det;
    return layout.vertical ? { x: 1 - v, y: u } : { x: u, y: v };
  };
  const matrix = (fn: (p: Point) => Point): UVMap => {
    const o = fn({ x: 0, y: 0 }), x = fn({ x: 1, y: 0 }), y = fn({ x: 0, y: 1 });
    return [x.x - o.x, x.y - o.y, y.x - o.x, y.y - o.y, o.x, o.y];
  };
  return { native: canvas, filmEdge: true, gate: matrix(uv), original: matrix((p) => sourcePoint(g, uv(p), native)) };
}

/** Each physical gate samples its own hole in the composed camera preview. */
export function pairProjection(layout:FrameLayout,rects:number[][],canvas:Size):FrameProjection|null {
  if(layout.gates?.length!==2||rects.length!==2) return null;
  const parts=layout.gates.map((gate,i)=>{
    const f=frameProjection({...layout,gates:[gate]},canvas,GEOMETRY_DEFAULT,canvas);
    const r=rects[i]; if(!f||!r||r.length!==4) return null;
    const m=f.gate,w=r[2]!,h=r[3]!;
    return {gate:m,original:[m[0]*w,m[1]*h,m[2]*w,m[3]*h,m[4]*w+r[0]!,m[5]*h+r[1]!] as UVMap};
  });
  return parts[0]&&parts[1]?{...parts[0],second:parts[1],native:canvas,filmEdge:true}:null;
}
