// geometry.ts — crop, straighten, quarter turns and flips, applied **after**
// the engine (ARCHITECTURE.md §7.1). A port of `Model/Geometry.swift`.
//
// Coordinates are normalised to the *source* (the engine's print), origin top
// left. The output is the crop, rotated by `angle` about its centre so it is
// rigid in pixels, then turned and flipped. `sourcePoint(forOutput:)` is the
// one map every surface uses (canvas shader, navigator, filmstrip, export),
// and `geometry.test.ts` + `surfaces.test.ts` pin that they agree — AGENTS.md
// trap 33: every surface that shows the frame shows the canvas's frame.

import { clamp } from './params';

export interface Point {
  x: number;
  y: number;
}
export interface Size {
  width: number;
  height: number;
}
export interface CropRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export const CROP_FULL: CropRect = { x: 0, y: 0, width: 1, height: 1 };

export type CropAspect =
  | 'free'
  | 'original'
  | 'originalPortrait'
  | 'square'
  | 'r3x2'
  | 'r2x3'
  | 'r4x3'
  | 'r3x4'
  | 'r16x9'
  | 'r9x16'
  | 'r5x4'
  | 'r4x5'
  | 'r7x5'
  | 'r5x7';

export const CROP_ASPECT_PICKER: CropAspect[] = ['free', 'original', 'square', 'r3x2', 'r4x3', 'r16x9', 'r5x4', 'r7x5'];

const RATIOS: Partial<Record<CropAspect, number>> = {
  square: 1,
  r3x2: 3 / 2,
  r2x3: 2 / 3,
  r4x3: 4 / 3,
  r3x4: 3 / 4,
  r16x9: 16 / 9,
  r9x16: 9 / 16,
  r5x4: 5 / 4,
  r4x5: 4 / 5,
  r7x5: 7 / 5,
  r5x7: 5 / 7,
};
const TRANSPOSE: Record<CropAspect, CropAspect> = {
  free: 'free',
  square: 'square',
  original: 'originalPortrait',
  originalPortrait: 'original',
  r3x2: 'r2x3',
  r2x3: 'r3x2',
  r4x3: 'r3x4',
  r3x4: 'r4x3',
  r16x9: 'r9x16',
  r9x16: 'r16x9',
  r5x4: 'r4x5',
  r4x5: 'r5x4',
  r7x5: 'r5x7',
  r5x7: 'r7x5',
};

export function aspectLabel(a: CropAspect): string {
  switch (a) {
    case 'free':
      return 'Free';
    case 'original':
    case 'originalPortrait':
      return 'Original';
    case 'square':
      return '1:1';
    case 'r3x2':
    case 'r2x3':
      return '3:2';
    case 'r4x3':
    case 'r3x4':
      return '4:3';
    case 'r16x9':
    case 'r9x16':
      return '16:9';
    case 'r5x4':
    case 'r4x5':
      return '5:4';
    case 'r7x5':
    case 'r5x7':
      return '7:5';
  }
}
export const aspectTransposed = (a: CropAspect) => TRANSPOSE[a];
export const aspectIsPortrait = (a: CropAspect) =>
  ['originalPortrait', 'r2x3', 'r3x4', 'r9x16', 'r4x5', 'r5x7'].includes(a);
export const aspectCanonical = (a: CropAspect) => (aspectIsPortrait(a) ? TRANSPOSE[a] : a);
export const aspectHasOrientation = (a: CropAspect) => a !== 'free' && a !== 'square';
export function aspectRatio(a: CropAspect, sourceAspect: number): number | null {
  if (a === 'original') return sourceAspect;
  if (a === 'originalPortrait') return 1 / Math.max(sourceAspect, Number.MIN_VALUE);
  return RATIOS[a] ?? null;
}

export interface Geometry {
  crop: CropRect;
  angle: number;
  quarterTurns: number;
  flipH: boolean;
  flipV: boolean;
  aspect: CropAspect;
  /** The crop's size before a straighten shrank it (Swift: CGSize as [w, h]). */
  intendedSize?: Size | null;
  lockedRatio?: number | null;
}

export const GEOMETRY_DEFAULT: Geometry = {
  crop: CROP_FULL,
  angle: 0,
  quarterTurns: 0,
  flipH: false,
  flipV: false,
  aspect: 'free',
  intendedSize: null,
  lockedRatio: null,
};

