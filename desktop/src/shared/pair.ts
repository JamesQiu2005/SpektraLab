// HalfFramePair.swift / PairComposer.swift, pinned upstream f1440bd1.
// A pair is a source recipe, not two already-developed pictures joined together.
import { decodeAdjustments, type Adjustments } from './adjustments.ts';
import { clamp, FILM_PARAMS_DEFAULT, FILM_FRAME_CUSTOM, filmFormatMM, type FilmParams } from './params.ts';
import { decodeGeometry, encodeGeometry, GEOMETRY_DEFAULT, outputSize, type Geometry, type Point, type Size } from './geometry.ts';
import { DECODE_DEFAULT, decodeSidecar, type DecodeSettings } from './sidecar.ts';
import type { FileMetadata, PairInfo } from './protocol.ts';
import type { StockCatalog } from './stocks.ts';
import { captureDate, resolveFilmEdgeParams, shootingText } from './filmEdge.ts';

export type PairSide = 'left' | 'right';
export type PairLayer = 'film' | PairSide;
export type PairScope = 'frame' | 'film';
export interface PairRect { x: number; y: number; width: number; height: number }
export interface PairPlacement { scale: number; x: number; y: number; quarterTurns: number }
export const PLACEMENT_DEFAULT: PairPlacement = { scale: 1, x: 0, y: 0, quarterTurns: 0 };
export interface PairPrint { brightnessStops: number; yFilterShift: number; mFilterShift: number; preflashExposure: number }
export interface PairHole {
  path: string; placement: PairPlacement; exposureEV: number; exposureBaselineEV?: number; meteredEV?: number; meteredFor?: string;
  decode: DecodeSettings; geometry: Geometry; autoExposure: boolean; meterMethod?: string | null;
  print?: PairPrint | null; adjustments?: Adjustments | null; printScope: PairScope; exposureScope: PairScope;
}
export interface HalfFramePair { schemaVersion: number; folder: string; left: PairHole | null; right: PairHole | null; spacingMM: number; onStrip: boolean; turned: boolean }
export const PAIR_SIDES: PairSide[] = ['left', 'right'];
export function isPairPath(path: string) { return /\.spektrapair$/i.test(path); }
export const pairSpacing = (p: HalfFramePair) => p.onStrip ? 1 : clamp(p.spacingMM, .5, 2);
export const pairAspect = (p: HalfFramePair) => p.turned ? 4 / 3 : 3 / 4;
export function newPair(folder: string): HalfFramePair { return { schemaVersion: 1, folder, left: null, right: null, spacingMM: 1, onStrip: false, turned: false }; }
export function newHole(path: string): PairHole { return { path, placement: { ...PLACEMENT_DEFAULT }, exposureEV: 0, decode: { ...DECODE_DEFAULT }, geometry: GEOMETRY_DEFAULT, autoExposure: true, printScope: 'film', exposureScope: 'frame' }; }
const obj = (v: unknown): Record<string, unknown> => v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {};
const num = (v: unknown, fallback: number, lo = -Infinity, hi = Infinity) => typeof v === 'number' && Number.isFinite(v) ? clamp(v, lo, hi) : fallback;
export function decodePair(raw: unknown): HalfFramePair | null {
  const p = obj(raw);
  if (typeof p.folder !== 'string' || (p.schemaVersion !== undefined && p.schemaVersion !== 1)) return null;
  function hole(raw: unknown): PairHole | null {
    if (raw == null) return null;
    const h = obj(raw), pl = obj(h.placement), pr = obj(h.print);
    if (typeof h.path !== 'string' || !h.path || isPairPath(h.path)) throw new Error('A half-frame hole must reference a photograph.');
    const out: PairHole = { ...newHole(h.path),
      placement: { scale: num(pl.scale, 1, 1, 4), x: num(pl.x, 0, -1, 1), y: num(pl.y, 0, -1, 1), quarterTurns: ((Math.round(num(pl.quarterTurns, 0)) % 4) + 4) % 4 },
      exposureEV: num(h.exposureEV, 0, -5, 5), decode: decodeSidecar({ decode: h.decode }).decode,
      exposureBaselineEV: num(h.exposureBaselineEV, 0, -64, 64),
      geometry: decodeGeometry(h.geometry), autoExposure: h.autoExposure !== false,
      printScope: h.printScope === 'frame' ? 'frame' : 'film', exposureScope: h.exposureScope === 'film' ? 'film' : 'frame',
    };
    if (typeof h.meteredEV === 'number' && Number.isFinite(h.meteredEV)) out.meteredEV = h.meteredEV;
    if (typeof h.meteredFor === 'string') out.meteredFor = h.meteredFor;
    if (typeof h.meterMethod === 'string') out.meterMethod = h.meterMethod;
    if (h.adjustments) out.adjustments = decodeAdjustments(h.adjustments);
    if (h.print) out.print = { brightnessStops: num(pr.brightnessStops, 0, -3, 3), yFilterShift: num(pr.yFilterShift, 0, -1, 1), mFilterShift: num(pr.mFilterShift, 0, -1, 1), preflashExposure: num(pr.preflashExposure, 0, 0, .03) };
    return out;
  }
  try { return { schemaVersion: 1, folder: p.folder, left: hole(p.left), right: hole(p.right), spacingMM: num(p.spacingMM, 1, .5, 2), onStrip: p.onStrip === true, turned: p.turned === true }; }
  catch { return null; }
}
export function encodePair(p: HalfFramePair): Record<string, unknown> {
  return { ...p, left: p.left ? { ...p.left, geometry: encodeGeometry(p.left.geometry) } : null,
    right: p.right ? { ...p.right, geometry: encodeGeometry(p.right.geometry) } : null };
}
export interface PairLayout { size: Size; hole: Size; advance: number; rects: Record<PairSide, PairRect> }
export function pairLayout(across: number, spacingMM = 1, turned = false): PairLayout {
  const a = Math.max(8, Math.floor(across)), along = Math.max(6, Math.round(a * 18 / 24));
  const advance = Math.round(along * (18 + spacingMM) / 18);
  const hole = turned ? { width: a, height: along } : { width: along, height: a };
  return { hole, advance, size: turned ? { width: hole.width, height: advance + hole.height } : { width: advance + hole.width, height: hole.height },
    rects: { left: { x: 0, y: 0, ...hole }, right: { x: turned ? 0 : advance, y: turned ? advance : 0, ...hole } } };
}
export function pairRects(p: HalfFramePair, across = 2400): Record<PairSide, PairRect> {
  const l = pairLayout(across, pairSpacing(p), p.turned);
  const rect = (r: PairRect) => ({ x: r.x / l.size.width, y: r.y / l.size.height, width: r.width / l.size.width, height: r.height / l.size.height });
  return { left: rect(l.rects.left), right: rect(l.rects.right) };
}
export function placementSourceRect(p: PairPlacement, source: Size, aspect = .75): PairRect {
  let w = source.width, h = source.height;
  if (w <= 0 || h <= 0) return { x: 0, y: 0, width: 0, height: 0 };
  if (w / h > aspect) w = h * aspect; else h = w / aspect;
  const scale = clamp(p.scale, 1, 4); w /= scale; h /= scale;
  const cx = source.width / 2 + clamp(p.x, -1, 1) * (source.width - w) / 2;
  const cy = source.height / 2 + clamp(p.y, -1, 1) * (source.height - h) / 2;
  return { x: cx - w / 2, y: cy - h / 2, width: w, height: h };
}
export const placementTurnedSize = (p: PairPlacement, size: Size): Size => p.quarterTurns % 2 ? { width: size.height, height: size.width } : size;
export function sourcePairLayout(p: HalfFramePair, sizes: Partial<Record<PairSide, Size>>): PairLayout {
  const across: number[] = []; let longest = 0;
  for (const side of PAIR_SIDES) {
    const h = p[side], size = sizes[side]; if (!h || !size) continue;
    const framed = outputSize(h.geometry, size), turned = placementTurnedSize(h.placement, framed);
    const cut = placementSourceRect({ ...h.placement, scale: 1 }, turned, pairAspect(p));
    across.push(p.turned ? cut.width : cut.height); longest = Math.max(longest, framed.width, framed.height);
  }
  let a = across.length ? Math.min(...across) : 2400;
  if (longest > 0) a = Math.min(a, longest / (37 / 24));
  return pairLayout(a, pairSpacing(p), p.turned);
}
export function draggedPlacement(p: PairPlacement, delta: Point, source: Size, aspect = .75): PairPlacement {
  const turned = placementTurnedSize(p, source), cut = placementSourceRect(p, turned, aspect);
  const sx = (turned.width - cut.width) / 2, sy = (turned.height - cut.height) / 2;
  return { ...p, x: sx > .5 ? clamp(p.x - delta.x * cut.width / sx, -1, 1) : p.x,
    y: sy > .5 ? clamp(p.y - delta.y * cut.height / sy, -1, 1) : p.y };
}
export function zoomedPlacement(p: PairPlacement, factor: number, anchor: Point, source: Size, aspect = .75): PairPlacement {
  if (!(factor > 0) || !Number.isFinite(factor)) return p;
  const turned = placementTurnedSize(p, source), was = placementSourceRect(p, turned, aspect), from = clamp(p.scale, 1, 4);
  const scale = clamp(from * factor, 1, 4); if (scale === from || was.width <= 0 || was.height <= 0) return p;
  const w = was.width * from / scale, h = was.height * from / scale;
  const cx = was.x + anchor.x * was.width - anchor.x * w + w / 2, cy = was.y + anchor.y * was.height - anchor.y * h + h / 2;
  const sx = (turned.width - w) / 2, sy = (turned.height - h) / 2;
  return { ...p, scale, x: sx > .5 ? clamp((cx - turned.width / 2) / sx, -1, 1) : 0, y: sy > .5 ? clamp((cy - turned.height / 2) / sy, -1, 1) : 0 };
}
export const printTrim = (p: FilmParams): PairPrint => ({ brightnessStops: p.printBrightnessStops, yFilterShift: p.yFilterShift, mFilterShift: p.mFilterShift, preflashExposure: p.preflashExposure });
/** Wire-only state: the recipe keeps its preflash while the film effect switch
 * bypasses it, exactly like the shared film's print stage. */
