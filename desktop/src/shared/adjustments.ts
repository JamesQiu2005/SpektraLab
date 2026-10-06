// adjustments.ts — Layer 2: the scan-side grade (white balance on the scan,
// exposure, curves, colour balance, vignette). A port of
// `Model/Adjustments.swift`, `Model/CurveMath.swift` and the `layer2` kernel
// of `Canvas/Shaders.metal`.
//
// Layer 2 never leaves the app: the canvas runs it in a WebGL2 fragment
// shader (`src/canvas/shaders.ts`), and `applyLayer2` below is the same
// arithmetic on the CPU, for the export path and for the tests that pin the
// two together. Order is fixed:
//
//   white balance → exposure/contrast/brightness → highlights/shadows
//   → black/white point → saturation → colour balance → curves → vignette

import { clamp } from './params';

export interface ColorZone {
  hue: number;
  saturation: number;
  luminance: number;
}
export interface ColorBalance {
  master: ColorZone;
  shadows: ColorZone;
  midtones: ColorZone;
  highlights: ColorZone;
}
export interface Vignette {
  amount: number;
  midpoint: number;
}
export type CurvePoint = [number, number];
export interface Curve {
  points: CurvePoint[];
}
export type CurveChannel = 'rgb' | 'luma' | 'red' | 'green' | 'blue';
export const CURVE_CHANNELS: CurveChannel[] = ['rgb', 'luma', 'red', 'green', 'blue'];
export type CurveSet = Record<CurveChannel, Curve>;

export interface Adjustments {
  enabled: boolean;
  temperature: number;
  tint: number;
  exposure: number;
  contrast: number;
  brightness: number;
  saturation: number;
  highlights: number;
  shadows: number;
  blackPoint: number;
  whitePoint: number;
  curves: CurveSet;
  colorBalance: ColorBalance;
  vignette: Vignette;
}

const ZONE: ColorZone = { hue: 0, saturation: 0, luminance: 0 };
export const CURVE_IDENTITY: Curve = {
  points: [
    [0, 0],
    [1, 1],
  ],
};
export const CURVES_IDENTITY: CurveSet = {
  rgb: CURVE_IDENTITY,
  luma: CURVE_IDENTITY,
  red: CURVE_IDENTITY,
  green: CURVE_IDENTITY,
  blue: CURVE_IDENTITY,
};
export const ADJUSTMENTS_DEFAULT: Adjustments = {
  enabled: true,
  temperature: 0,
  tint: 0,
  exposure: 0,
  contrast: 0,
  brightness: 0,
  saturation: 0,
  highlights: 0,
  shadows: 0,
  blackPoint: 0,
  whitePoint: 0,
  curves: CURVES_IDENTITY,
  colorBalance: { master: ZONE, shadows: ZONE, midtones: ZONE, highlights: ZONE },
  vignette: { amount: 0, midpoint: 50 },
};

export const curveIsIdentity = (c: Curve) =>
  c.points.length === 2 && c.points[0]![0] === 0 && c.points[0]![1] === 0 && c.points[1]![0] === 1 && c.points[1]![1] === 1;
export const curvesIdentity = (s: CurveSet) => CURVE_CHANNELS.every((k) => curveIsIdentity(s[k]));
export const zoneNeutral = (z: ColorZone) => z.saturation === 0 && z.luminance === 0;

export function isNeutral(a: Adjustments): boolean {
  return (
    a.temperature === 0 &&
    a.tint === 0 &&
    a.exposure === 0 &&
    a.contrast === 0 &&
    a.brightness === 0 &&
    a.saturation === 0 &&
    a.highlights === 0 &&
    a.shadows === 0 &&
    a.blackPoint === 0 &&
    a.whitePoint === 0 &&
    curvesIdentity(a.curves) &&
    zoneNeutral(a.colorBalance.master) &&
    zoneNeutral(a.colorBalance.shadows) &&
    zoneNeutral(a.colorBalance.midtones) &&
    zoneNeutral(a.colorBalance.highlights) &&
    a.vignette.amount === 0
  );
}

// ------------------------------------------------------------------ curves