export const MAX_ANGLE = 45;
export const MIN_SIDE = 16;

const mod4 = (n: number) => ((Math.round(n) % 4) + 4) % 4;

export const isIdentity = (g: Geometry) =>
  g.crop.x === 0 &&
  g.crop.y === 0 &&
  g.crop.width === 1 &&
  g.crop.height === 1 &&
  g.angle === 0 &&
  mod4(g.quarterTurns) === 0 &&
  !g.flipH &&
  !g.flipV;

export const centre = (g: Geometry): Point => ({ x: g.crop.x + g.crop.width / 2, y: g.crop.y + g.crop.height / 2 });

export function lockRatio(g: Geometry, sourceAspect: number): number | null {
  return g.lockedRatio ?? aspectRatio(g.aspect, sourceAspect);
}

/** The output's pixel size for a source of `image` pixels. */
export function outputSize(g: Geometry, image: Size): Size {
  const w = Math.max(Math.round(g.crop.width * image.width), 1);
  const h = Math.max(Math.round(g.crop.height * image.height), 1);
  return mod4(g.quarterTurns) % 2 === 0 ? { width: w, height: h } : { width: h, height: w };
}

/** Output uv (0…1, top-left) → source uv. The one map (trap 33). */
export function sourcePoint(g: Geometry, p: Point, image: Size): Point {
  let u = { x: p.x, y: p.y };
  if (g.flipH) u.x = 1 - u.x;
  if (g.flipV) u.y = 1 - u.y;
  switch (mod4(g.quarterTurns)) {
    case 1:
      u = { x: u.y, y: 1 - u.x };
      break;
    case 2:
      u = { x: 1 - u.x, y: 1 - u.y };
      break;
    case 3:
      u = { x: 1 - u.y, y: u.x };
      break;
  }
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const px = (u.x - 0.5) * g.crop.width * w;
  const py = (u.y - 0.5) * g.crop.height * h;
  const a = (g.angle * Math.PI) / 180;
  const ca = Math.cos(a);
  const sa = Math.sin(a);
  const c = centre(g);
  return { x: c.x + (px * ca - py * sa) / w, y: c.y + (px * sa + py * ca) / h };
}

/** Source uv → output uv; the inverse of `sourcePoint`. */
export function outputPoint(g: Geometry, p: Point, image: Size): Point {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const c = centre(g);
  const dx = (p.x - c.x) * w;
  const dy = (p.y - c.y) * h;
  const a = (-g.angle * Math.PI) / 180;
  const ca = Math.cos(a);
  const sa = Math.sin(a);
  const px = dx * ca - dy * sa;
  const py = dx * sa + dy * ca;
  let u = { x: px / (g.crop.width * w) + 0.5, y: py / (g.crop.height * h) + 0.5 };
  switch ((4 - mod4(g.quarterTurns)) % 4) {
    case 1:
      u = { x: u.y, y: 1 - u.x };
      break;
    case 2:
      u = { x: 1 - u.x, y: 1 - u.y };
      break;
    case 3:
      u = { x: 1 - u.y, y: u.x };
      break;
  }
  if (g.flipH) u.x = 1 - u.x;
  if (g.flipV) u.y = 1 - u.y;
  return u;
}

/**
 * Output pixel → source pixel as an affine matrix [a, b, c, d, tx, ty]
 * (canvas 2D `setTransform` order): src = (a·x + c·y + tx, b·x + d·y + ty).
 */
export function outputToSourceTransform(g: Geometry, image: Size): [number, number, number, number, number, number] {
  const out = outputSize(g, image);
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const px = (p: Point) => {
    const s = sourcePoint(g, p, image);
    return { x: s.x * w, y: s.y * h };
  };
  const o = px({ x: 0, y: 0 });
  const ex = px({ x: 1, y: 0 });
  const ey = px({ x: 0, y: 1 });
  return [(ex.x - o.x) / out.width, (ex.y - o.y) / out.width, (ey.x - o.x) / out.height, (ey.y - o.y) / out.height, o.x, o.y];
}