export function pairSnapshotFor(pair: HalfFramePair, p: FilmParams): HalfFramePair & { printEffects: boolean } {
  return { ...structuredClone(pair), printEffects: p.printEffects };
}
/** A meter reading is derived data. Placement and manual exposure may change
 * while it runs; source, decode, source geometry and meter intent may not.
 * The opaque native key also checks file identity on a later cold open. */
export function pairWithMeterReadings<T extends HalfFramePair>(live: T, requested: HalfFramePair, info: PairInfo | undefined,
  fallbackMethod: string | null | undefined, requestedMethod = fallbackMethod): T {
  const inputs = (h: PairHole, fallback: string | null | undefined) => JSON.stringify([
    h.path, h.decode, h.geometry, h.meterMethod || fallback || 'balanced',
  ]);
  let result = live;
  for (const side of PAIR_SIDES) {
    const hole = result[side], sent = requested[side], reading = info?.[side];
    if (!hole || !sent || !hole.autoExposure || !sent.autoExposure || !reading?.available
      || !Number.isFinite(reading.metered_ev) || Math.abs(reading.metered_ev!) > 64 || typeof reading.metered_for !== 'string' || !reading.metered_for
      || inputs(hole, fallbackMethod) !== inputs(sent, requestedMethod)) continue;
    if (hole.meteredEV === reading.metered_ev && hole.meteredFor === reading.metered_for) continue;
    result = { ...result, [side]: { ...hole, meteredEV: reading.metered_ev, meteredFor: reading.metered_for } };
  }
  return result;
}
export function pairFitRegion(pair: HalfFramePair, right: boolean): [number, number, number, number] {
  const r = pairRects(pair)[right ? 'right' : 'left'];
  return [r.x, r.y, r.x + r.width, r.y + r.height];
}
export function pairFilmFormat(p: FilmParams, pair: HalfFramePair) {
  return clamp((36 + pairSpacing(pair)) * filmFormatMM(p.filmSide, p.sideLengthMM, 24 / 18, 1) / 24, 4, 200);
}
/** Both preview and immutable export resolve the same physical pair and dates. */
export function resolvePairParams(p: FilmParams, pair: HalfFramePair, first: FileMetadata | null, second: FileMetadata | null, catalog: StockCatalog): FilmParams {
  // Old recipes used the ordinary 135 default for one 18×24 mm half frame.
  // Repair it for offline export as well as the editor's first open.
  if (p.filmFrame === FILM_PARAMS_DEFAULT.filmFrame && p.filmSide === FILM_PARAMS_DEFAULT.filmSide && p.sideLengthMM === FILM_PARAMS_DEFAULT.sideLengthMM)
    p = { ...p, filmFrame: FILM_FRAME_CUSTOM.id, filmSide: 'long', sideLengthMM: 24 };
  const base = resolveFilmEdgeParams(p, GEOMETRY_DEFAULT, first, catalog);
  return { ...base, autoExposure: false, exposureBaselineEV: 0, filmFormatMM: pairFilmFormat(p, pair), pairSplit: .5,
    filmEdge: { ...base.filmEdge, format: '135_half', pair: true },
    dateBack: { ...base.dateBack, camera: '135_half', frameScale: 1, framing: '',
      textB: p.dateBack.face === 'data' ? shootingText(second) : captureDate(second?.datetime_original, p.dateBack.order) } };
}
