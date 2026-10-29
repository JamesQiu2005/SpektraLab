// params.ts — Layer 1: the engine's parameters as the interface holds them.
// A port of `Model/Params.swift` (FilmParams) with the same two rules:
//
// 1. Wire names are the host's `params_schema` names. `wire()` produces
//    exactly the `set_params` delta the host validates, nothing else;
//    `params.test.ts` pins every name against the schema the mock host
//    carries, which is extracted from `engine/src/core/params.cpp`.
// 2. Every field knows its layer (`shoot` / `print`): a print-only delta is a
//    reprint (API-SPEC §2), anything shoot-side is a re-render.
//
// The JSON keys of `FilmParams` are the Swift `Codable` keys, so a sidecar
// written by the macOS app opens here and the other way round.

import type { StockCatalog } from './stocks.ts';
import { dateCamera, dateEffective, datePrints, dateScale, edgeEffective, filmFormatForWire } from './filmEdge.ts';

export type ParamLayer = 'shoot' | 'print';
export type WireValue = number | boolean | string;
export interface WireField {
  name: string;
  value: WireValue;
  layer: ParamLayer;
}

export const clamp = (v: number, lo: number, hi: number) => (v < lo ? lo : v > hi ? hi : v);

// ---------------------------------------------------------------- film frame

export interface FilmFrame {
  id: string;
  short: number;
  long: number;
  isCine: boolean;
}

export const FILM_FRAMES_CINE: FilmFrame[] = [
  { id: 'Super 8', short: 4.01, long: 5.79, isCine: true },
  { id: '16mm', short: 7.49, long: 10.26, isCine: true },
  { id: 'Super 16', short: 7.41, long: 12.52, isCine: true },
  { id: 'Super 35', short: 14.0, long: 24.89, isCine: true },
  { id: '65mm', short: 23.01, long: 52.63, isCine: true },
];
export const FILM_FRAME_CUSTOM: FilmFrame = { id: 'Custom', short: 24, long: 36, isCine: false };
export const FILM_FRAMES_STILL: FilmFrame[] = [
  { id: '110', short: 13, long: 17, isCine: false },
  { id: 'APS', short: 16.7, long: 30.2, isCine: false },
  { id: '135', short: 24, long: 36, isCine: false },
  { id: '120', short: 56, long: 56, isCine: false },
  FILM_FRAME_CUSTOM,
];
export const FILM_FRAMES: FilmFrame[] = [...FILM_FRAMES_CINE, ...FILM_FRAMES_STILL];
export const filmFrameNamed = (id: string) => FILM_FRAMES.find((f) => f.id === id) ?? FILM_FRAME_CUSTOM;

export type FilmSide = 'short' | 'long';
export type SideUnit = 'mm' | 'cm' | 'inch';
export const SIDE_UNIT_PER_MM: Record<SideUnit, number> = { mm: 1, cm: 10, inch: 25.4 };
export const SIDE_UNIT_DECIMALS: Record<SideUnit, number> = { mm: 1, cm: 2, inch: 3 };

/**
 * `Session.filmFormatMM(side:sideLengthMM:aspect:cropScale:)`: the frame's long
 * edge, from a side, its length and the photograph's own aspect (≥ 1).
 */
export function filmFormatMM(side: FilmSide, sideLengthMM: number, aspect: number, cropScale = 1): number {
  const long = side === 'long' ? sideLengthMM : sideLengthMM * Math.max(aspect, 1);
  return clamp(long * Math.max(cropScale, 1), 4, 200);
}

// ----------------------------------------------------------- exposure method

export const EXPOSURE_METHODS = ['balanced', 'center', 'protect_highlights', 'protect_shadows'] as const;
export type ExposureMethod = (typeof EXPOSURE_METHODS)[number];
/** The AE Method pill: `custom` is the meter switched off, not a fifth meter. */
export type AEMethod = 'custom' | ExposureMethod | 'legacy';

export function aeMethodOf(p: FilmParams): AEMethod {
  if (!p.autoExposure) return 'custom';
  if (p.autoExposureMethod == null) return 'legacy';
  return (EXPOSURE_METHODS as readonly string[]).includes(p.autoExposureMethod)
    ? (p.autoExposureMethod as ExposureMethod)
    : 'legacy';
}