/** The shader's uniform block (`GeometryUniform` in Shaders.metal). */
export interface GeometryUniform {
  centre: [number, number];
  halfExtent: [number, number];
  cosSin: [number, number];
  pixelRatio: [number, number];
  quarterTurns: number;
  flips: number;
  active: boolean;
}

export function uniform(g: Geometry, image: Size): GeometryUniform {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const a = (g.angle * Math.PI) / 180;
  const c = centre(g);
  return {
    centre: [c.x, c.y],
    halfExtent: [g.crop.width / 2, g.crop.height / 2],
    cosSin: [Math.cos(a), Math.sin(a)],
    pixelRatio: [w / h, h / w],
    quarterTurns: mod4(g.quarterTurns),
    flips: (g.flipH ? 1 : 0) | (g.flipV ? 2 : 0),
    active: !isIdentity(g),
  };
}

/** `geometryMap` in the shader, transliterated: what the GLSL must equal. */
export function shaderMap(u: GeometryUniform, uv: Point): Point {
  if (!u.active) return uv;
  let p = { ...uv };
  if (u.flips & 1) p.x = 1 - p.x;
  if (u.flips & 2) p.y = 1 - p.y;
  switch (u.quarterTurns) {
    case 1:
      p = { x: p.y, y: 1 - p.x };
      break;
    case 2:
      p = { x: 1 - p.x, y: 1 - p.y };
      break;
    case 3:
      p = { x: 1 - p.y, y: p.x };
      break;
  }
  const px = (p.x - 0.5) * 2 * u.halfExtent[0];
  const py = (p.y - 0.5) * 2 * u.halfExtent[1] * u.pixelRatio[1];
  const rx = px * u.cosSin[0] - py * u.cosSin[1];
  const ry = px * u.cosSin[1] + py * u.cosSin[0];
  return { x: u.centre[0] + rx, y: u.centre[1] + ry * u.pixelRatio[0] };
}

// ---------------------------------------------------------------- editing

export function corners(g: Geometry, image: Size): Point[] {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const c = centre(g);
  const hw = (g.crop.width / 2) * w;
  const hh = (g.crop.height / 2) * h;
  const a = (g.angle * Math.PI) / 180;
  const ca = Math.cos(a);
  const sa = Math.sin(a);
  return [
    [-1, -1],
    [1, -1],
    [1, 1],
    [-1, 1],
  ].map(([sx, sy]) => {
    const px = sx! * hw;
    const py = sy! * hh;
    return { x: c.x + (px * ca - py * sa) / w, y: c.y + (px * sa + py * ca) / h };
  });
}

export function fits(g: Geometry, image: Size, eps = 1e-6): boolean {
  return corners(g, image).every((p) => p.x >= -eps && p.y >= -eps && p.x <= 1 + eps && p.y <= 1 + eps);
}

export function snappedToFrame(g: Geometry, eps = 1e-5): Geometry {
  if (g.angle !== 0) return g;
  const crop = { ...g.crop };
  const snap = (o: 'x' | 'y', l: 'width' | 'height') => {
    if (crop[o] < 0 && crop[o] > -eps) {
      crop[l] += crop[o];
      crop[o] = 0;
    }
    if (crop[o] + crop[l] > 1 && crop[o] + crop[l] < 1 + eps) crop[l] = 1 - crop[o];
  };
  snap('x', 'width');
  snap('y', 'height');
  return { ...g, crop };
}

export function fitted(g0: Geometry, image: Size): Geometry {
  const g = { ...g0, crop: { ...g0.crop } };
  g.crop.x = clamp(g.crop.x + g.crop.width / 2, 0, 1) - g.crop.width / 2;
  g.crop.y = clamp(g.crop.y + g.crop.height / 2, 0, 1) - g.crop.height / 2;
  if (fits(g, image)) return snappedToFrame(g);
  const c = centre(g);
  let lo = 0;
  let hi = 1;
  const at = (k: number): Geometry => ({
    ...g,
    crop: {
      x: c.x - (g.crop.width * k) / 2,
      y: c.y - (g.crop.height * k) / 2,
      width: g.crop.width * k,
      height: g.crop.height * k,
    },
  });
  for (let i = 0; i < 40; i++) {
    const mid = (lo + hi) / 2;
    if (fits(at(mid), image)) lo = mid;
    else hi = mid;
  }
  return snappedToFrame(at(lo));
}