/** Monotone cubic (Fritsch–Carlson), as CurveMath.swift `evaluate`. */
export function evaluateCurve(c: Curve, x: number): number {
  const p = c.points;
  const n = p.length;
  if (n < 2) return x;
  if (x <= p[0]![0]) return p[0]![1];
  if (x >= p[n - 1]![0]) return p[n - 1]![1];
  const d: number[] = [];
  for (let i = 0; i < n - 1; i++) {
    const dx = Math.max(p[i + 1]![0] - p[i]![0], 1e-6);
    d.push((p[i + 1]![1] - p[i]![1]) / dx);
  }
  const m: number[] = new Array(n).fill(0);
  m[0] = d[0]!;
  m[n - 1] = d[n - 2]!;
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1]! * d[i]! <= 0 ? 0 : (d[i - 1]! + d[i]!) / 2;
  for (let i = 0; i < n - 1; i++) {
    if (d[i] === 0) continue;
    const a = m[i]! / d[i]!;
    const b = m[i + 1]! / d[i]!;
    const s = a * a + b * b;
    if (s > 9) {
      const t = 3 / Math.sqrt(s);
      m[i] = t * a * d[i]!;
      m[i + 1] = t * b * d[i]!;
    }
  }
  let i = 0;
  while (i < n - 2 && x > p[i + 1]![0]) i++;
  const h = Math.max(p[i + 1]![0] - p[i]![0], 1e-6);
  const t = (x - p[i]![0]) / h;
  const t2 = t * t;
  const t3 = t2 * t;
  const y =
    (2 * t3 - 3 * t2 + 1) * p[i]![1] +
    (t3 - 2 * t2 + t) * h * m[i]! +
    (-2 * t3 + 3 * t2) * p[i + 1]![1] +
    (t3 - t2) * h * m[i + 1]!;
  return clamp(y, 0, 1);
}

export const CURVE_TABLE_SIZE = 256;

/** Five rows of 256: rgb, luma, red, green, blue (the shader's layout). */
export function curveTables(s: CurveSet): Float32Array {
  const out = new Float32Array(CURVE_TABLE_SIZE * 5);
  CURVE_CHANNELS.forEach((ch, row) => {
    for (let i = 0; i < CURVE_TABLE_SIZE; i++) out[row * CURVE_TABLE_SIZE + i] = evaluateCurve(s[ch], i / (CURVE_TABLE_SIZE - 1));
  });
  return out;
}

export function insertPoint(c: Curve, x: number, y: number): { curve: Curve; index: number } {
  const q: CurvePoint = [clamp(x, 0, 1), clamp(y, 0, 1)];
  let i = c.points.findIndex((p) => p[0] > q[0]);
  if (i < 0) i = c.points.length;
  const points = [...c.points.slice(0, i), q, ...c.points.slice(i)];
  return { curve: { points }, index: i };
}

export function movePoint(c: Curve, i: number, x: number, y: number): Curve {
  if (i < 0 || i >= c.points.length) return c;
  const points = c.points.map((p) => [p[0], p[1]] as CurvePoint);
  let qx = clamp(x, 0, 1);
  const qy = clamp(y, 0, 1);
  if (i === 0) qx = 0;
  else if (i === points.length - 1) qx = 1;
  else {
    const lo = points[i - 1]![0] + 0.01;
    const hi = points[i + 1]![0] - 0.01;
    qx = clamp(qx, Math.min(lo, hi), Math.max(lo, hi));
  }
  points[i] = [qx, qy];
  return { points };
}

export function removePoint(c: Curve, i: number): Curve {
  if (c.points.length <= 2 || i <= 0 || i >= c.points.length - 1) return c;
  return { points: c.points.filter((_, j) => j !== i) };
}

// ---------------------------------------------------------------- uniforms

/** `pow(0.18, 1/1.8)` — mid-grey through ROMM γ1.8 (RFC-018 D1). */
export const PROPHOTO_MID_GREY = 0.3857;
/** The same through the sRGB curve — what the canvas's sRGB frame carries. */
export const SRGB_MID_GREY = 0.4614;

export interface Layer2Uniforms {
  wbGain: [number, number, number];
  exposureGain: number;
  contrast: number;
  brightness: number;
  saturation: number;
  highlights: number;
  shadows: number;
  blackPoint: number;
  whitePoint: number;
  cbMaster: [number, number, number];
  cbShadows: [number, number, number];
  cbMidtones: [number, number, number];
  cbHighlights: [number, number, number];
  cbLum: [number, number, number, number];
  vignetteAmount: number;
  vignetteMidpoint: number;
  midGrey: number;
  curvesActive: boolean;
  enabled: boolean;
}

function zoneOffset(z: ColorZone): [number, number, number] {
  const h = (z.hue * Math.PI) / 180;
  const s = z.saturation * 0.25;
  return [Math.cos(h) * s, Math.cos(h - (2 * Math.PI) / 3) * s, Math.cos(h + (2 * Math.PI) / 3) * s];
}

/**
 * The per-frame uniform block. `midGrey` follows the encoding of the pixels
 * the grade runs on: the canvas shows sRGB-encoded frames (the host's
 * `display: "srgb"`), an export grades the recipe's space.
 */