export function applyAEMethod(p: FilmParams, m: AEMethod): FilmParams {
  if (m === 'custom') return { ...p, autoExposure: false };
  if (m === 'legacy') return { ...p, autoExposure: true, autoExposureMethod: null };
  return { ...p, autoExposure: true, autoExposureMethod: m };
}

// -------------------------------------------------------- nested settings

export interface ContrastMaskSettings {
  active: boolean;
  highlights: number;
  shadows: number;
  core: number;
  scale: number;
  scheme: string;
}
export const CONTRAST_MASK_DEFAULT: ContrastMaskSettings = {
  active: false,
  highlights: 0,
  shadows: 0,
  core: 1,
  scale: 0.03,
  scheme: 'gaussian',
};
export const CONTRAST_MASK_SCALE: [number, number] = [0.002, 0.12];

export interface SceneLatitudeSettings {
  highlightPullBack: number;
  shadowPullBack: number;
  shadowPercentile: number;
  highlightPercentile: number;
  active: boolean;
  norm: string;
  highlightKnee: number;
  highlightRoom: number;
  shadowKnee: number;
  shadowRoom: number;
  rolloff: number;
  maxLift: number;
}
export const SCENE_LATITUDE_DEFAULT: SceneLatitudeSettings = {
  highlightPullBack: 0,
  shadowPullBack: 0,
  shadowPercentile: 0.1,
  highlightPercentile: 99.9,
  active: false,
  norm: 'power',
  highlightKnee: 2,
  highlightRoom: 0,
  shadowKnee: -2,
  shadowRoom: 0,
  rolloff: 2,
  maxLift: 4,
};

export interface EffectStrengths {
  grain: number;
  grainLayered: boolean;
  halation: number;
  antihalationRemoved: boolean;
  highlightBoost: number;
  /** `halation_headroom_ev` (1.3.4): the stops a clipped highlight is given back, on a film with no
   * anti-halation layer (CineStill 800T) only; every other film ignores it. 0…8 EV, 4 the engine default. */
  highlightHeadroom: number;
  scatter: number;
  couplersActive: boolean;
  couplers: number;
  glare: number;
}
export const EFFECTS_DEFAULT: EffectStrengths = {
  grain: 1,
  grainLayered: true,
  halation: 1,
  antihalationRemoved: false,
  highlightBoost: 0,
  highlightHeadroom: 4,
  scatter: 1,
  couplersActive: true,
  couplers: 1,
  glare: 1,
};
export const EFFECT_RANGES = {
  grain: [0, 2],
  halation: [0, 4],
  scatter: [0, 1],
  highlightBoost: [0, 8],
  highlightHeadroom: [0, 8],
  // Not the wire's 0…4: above ≈1.736 the coupler inverse is not monotonic
  // (AGENTS.md trap 22), so the slider stops short of it.
  couplers: [0, 1.5],
  glare: [0, 30],
} as const satisfies Record<string, readonly [number, number]>;

export const FILM_EDGE_FORMATS = [
  '135',
  '135_half',
  '135_xpan',
  '120_645',
  '120_6x6',
  '120_6x7',
  '120_6x8',
  '120_6x9',
  '120_6x12',
  '120_6x17',
] as const;
export type FilmEdgeFormat = (typeof FILM_EDGE_FORMATS)[number];

export interface FilmEdgeSettings {
  active: boolean;
  format: string;
  view: string;
  gate: string;
  holes: string;
  cameraSeed: number;
  frameSeed: number;
  frameNumber: number;
  fog: number;
  leaks: number;
  edgeText: string;
  fNumber: number;
  framing: string;
  pair: boolean;
  seeded: boolean;
}
export const FILM_EDGE_DEFAULT: FilmEdgeSettings = {
  active: false,
  format: '135',
  view: 'strip',
  gate: 'auto',
  holes: 'white',
  cameraSeed: 1,
  frameSeed: 1,
  frameNumber: 0,
  fog: 1,
  leaks: 0,
  edgeText: '',
  fNumber: 0,
  framing: '',
  pair: false,
  seeded: false,
};