function maxScale(half: Size, c: Point, angle: number, image: Size): number {
  const a = half.width;
  const b = half.height;
  if (a <= 0 || b <= 0) return 0;
  const r = (angle * Math.PI) / 180;
  const ca = Math.abs(Math.cos(r));
  const sa = Math.abs(Math.sin(r));
  const roomX = Math.min(c.x, image.width - c.x);
  const roomY = Math.min(c.y, image.height - c.y);
  if (roomX <= 0 || roomY <= 0) return 0;
  return Math.min(roomX / (a * ca + b * sa), roomY / (a * sa + b * ca));
}

export function straightened(g: Geometry, degrees: number, image: Size): Geometry {
  const out: Geometry = { ...g, angle: clamp(degrees, -MAX_ANGLE, MAX_ANGLE) };
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const c0 = centre(g);
  const c = { x: clamp(c0.x, 0, 1), y: clamp(c0.y, 0, 1) };
  const base = g.intendedSize ?? { width: g.crop.width, height: g.crop.height };
  if (!(base.width > 0 && base.height > 0)) return fitted(out, image);
  let cap: number;
  if (g.intendedSize) cap = 1;
  else if (
    maxScale({ width: (g.crop.width * w) / 2, height: (g.crop.height * h) / 2 }, { x: c.x * w, y: c.y * h }, g.angle, image) >
    1 + 1e-4
  )
    cap = 1;
  else cap = Infinity;
  const scale = Math.min(
    maxScale({ width: (base.width * w) / 2, height: (base.height * h) / 2 }, { x: c.x * w, y: c.y * h }, out.angle, image),
    cap,
  );
  out.crop = {
    x: c.x - (base.width * scale) / 2,
    y: c.y - (base.height * scale) / 2,
    width: base.width * scale,
    height: base.height * scale,
  };
  return out;
}

export function moved(g: Geometry, delta: Point, image: Size): Geometry {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const a = (g.crop.width * w) / 2;
  const b = (g.crop.height * h) / 2;
  const r = (g.angle * Math.PI) / 180;
  const ca = Math.abs(Math.cos(r));
  const sa = Math.abs(Math.sin(r));
  const hx = (a * ca + b * sa) / w;
  const hy = (a * sa + b * ca) / h;
  const cl = (v: number, half: number, cur: number) => (half <= 0.5 ? clamp(v, half, 1 - half) : cur);
  const c = centre(g);
  const x = cl(c.x + delta.x, hx, c.x);
  const y = cl(c.y + delta.y, hy, c.y);
  return { ...g, crop: { ...g.crop, x: x - g.crop.width / 2, y: y - g.crop.height / 2 } };
}

export function turned(g: Geometry, steps: number): Geometry {
  return { ...g, quarterTurns: mod4(g.quarterTurns + steps) };
}

const rememberingSize = (g: Geometry): Geometry => ({
  ...g,
  intendedSize: { width: g.crop.width, height: g.crop.height },
});

/** Re-fit the crop to its aspect lock, keeping its area about `anchor`. */
export function constrained(g: Geometry, image: Size, anchor: Point = { x: 0.5, y: 0.5 }): Geometry {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const ratio = lockRatio(g, w / h);
  if (ratio == null) return fitted(g, image);
  const pw = g.crop.width * w;
  const ph = g.crop.height * h;
  const area = Math.max(pw * ph, 1);
  const nw = Math.sqrt(area * ratio);
  const nh = nw / ratio;
  const x1 = g.crop.x + g.crop.width * anchor.x;
  const y1 = g.crop.y + g.crop.height * anchor.y;
  const out: Geometry = {
    ...g,
    crop: { x: x1 - (nw / w) * anchor.x, y: y1 - (nh / h) * anchor.y, width: nw / w, height: nh / h },
  };
  return rememberingSize(fitted(out, image));
}

export function withAspect(g: Geometry, aspect: CropAspect, image: Size): Geometry {
  return constrained({ ...g, aspect, lockedRatio: null }, image);
}