export function layer2Uniforms(a: Adjustments, midGrey = SRGB_MID_GREY): Layer2Uniforms {
  const t = a.temperature / 100;
  const g = a.tint / 100;
  const cb = a.colorBalance;
  return {
    wbGain: [1 + 0.18 * t, 1 - 0.12 * g, 1 - 0.18 * t],
    exposureGain: Math.pow(2, a.exposure),
    contrast: a.contrast / 100,
    brightness: a.brightness / 100,
    saturation: 1 + a.saturation / 100,
    highlights: a.highlights / 100,
    shadows: a.shadows / 100,
    blackPoint: a.blackPoint / 100,
    whitePoint: a.whitePoint / 100,
    cbMaster: zoneOffset(cb.master),
    cbShadows: zoneOffset(cb.shadows),
    cbMidtones: zoneOffset(cb.midtones),
    cbHighlights: zoneOffset(cb.highlights),
    cbLum: [cb.master.luminance * 0.25, cb.shadows.luminance * 0.25, cb.midtones.luminance * 0.25, cb.highlights.luminance * 0.25],
    vignetteAmount: a.vignette.amount / 100,
    vignetteMidpoint: a.vignette.midpoint / 100,
    midGrey,
    curvesActive: !curvesIdentity(a.curves),
    enabled: a.enabled,
  };
}

const luma = (r: number, g: number, b: number) => 0.2126 * r + 0.7152 * g + 0.0722 * b;
const sat = (v: number) => clamp(v, 0, 1);

export function tonePosition(l: number, midGrey: number): number {
  let m = sat(midGrey);
  if (m <= 0 || m >= 1) m = 0.5;
  return l <= m ? (0.5 * l) / m : 0.5 + (0.5 * (l - m)) / (1 - m);
}

/** `layer2Tone` — steps 1–6. In/out: one pixel, encoded 0…1. */
export function layer2Tone(c: [number, number, number], u: Layer2Uniforms): [number, number, number] {
  let [r, g, b] = c;
  r *= u.wbGain[0];
  g *= u.wbGain[1];
  b *= u.wbGain[2];
  if (u.exposureGain !== 1) {
    r = Math.pow(Math.pow(Math.max(r, 0), 2.2) * u.exposureGain, 1 / 2.2);
    g = Math.pow(Math.pow(Math.max(g, 0), 2.2) * u.exposureGain, 1 / 2.2);
    b = Math.pow(Math.pow(Math.max(b, 0), 2.2) * u.exposureGain, 1 / 2.2);
  }
  if (u.contrast !== 0) {
    const k = 1 + u.contrast * 1.2;
    r = (r - u.midGrey) * k + u.midGrey;
    g = (g - u.midGrey) * k + u.midGrey;
    b = (b - u.midGrey) * k + u.midGrey;
  }
  if (u.brightness !== 0) {
    const e = 1 / (1 + u.brightness * 0.8);
    r = Math.pow(Math.max(r, 0), e);
    g = Math.pow(Math.max(g, 0), e);
    b = Math.pow(Math.max(b, 0), e);
  }
  let l = tonePosition(luma(r, g, b), u.midGrey);
  if (u.shadows !== 0) {
    let w = 1 - l;
    w = w * w;
    r += u.shadows * 0.25 * w * (1 - r);
    g += u.shadows * 0.25 * w * (1 - g);
    b += u.shadows * 0.25 * w * (1 - b);
  }
  if (u.highlights !== 0) {
    const w = l * l;
    const k = u.highlights * 0.25 * w;
    if (u.highlights > 0) {
      r += k * (1 - r);
      g += k * (1 - g);
      b += k * (1 - b);
    } else {
      r += k * r;
      g += k * g;
      b += k * b;
    }
  }
  const span = Math.max(1 - u.blackPoint - u.whitePoint, 0.05);
  r = (r - u.blackPoint) / span;
  g = (g - u.blackPoint) / span;
  b = (b - u.blackPoint) / span;
  l = luma(r, g, b);
  r = l + (r - l) * u.saturation;
  g = l + (g - l) * u.saturation;
  b = l + (b - l) * u.saturation;
  const ls = sat(tonePosition(l, u.midGrey));
  const wS = (1 - ls) * (1 - ls);
  const wH = ls * ls;
  const wM = Math.max(1 - wS - wH, 0);
  const off = (i: 0 | 1 | 2) => u.cbMaster[i] + u.cbShadows[i] * wS + u.cbMidtones[i] * wM + u.cbHighlights[i] * wH;
  const lum = 1 + u.cbLum[0] + u.cbLum[1] * wS + u.cbLum[2] * wM + u.cbLum[3] * wH;
  return [(r + off(0)) * lum, (g + off(1)) * lum, (b + off(2)) * lum];
}

function lookup(tables: Float32Array, x: number, row: number): number {
  // Linear between table entries, clamped — the shader's linear sampler.
  const n = CURVE_TABLE_SIZE;
  const f = sat(x) * (n - 1);
  const i = Math.floor(f);
  const j = Math.min(i + 1, n - 1);
  const t = f - i;
  return tables[row * n + i]! * (1 - t) + tables[row * n + j]! * t;
}