export interface DateBackSettings {
  active: boolean;
  face: string;
  order: string;
  placement: string;
  corner: string;
  insetXMM: number;
  insetYMM: number;
  size: number;
  brightnessEV: number;
  text: string;
  textB: string;
  withData: boolean;
  dataText: string;
  customText?: string | null;
  camera?: string | null;
  framing: string;
  frameScale: number;
}
export const DATE_BACK_DEFAULT: DateBackSettings = {
  active: false,
  face: 'lcd',
  order: 'japan',
  placement: 'frame',
  corner: 'br',
  insetXMM: 3,
  insetYMM: 2.4,
  size: 1,
  brightnessEV: 3.5,
  text: '',
  textB: '',
  withData: false,
  dataText: '',
  customText: null,
  camera: '135',
  framing: '',
  frameScale: 1,
};

// ------------------------------------------------------------- FilmParams

export interface FilmParams {
  filmStock: string;
  printStock: string;
  exposureCompensationEV: number;
  exposureBaselineEV: number;
  /** `null` = a legacy sidecar: send no method, the engine keeps its own. */
  autoExposureMethod: string | null;
  autoExposure: boolean;
  filmFormatMM: number;
  filmFrame: string;
  filmSide: FilmSide;
  sideLengthMM: number;
  grainActive: boolean;
  halationActive: boolean;
  printBrightnessStops: number;
  yFilterShift: number;
  mFilterShift: number;
  glareActive: boolean;
  scanFilm: boolean;
  digitalIntermediate: boolean;
  extendedDynamicRange: boolean;
  preflashExposure: number;
  contrastMask: ContrastMaskSettings;
  sceneLatitude: SceneLatitudeSettings;
  sceneLatitudeOther: SceneLatitudeSettings;
  placementIsRight: boolean;
  pairSplit: number;
  effects: EffectStrengths;
  printEffects: boolean;
  filmEdge: FilmEdgeSettings;
  dateBack: DateBackSettings;
}

export const FILM_PARAMS_DEFAULT: FilmParams = {
  filmStock: 'kodak_portra_400',
  printStock: 'kodak_supra_endura',
  exposureCompensationEV: 0,
  exposureBaselineEV: 0,
  autoExposureMethod: 'balanced',
  autoExposure: true,
  filmFormatMM: 36,
  filmFrame: '135',
  filmSide: 'short',
  sideLengthMM: 24,
  grainActive: true,
  halationActive: true,
  printBrightnessStops: 0,
  yFilterShift: 0,
  mFilterShift: 0,
  glareActive: true,
  scanFilm: false,
  digitalIntermediate: false,
  extendedDynamicRange: false,
  preflashExposure: 0,
  contrastMask: CONTRAST_MASK_DEFAULT,
  sceneLatitude: SCENE_LATITUDE_DEFAULT,
  sceneLatitudeOther: SCENE_LATITUDE_DEFAULT,
  placementIsRight: false,
  pairSplit: 0,
  effects: EFFECTS_DEFAULT,
  printEffects: true,
  filmEdge: FILM_EDGE_DEFAULT,
  dateBack: DATE_BACK_DEFAULT,
};

/** What the Yellow / Magenta sliders' ends are, in CC (`filter_shift_scale`). */
export const FILTER_SHIFT_CC = 40;

/** UI stops (brighter positive) → the wire's `print_exposure`. */
export const printExposure = (stops: number) => clamp(Math.pow(2, -stops), 0.05, 20);

/** Fields written onto a live pipeline without a rebuild (informational). */
export const LIVE_MUTABLE = new Set([
  'print_exposure',
  'm_filter_shift',
  'y_filter_shift',
  'preflash_exposure',
  'filter_shift_scale',
]);