export type CropHandle = 'topLeft' | 'top' | 'topRight' | 'right' | 'bottomRight' | 'bottom' | 'bottomLeft' | 'left' | 'body';
export const CROP_HANDLES: CropHandle[] = ['topLeft', 'top', 'topRight', 'right', 'bottomRight', 'bottom', 'bottomLeft', 'left'];
const movesLeading = (h: CropHandle) => h === 'topLeft' || h === 'left' || h === 'bottomLeft';
const movesTrailing = (h: CropHandle) => h === 'topRight' || h === 'right' || h === 'bottomRight';
const movesTop = (h: CropHandle) => h === 'topLeft' || h === 'top' || h === 'topRight';
const movesBottom = (h: CropHandle) => h === 'bottomLeft' || h === 'bottom' || h === 'bottomRight';
export const isCorner = (h: CropHandle) => h === 'topLeft' || h === 'topRight' || h === 'bottomLeft' || h === 'bottomRight';
export const handlePosition = (h: CropHandle): Point => ({
  x: movesLeading(h) ? 0 : movesTrailing(h) ? 1 : 0.5,
  y: movesTop(h) ? 0 : movesBottom(h) ? 1 : 0.5,
});
const oppositeAnchor = (h: CropHandle): Point => ({
  x: movesLeading(h) ? 1 : movesTrailing(h) ? 0 : 0.5,
  y: movesTop(h) ? 1 : movesBottom(h) ? 0 : 0.5,
});

function rotate(p: Point, pivot: Point, degrees: number, image: Size): Point {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const dx = (p.x - pivot.x) * w;
  const dy = (p.y - pivot.y) * h;
  const a = (degrees * Math.PI) / 180;
  const ca = Math.cos(a);
  const sa = Math.sin(a);
  return { x: pivot.x + (dx * ca - dy * sa) / w, y: pivot.y + (dx * sa + dy * ca) / h };
}
export const unrotated = (g: Geometry, p: Point, image: Size) => rotate(p, centre(g), -g.angle, image);
export const rotated = (g: Geometry, p: Point, image: Size) => rotate(p, centre(g), g.angle, image);

/** The handle under a source point, with a tolerance in source pixels. */
export function handleAt(g: Geometry, p: Point, image: Size, tolerance: number): CropHandle | null {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const q = unrotated(g, p, image);
  const dx = (q.x - g.crop.x) * w;
  const dy = (q.y - g.crop.y) * h;
  const cw = g.crop.width * w;
  const ch = g.crop.height * h;
  let best: { handle: CropHandle; rank: number } | null = null;
  for (const handle of CROP_HANDLES) {
    const pos = handlePosition(handle);
    const d = Math.hypot(dx - pos.x * cw, dy - pos.y * ch);
    if (d > tolerance) continue;
    const rank = isCorner(handle) ? d : d + tolerance;
    if (!best || rank < best.rank) best = { handle, rank };
  }
  if (best) return best.handle;
  const inside = dx >= -tolerance && dy >= -tolerance && dx <= cw + tolerance && dy <= ch + tolerance;
  return inside ? 'body' : null;
}