function smoothstep(e0: number, e1: number, x: number) {
  const t = sat((x - e0) / (e1 - e0));
  return t * t * (3 - 2 * t);
}

/**
 * One pixel through the whole layer (steps 1–9), `suv` its place on the
 * *print* (the vignette is the print's, before geometry — as the canvas
 * shader and the Mac's `layer2` kernel do).
 */
export function layer2Pixel(
  rgb: [number, number, number],
  u: Layer2Uniforms,
  tables: Float32Array | null,
  sx: number,
  sy: number,
): [number, number, number] {
  if (!u.enabled) return rgb;
  let [r, g, b] = layer2Tone(rgb, u);
  if (tables) {
    r = sat(r);
    g = sat(g);
    b = sat(b);
    const ly = luma(r, g, b);
    const ly2 = lookup(tables, ly, 1);
    const k = ly > 1e-4 ? ly2 / ly : 1;
    r = sat(r * k);
    g = sat(g * k);
    b = sat(b * k);
    r = lookup(tables, r, 0);
    g = lookup(tables, g, 0);
    b = lookup(tables, b, 0);
    r = lookup(tables, r, 2);
    g = lookup(tables, g, 3);
    b = lookup(tables, b, 4);
  }
  if (u.vignetteAmount !== 0) {
    const d = Math.hypot((sx - 0.5) * 2, (sy - 0.5) * 2);
    const fall = smoothstep(u.vignetteMidpoint * 1.2, 1.5, d);
    const k = 1 + u.vignetteAmount * fall * 0.9;
    r *= k;
    g *= k;
    b *= k;
  }
  return [sat(r), sat(g), sat(b)];
}

/** The whole layer on an RGBA float buffer (0…1), in place — a print, before geometry. */
export function applyLayer2(data: Float32Array, width: number, height: number, a: Adjustments, midGrey: number): void {
  const u = layer2Uniforms(a, midGrey);
  if (!u.enabled) return;
  const tables = u.curvesActive ? curveTables(a.curves) : null;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      const [r, g, b] = layer2Pixel([data[i]!, data[i + 1]!, data[i + 2]!], u, tables, (x + 0.5) / width, (y + 0.5) / height);
      data[i] = r;
      data[i + 1] = g;
      data[i + 2] = b;
    }
  }
}

function obj(v: unknown): Record<string, unknown> {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}
const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

function decodeCurve(v: unknown): Curve {
  const pts = obj(v).points;
  if (!Array.isArray(pts) || pts.length < 2) return CURVE_IDENTITY;
  const points: CurvePoint[] = [];
  for (const p of pts) {
    // Swift encodes CGPoint as [x, y]; accept {x, y} too.
    if (Array.isArray(p) && p.length === 2) points.push([num(p[0], 0), num(p[1], 0)]);
    else if (p && typeof p === 'object') points.push([num((p as Record<string, unknown>).x, 0), num((p as Record<string, unknown>).y, 0)]);
  }
  return points.length >= 2 ? { points } : CURVE_IDENTITY;
}

function decodeZone(v: unknown): ColorZone {
  const o = obj(v);
  return { hue: num(o.hue, 0), saturation: num(o.saturation, 0), luminance: num(o.luminance, 0) };
}

export function decodeAdjustments(raw: unknown): Adjustments {
  const o = obj(raw);
  const d = ADJUSTMENTS_DEFAULT;
  const c = obj(o.curves);
  const cb = obj(o.colorBalance);
  const v = obj(o.vignette);
  return {
    enabled: typeof o.enabled === 'boolean' ? o.enabled : true,
    temperature: num(o.temperature, d.temperature),
    tint: num(o.tint, d.tint),
    exposure: num(o.exposure, d.exposure),
    contrast: num(o.contrast, d.contrast),
    brightness: num(o.brightness, d.brightness),
    saturation: num(o.saturation, d.saturation),
    highlights: num(o.highlights, d.highlights),
    shadows: num(o.shadows, d.shadows),
    blackPoint: num(o.blackPoint, d.blackPoint),
    whitePoint: num(o.whitePoint, d.whitePoint),
    curves: {
      rgb: decodeCurve(c.rgb),
      luma: decodeCurve(c.luma),
      red: decodeCurve(c.red),
      green: decodeCurve(c.green),
      blue: decodeCurve(c.blue),
    },
    colorBalance: {
      master: decodeZone(cb.master),
      shadows: decodeZone(cb.shadows),
      midtones: decodeZone(cb.midtones),
      highlights: decodeZone(cb.highlights),
    },
    vignette: { amount: num(v.amount, 0), midpoint: num(v.midpoint, 50) },
  };
}