function obj(v: unknown): Record<string, unknown> {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

/** Decode a nested settings object key by key: absent or mistyped → default. */
function decodeShape<T extends object>(raw: unknown, d: T): T {
  const o = obj(raw);
  const out: Record<string, unknown> = { ...(d as Record<string, unknown>) };
  for (const k of Object.keys(d)) {
    const v = o[k];
    const dv = (d as Record<string, unknown>)[k];
    if (v === undefined) continue;
    if (dv === null || dv === undefined) {
      if (v === null || typeof v === 'string' || typeof v === 'number') out[k] = v;
    } else if (typeof v === typeof dv) out[k] = v;
  }
  return out as T;
}

/**
 * A sidecar's `params` → FilmParams. Tolerant where Swift is tolerant (newer
 * fields default when absent); a missing `autoExposureMethod` stays `null`,
 * which is the legacy wire state (see Params.swift).
 */
export function decodeFilmParams(raw: unknown): FilmParams {
  const o = obj(raw);
  const base = decodeShape(o, FILM_PARAMS_DEFAULT);
  base.autoExposureMethod =
    'autoExposureMethod' in o ? (typeof o.autoExposureMethod === 'string' ? o.autoExposureMethod : null) : null;
  if (!('filmStock' in o)) base.autoExposureMethod = FILM_PARAMS_DEFAULT.autoExposureMethod;
  base.filmSide = base.filmSide === 'long' ? 'long' : 'short';
  base.contrastMask = decodeShape(o.contrastMask, CONTRAST_MASK_DEFAULT);
  base.sceneLatitude = decodeShape(o.sceneLatitude, SCENE_LATITUDE_DEFAULT);
  base.sceneLatitudeOther = decodeShape(o.sceneLatitudeOther, SCENE_LATITUDE_DEFAULT);
  base.effects = decodeShape(o.effects, EFFECTS_DEFAULT);
  base.filmEdge = decodeShape(o.filmEdge, FILM_EDGE_DEFAULT);
  base.dateBack = decodeShape(o.dateBack, DATE_BACK_DEFAULT);
  if (o.filmEdge && !('seeded' in obj(o.filmEdge))) base.filmEdge.seeded = 'frameSeed' in obj(o.filmEdge);
  return base;
}

/** Features the host may refuse (`capabilities.backend.unsupported_features`). */
export interface FeatureGate {
  /** Decoded source through Layer 2, explicitly advertised by the host. */
  noFilm: boolean;
  digitalIntermediate: boolean;
  sceneLatitude: boolean;
  contrastMask: boolean;
  overscan: boolean;
  dateImprint: boolean;
  /** Settings ▸ Rendering: RFC-028 §10 blue compensation. */
  diBlueCompensation: boolean;
  /** FeatureFlags.toneMask on macOS: withdrawn, so never on the wire. */
  toneMask: boolean;
}
export const ALL_FEATURES: FeatureGate = {
  noFilm: true,
  digitalIntermediate: true,
  sceneLatitude: true,
  contrastMask: true,
  overscan: true,
  dateImprint: true,
  diBlueCompensation: false,
  toneMask: false,
};

export function featureGate(unsupported: readonly string[] | undefined, diBlue = false, noFilm = false): FeatureGate {
  const u = new Set(unsupported ?? []);
  return {
    noFilm,
    digitalIntermediate: !u.has('digital_intermediate'),
    sceneLatitude: !u.has('scene_latitude_mapping'),
    contrastMask: !u.has('contrast_mask'),
    overscan: !u.has('overscan'),
    dateImprint: !u.has('date_imprint'),
    diBlueCompensation: diBlue,
    toneMask: false,
  };
}

export function effectiveEDR(p: FilmParams, catalog?: StockCatalog): boolean {
  return p.extendedDynamicRange && !p.scanFilm && !p.digitalIntermediate && !catalog?.isMonochrome(p.printStock);
}

/** Repair viewing-stage/paper compatibility at every editor and batch entry.
 * Saved preferences (EDR, layered grain, exposure and direct scan) survive;
 * their effective values are derived only when the wire is built. */
export function normalizeStockPair(p: FilmParams, catalog: StockCatalog): FilmParams {
  const scanFilm = p.scanFilm || catalog.isPositive(p.filmStock);
  let printStock = p.printStock;
  if (!catalog.canPrint(p.filmStock, printStock)) {
    const target = catalog.stock(p.filmStock)?.targetPrint;
    const defaultPaper = FILM_PARAMS_DEFAULT.printStock;
    const replacement = target && catalog.stock(target) && catalog.canPrint(p.filmStock, target)
      ? target : catalog.stock(defaultPaper) && catalog.canPrint(p.filmStock, defaultPaper)
        ? defaultPaper : catalog.papers.find((paper) => catalog.canPrint(p.filmStock, paper.id))?.id;
    if (replacement) printStock = replacement;
  }
  return scanFilm === p.scanFilm && printStock === p.printStock ? p : { ...p, scanFilm, printStock };
}

/** Upstream 1.3.3's per-film RMS grain calibration; the UI strength multiplies it. */
export function ownGrain(stock: string): number {
  switch (stock) {
    case 'kodak_tri_x_400': return 1.70;
    case 'ilford_hp5_plus_400': return 1.49;
    case 'kodak_tmax_100': return 0.74;
    case 'fujifilm_neopan_acros_100_ii': return 0.64;
    default: return 1;
  }
}

export function digitalIntermediateActive(p: FilmParams, filmIsPositive: boolean): boolean {
  return p.digitalIntermediate && !p.scanFilm && !filmIsPositive;
}

/**
 * Every wire field, in a stable order (the Swift `wire`). Features the host
 * cannot do are sent in their off state, so an unported feature in a sidecar
 * from the Mac never makes the host refuse the whole delta; the setting itself
 * stays in the sidecar.
 */
export function wire(p: FilmParams, gate: FeatureGate = ALL_FEATURES, catalog?: StockCatalog): WireField[] {
  const di = gate.digitalIntermediate && p.digitalIntermediate;
  const placement = p.placementIsRight ? p.sceneLatitudeOther : p.sceneLatitude;
  const f: WireField[] = [
    { name: 'film_stock', value: p.filmStock, layer: 'shoot' },
    { name: 'print_stock', value: p.printStock, layer: 'print' },
    { name: 'exposure_compensation_ev', value: p.exposureCompensationEV, layer: 'shoot' },
    { name: 'exposure_baseline_ev', value: p.exposureBaselineEV, layer: 'shoot' },
  ];
  if (p.autoExposureMethod != null) f.push({ name: 'auto_exposure_method', value: p.autoExposureMethod, layer: 'shoot' });
  f.push(
    { name: 'auto_exposure', value: p.autoExposure, layer: 'shoot' },
    { name: 'film_format_mm', value: clamp(filmFormatForWire(p, gate), 4, 200), layer: 'shoot' },
    { name: 'grain_active', value: p.grainActive, layer: 'shoot' },
    { name: 'grain_sublayers_active', value: p.grainActive && p.effects.grainLayered && !catalog?.isMonochrome(p.filmStock), layer: 'shoot' },
    { name: 'halation_active', value: p.halationActive, layer: 'shoot' },
    { name: 'print_exposure', value: printExposure(p.printBrightnessStops), layer: 'print' },
    { name: 'y_filter_shift', value: clamp(p.yFilterShift, -1, 1), layer: 'print' },
    { name: 'm_filter_shift', value: clamp(p.mFilterShift, -1, 1), layer: 'print' },
    { name: 'filter_shift_scale', value: FILTER_SHIFT_CC, layer: 'print' },
    { name: 'glare_active', value: p.glareActive && p.printEffects, layer: 'print' },
    { name: 'scan_film', value: p.scanFilm, layer: 'print' },
    { name: 'extended_dynamic_range', value: effectiveEDR(p, catalog), layer: 'print' },
    { name: 'preflash_exposure', value: p.printEffects ? clamp(p.preflashExposure, 0, 1) : 0, layer: 'print' },
  );
  if (gate.contrastMask) {
    f.push(
      {
        name: 'contrast_mask_active',
        value: p.contrastMask.active && p.printEffects && gate.toneMask,
        layer: 'print',
      },
      { name: 'contrast_mask_highlights', value: p.contrastMask.highlights, layer: 'print' },
      { name: 'contrast_mask_shadows', value: p.contrastMask.shadows, layer: 'print' },
      { name: 'contrast_mask_core', value: p.contrastMask.core, layer: 'print' },
      {
        name: 'contrast_mask_scale',
        value: clamp(p.contrastMask.scale, CONTRAST_MASK_SCALE[0], CONTRAST_MASK_SCALE[1]),
        layer: 'print',
      },
      { name: 'contrast_mask_scheme', value: p.contrastMask.scheme, layer: 'print' },
    );
  }
  if (gate.sceneLatitude) {
    f.push(
      { name: 'scene_latitude_active', value: placement.active && !(di && !p.scanFilm), layer: 'shoot' },
      { name: 'scene_latitude_norm', value: placement.norm, layer: 'shoot' },
      { name: 'scene_latitude_highlight_knee', value: placement.highlightKnee, layer: 'shoot' },
      { name: 'scene_latitude_highlight_room', value: placement.highlightRoom, layer: 'shoot' },
      { name: 'scene_latitude_shadow_knee', value: placement.shadowKnee, layer: 'shoot' },
      { name: 'scene_latitude_shadow_room', value: placement.shadowRoom, layer: 'shoot' },
      { name: 'scene_latitude_rolloff', value: placement.rolloff, layer: 'shoot' },
      { name: 'scene_latitude_max_lift', value: placement.maxLift, layer: 'shoot' },
      { name: 'scene_latitude_split', value: p.filmEdge.pair ? clamp(p.pairSplit, 0, 1) : 0, layer: 'shoot' },
    );
    if (p.filmEdge.pair) {
      const second = p.placementIsRight ? p.sceneLatitude : p.sceneLatitudeOther;
      f.push(
        { name: 'scene_latitude_b_active', value: second.active && !(di && !p.scanFilm), layer: 'shoot' },
        { name: 'scene_latitude_b_highlight_knee', value: second.highlightKnee, layer: 'shoot' },
        { name: 'scene_latitude_b_highlight_room', value: second.highlightRoom, layer: 'shoot' },
        { name: 'scene_latitude_b_shadow_knee', value: second.shadowKnee, layer: 'shoot' },
        { name: 'scene_latitude_b_shadow_room', value: second.shadowRoom, layer: 'shoot' },
      );
    }
  }
  const e = p.effects;
  const r = EFFECT_RANGES;
  f.push(
    { name: 'halation_amount', value: clamp(e.halation, r.halation[0], r.halation[1]), layer: 'shoot' },
    { name: 'halation_scatter_amount', value: clamp(e.scatter, r.scatter[0], r.scatter[1]), layer: 'shoot' },
    { name: 'grain_amount', value: clamp(e.grain * ownGrain(p.filmStock), r.grain[0], r.grain[1]), layer: 'shoot' },
    { name: 'dir_couplers_active', value: e.couplersActive, layer: 'shoot' },
    { name: 'dir_couplers_amount', value: clamp(e.couplers, r.couplers[0], r.couplers[1]), layer: 'shoot' },
    { name: 'glare_amount', value: clamp(e.glare, r.glare[0], r.glare[1]), layer: 'print' },
    { name: 'antihalation_removed', value: e.antihalationRemoved, layer: 'shoot' },
    { name: 'halation_boost_ev', value: clamp(e.highlightBoost, r.highlightBoost[0], r.highlightBoost[1]), layer: 'shoot' },
    // 1.3.4 (API-SPEC §18): sent always; every film with an anti-halation layer ignores it.
    { name: 'halation_headroom_ev', value: clamp(e.highlightHeadroom, r.highlightHeadroom[0], r.highlightHeadroom[1]), layer: 'shoot' },
  );
  if (catalog?.isMonochrome(p.filmStock) && catalog.isMonochrome(p.printStock)) {
    // Multigrade IV RC filter 2. There is no silver-paper row in the colour
    // neutral-filter database; sending no pack would retain the old colour pair.
    f.push(
      { name: 'c_filter_neutral', value: 0, layer: 'print' },
      { name: 'm_filter_neutral', value: 0, layer: 'print' },
      { name: 'y_filter_neutral', value: 68, layer: 'print' },
    );
  }
  if (gate.digitalIntermediate) {
    f.push(
      { name: 'digital_intermediate', value: p.digitalIntermediate, layer: 'print' },
      {
        name: 'digital_intermediate_blue_compensation',
        value: p.digitalIntermediate && gate.diBlueCompensation,
        layer: 'print',
      },
    );
  }
  if (gate.overscan) {
    const fe = p.filmEdge;
    f.push({ name: 'overscan_active', value: edgeEffective(fe, gate), layer: 'shoot' });
    f.push({ name: 'overscan_pair', value: fe.pair, layer: 'shoot' });
    if (edgeEffective(fe, gate)) {
      f.push(
        { name: 'overscan_format', value: fe.format, layer: 'shoot' },
        { name: 'overscan_mode', value: fe.view, layer: 'shoot' },
        { name: 'overscan_gate', value: fe.gate, layer: 'shoot' },
        { name: 'overscan_holes', value: fe.holes, layer: 'shoot' },
        { name: 'overscan_camera_seed', value: clamp(Math.round(fe.cameraSeed), 0, 2147483647), layer: 'shoot' },
        { name: 'overscan_frame_seed', value: clamp(Math.round(fe.frameSeed), 0, 2147483647), layer: 'shoot' },
        { name: 'overscan_frame_number', value: clamp(Math.round(fe.frameNumber), 0, 99), layer: 'shoot' },
        { name: 'overscan_fog', value: clamp(fe.fog, 0, 4), layer: 'shoot' },
        { name: 'overscan_leaks', value: clamp(fe.leaks, 0, 4), layer: 'shoot' },
        { name: 'overscan_edge_text', value: fe.edgeText, layer: 'shoot' },
        { name: 'overscan_f_number', value: clamp(fe.fNumber, 0, 64), layer: 'shoot' },
      );
    }
  }
  if (gate.dateImprint) {
    const d = p.dateBack;
    const on = dateEffective(d, p.filmEdge, gate), camera = dateCamera(d, p.filmEdge, gate), scale = dateScale(p, gate);
    f.push({ name: 'date_imprint_active', value: on, layer: 'shoot' });
    if (on) {
      if (!(gate.overscan && p.filmEdge.active))
        f.push({ name: 'overscan_format', value: d.camera ?? '135', layer: 'shoot' });
      f.push(
        { name: 'date_imprint_style', value: d.face, layer: 'shoot' },
        { name: 'date_imprint_text', value: d.customText ?? d.text, layer: 'shoot' },
        { name: 'date_imprint_text_b', value: p.filmEdge.pair ? d.textB : '', layer: 'shoot' },
        { name: 'date_imprint_placement', value: d.placement, layer: 'shoot' },
        { name: 'date_imprint_corner', value: d.corner, layer: 'shoot' },
        { name: 'date_imprint_inset_x', value: clamp(d.insetXMM * scale, 0, 30), layer: 'shoot' },
        { name: 'date_imprint_inset_y', value: clamp(d.insetYMM * scale, 0, 30), layer: 'shoot' },
        { name: 'date_imprint_size', value: clamp((d.face === 'data' && camera?.id === '135_half' ? Math.min(d.size, 1) : d.size) * scale, 0.4, 3), layer: 'shoot' },
        { name: 'date_imprint_ev', value: clamp(d.brightnessEV, -2, 8), layer: 'shoot' },
        { name: 'date_imprint_data_text', value: d.withData && d.face !== 'data' && datePrints('data', d, p.filmEdge, gate) ? d.dataText : '', layer: 'shoot' },
      );
    }
  }
  return f;
}

export function fullDelta(p: FilmParams, gate?: FeatureGate, catalog?: StockCatalog): Record<string, WireValue> {
  const out: Record<string, WireValue> = {};
  for (const f of wire(p, gate, catalog)) out[f.name] = f.value;
  return out;
}

/** The delta that turns `from` into `to`, and the layers it touches. */
export function delta(
  to: FilmParams,
  from: FilmParams,
  gate?: FeatureGate,
  catalog?: StockCatalog,
): { delta: Record<string, WireValue>; layers: Set<ParamLayer> } {
  const theirs = new Map(wire(from, gate, catalog).map((f) => [f.name, f.value]));
  const out: Record<string, WireValue> = {};
  const layers = new Set<ParamLayer>();
  for (const f of wire(to, gate, catalog)) {
    if (theirs.get(f.name) !== f.value) {
      out[f.name] = f.value;
      layers.add(f.layer);
    }
  }
  // A film change also invalidates the print side.
  if ('film_stock' in out) layers.add('print');
  return { delta: out, layers };
}

/** Deep equality for plain JSON-shaped values. */
export function jsonEqual(a: unknown, b: unknown): boolean {
  if (a === b) return true;
  if (typeof a !== typeof b || a === null || b === null || typeof a !== 'object') return false;
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a as object);
  const kb = Object.keys(b as object);
  if (ka.length !== kb.length) return false;
  for (const k of ka) if (!jsonEqual((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k])) return false;
  return true;
}