/** Drag a handle to a source point; the crop stays inside the frame. */
export function resized(g: Geometry, handle: CropHandle, point: Point, image: Size): Geometry {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const ratio = lockRatio(g, w / h);
  const from = {
    x: movesLeading(handle) ? g.crop.x : g.crop.x + g.crop.width,
    y: movesTop(handle) ? g.crop.y : g.crop.y + g.crop.height,
  };
  const asked = (p: Point): Geometry => {
    let minX = g.crop.x;
    let minY = g.crop.y;
    let maxX = g.crop.x + g.crop.width;
    let maxY = g.crop.y + g.crop.height;
    if (movesLeading(handle)) minX = p.x;
    if (movesTrailing(handle)) maxX = p.x;
    if (movesTop(handle)) minY = p.y;
    if (movesBottom(handle)) maxY = p.y;
    let crop: CropRect = {
      x: Math.min(minX, maxX),
      y: Math.min(minY, maxY),
      width: Math.max(Math.abs(maxX - minX), MIN_SIDE / w),
      height: Math.max(Math.abs(maxY - minY), MIN_SIDE / h),
    };
    if (ratio != null) {
      const anchor = oppositeAnchor(handle);
      const pw = crop.width * w;
      const ph = crop.height * h;
      let nw = pw;
      let nh = ph;
      if (isCorner(handle)) {
        nw = Math.max(pw, ph * ratio);
        nh = nw / ratio;
        if (nh < MIN_SIDE) {
          nh = MIN_SIDE;
          nw = nh * ratio;
        }
      } else if (movesLeading(handle) || movesTrailing(handle)) nh = pw / ratio;
      else nw = ph * ratio;
      const ax = crop.x + crop.width * anchor.x;
      const ay = crop.y + crop.height * anchor.y;
      crop = { x: ax - (nw / w) * anchor.x, y: ay - (nh / h) * anchor.y, width: nw / w, height: nh / h };
    }
    let out: Geometry = { ...g, crop };
    if (g.angle !== 0) {
      const c = rotated(g, centre(out), image);
      out = { ...out, crop: { ...crop, x: c.x - crop.width / 2, y: c.y - crop.height / 2 } };
    }
    return out;
  };
  const target = { x: clamp(point.x, 0, 1), y: clamp(point.y, 0, 1) };
  const want = asked(target);
  if (fits(want, image)) return rememberingSize(want);
  const furthest = (start: Point, end: Point): Point => {
    const at = (t: number) => ({ x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t });
    let lo = 0;
    let hi = 1;
    for (let i = 0; i < 30; i++) {
      const mid = (lo + hi) / 2;
      if (fits(asked(at(mid)), image)) lo = mid;
      else hi = mid;
    }
    return at(lo);
  };
  // The last step back into the frame: a lock's float rounding can leave the
  // start of the search a hair outside it (Swift has the same edge).
  const settle = (g1: Geometry) => rememberingSize(fits(g1, image) ? g1 : fitted(g1, image));
  if (ratio == null) {
    const x = furthest(from, { x: target.x, y: from.y });
    const p = furthest(x, { x: x.x, y: target.y });
    return settle(asked(p));
  }
  return settle(asked(furthest(from, target)));
}

/** The straighten tool: a line drawn along a horizon or a vertical. */
export function straightenAngle(a: Point, b: Point, image: Size): number | null {
  const w = Math.max(image.width, 1);
  const h = Math.max(image.height, 1);
  const dx = (b.x - a.x) * w;
  const dy = (b.y - a.y) * h;
  if (Math.hypot(dx, dy) <= 8) return null;
  let deg = (Math.atan2(dy, dx) * 180) / Math.PI;
  if (Math.abs(deg) > 90) deg += deg > 0 ? -180 : 180;
  if (Math.abs(deg) > 45) deg += deg > 0 ? -90 : 90;
  return clamp(deg, -MAX_ANGLE, MAX_ANGLE);
}

/** Decode a sidecar's `geometry` (Swift CGSize is `[w, h]`). */
export function decodeGeometry(raw: unknown): Geometry {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const c = o.crop && typeof o.crop === 'object' ? (o.crop as Record<string, unknown>) : {};
  const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);
  const size = (v: unknown): Size | null =>
    Array.isArray(v) && v.length === 2 && typeof v[0] === 'number' && typeof v[1] === 'number'
      ? { width: v[0], height: v[1] }
      : null;
  return {
    crop: { x: num(c.x, 0), y: num(c.y, 0), width: num(c.width, 1), height: num(c.height, 1) },
    angle: num(o.angle, 0),
    quarterTurns: mod4(num(o.quarterTurns, 0)),
    flipH: o.flipH === true,
    flipV: o.flipV === true,
    aspect: typeof o.aspect === 'string' && o.aspect in TRANSPOSE ? (o.aspect as CropAspect) : 'free',
    intendedSize: size(o.intendedSize),
    lockedRatio: typeof o.lockedRatio === 'number' ? o.lockedRatio : null,
  };
}

/** Encode for the sidecar in the Swift shape. Absent optionals are omitted. */
export function encodeGeometry(g: Geometry): Record<string, unknown> {
  const out: Record<string, unknown> = {
    crop: g.crop,
    angle: g.angle,
    quarterTurns: mod4(g.quarterTurns),
    flipH: g.flipH,
    flipV: g.flipV,
    aspect: g.aspect,
  };
  if (g.intendedSize) out.intendedSize = [g.intendedSize.width, g.intendedSize.height];
  if (g.lockedRatio != null) out.lockedRatio = g.lockedRatio;
  return out;
}
