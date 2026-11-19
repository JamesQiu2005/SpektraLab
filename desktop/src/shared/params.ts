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

import { activeCatalog, edgeTextFor, type StockCatalog } from './stocks';

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
  scatter: 1,
  couplersActive: true,
  couplers: 1,
  glare: 1,
};
/**
 * Engine settings no SpektraLab interface exposed, offered on Linux at the owner's request
 * (2026-11-18). Each default is the engine's own (params.cpp), so a frame nobody touched renders
 * as before; the sidecar key `linuxAdvanced` is this port's, carried through by the Mac.
 */
export interface AdvancedParams {
  /** camera.lens_blur_um: the taking lens's softness, in micrometres on the film. */
  lensBlurUM: number;
  /** film_render.density_curve_gamma: development contrast (1 = the data sheet's). */
  developGamma: number;
  /** scanner.lens_blur: the scanner lens's softness. */
  scannerBlur: number;
  scannerWhite: boolean;
  scannerBlack: boolean;
  /** film_render.halation.headroom_ev: highlight headroom for a film with no anti-halation layer. */
  headroomEV: number;
}
export const ADVANCED_DEFAULT: AdvancedParams = {
  lensBlurUM: 0,
  developGamma: 1,
  scannerBlur: 0,
  scannerWhite: false,
  scannerBlack: false,
  headroomEV: 4,
};
/** Inside the wire's ranges, narrowed to where a slider is usable. */
export const ADVANCED_RANGES = {
  lensBlurUM: [0, 100],
  developGamma: [0.5, 2],
  scannerBlur: [0, 10],
  headroomEV: [0, 8],
} as const satisfies Record<string, readonly [number, number]>;

/**
 * **Light Leak** (API-SPEC §21.1, §21.8, §21.9), SpektraLab 2's `LeakSettings` (LensEdge.swift): light that
 * reached the film without passing the lens. `kind` off / auto / band / wash / spot at `amount` (0…4, 1 reaches
 * orange, 4 clips to white); beside it the **Edge Burn** at its own strength (`edge`, 0 is off); `seed` 0 is the
 * camera's own leak, non-zero Shuffle's. Its colour is the film's own sensitivity: no colour is painted.
 */
export const LEAK_KINDS = ['off', 'auto', 'band', 'wash', 'spot'] as const;
export type LeakKind = (typeof LEAK_KINDS)[number];
export interface LeakSettings {
  kind: string;
  amount: number;
  edge: number;
  seed: number;
}
export const LEAK_DEFAULT: LeakSettings = { kind: 'off', amount: 1, edge: 0, seed: 0 };
export const LEAK_RANGE: readonly [number, number] = [0, 4];
/** The Edge Burn's strength when its switch goes on. */
export const LEAK_EDGE_REST = 1;
export const LEAK_SEED_MAX = 2147483647;

/**
 * **Lens** (API-SPEC §21.5-§21.6), SpektraLab 2's `LensSettings`: a soft filter in front of the lens (the four
 * families, generic names, at the grade's five detents 1/8 … 2) and the lens's **Character** -- a named lens, the
 * twelve `lens_*` numbers at Amount 100 % (`LensCharacter.preset`, the app's own tables). Both act on the source
 * before the film, so either re-develops.
 */
export const SOFT_FILTERS = ['black_pro_mist', 'pro_mist', 'glimmerglass', 'cinebloom'] as const;
export const SOFT_FILTER_STRENGTHS = [0.125, 0.25, 0.5, 1, 2] as const;
export const LENS_CHARACTERS = ['helios44', 'petzval', 'vintage_soft', 'plastic'] as const;
export interface LensSettings {
  /** `diffusion_filter_family`; null is off. */
  filter: string | null;
  strength: number;
  /** A `LENS_CHARACTERS` name; null is off. */
  character: string | null;
  /** 0…1. */
  amount: number;
}
export const LENS_DEFAULT: LensSettings = { filter: null, strength: 0.5, character: null, amount: 1 };

interface LensPreset {
  fieldCurvatureUM?: number;
  astigmatismUM?: number;
  fieldExponent?: number;
  sharpRadius?: number;
  comaUM?: number;
  sphericalAmount?: number;
  sphericalUM?: number;
  lateralCAR?: number;
  lateralCAB?: number;
  locaUM?: number;
  locaSign?: string;
}
/** LensEdge.swift `LensCharacter.preset`, number for number. */
const LENS_PRESETS: Record<string, LensPreset> = {
  helios44: { fieldCurvatureUM: 45, astigmatismUM: 70, fieldExponent: 2, comaUM: 25, sphericalAmount: 0.08, sphericalUM: 60 },
  petzval: { fieldCurvatureUM: 70, astigmatismUM: 100, fieldExponent: 3, sharpRadius: 0.3 },
  vintage_soft: { fieldCurvatureUM: 25, comaUM: 60, sphericalAmount: 0.2, sphericalUM: 80 },
  plastic: { fieldCurvatureUM: 35, sphericalAmount: 0.25, sphericalUM: 120, lateralCAR: 1.5, lateralCAB: -1.5, locaUM: 10, locaSign: 'purple' },
};

/** `LensPreset.wire(amount:)`: the blurs, fringes and glow's share scale with the amount; the field's shape is the lens's. */
function lensCharacterWire(name: string, amount: number): WireField[] {
  const q = LENS_PRESETS[name];
  if (!q) return [];
  const a = clamp(amount, 0, 1);
  const L = (n: string, v: WireValue): WireField => ({ name: n, value: v, layer: 'shoot' });
  return [
    L('lens_field_curvature_um', clamp((q.fieldCurvatureUM ?? 0) * a, 0, 120)),
    L('lens_astigmatism_um', clamp((q.astigmatismUM ?? 0) * a, -120, 120)),
    L('lens_field_exponent', clamp(q.fieldExponent ?? 2, 1, 4)),
    L('lens_sharp_radius', clamp(q.sharpRadius ?? 0, 0, 0.8)),
    L('lens_coma_um', clamp((q.comaUM ?? 0) * a, -150, 150)),
    L('lens_spherical_amount', clamp((q.sphericalAmount ?? 0) * a, 0, 0.6)),
    L('lens_spherical_um', clamp(q.sphericalUM ?? 60, 10, 400)),
    L('lens_lateral_ca_r', clamp((q.lateralCAR ?? 0) * a, -3, 3)),
    L('lens_lateral_ca_b', clamp((q.lateralCAB ?? 0) * a, -3, 3)),
    L('lens_loca_um', clamp((q.locaUM ?? 0) * a, 0, 30)),
    L('lens_loca_sign', q.locaSign ?? 'purple'),
    L('lens_loca_highlight_gate', 1),
  ];
}

/**
 * A photo's own leak (SpektraLab 2: every frame has its own `frameSeed`, drawn once and kept in its
 * edit; the camera's seed is the body's). The first time a leak is on in a photo whose film-edge seeds
 * were never drawn, its frame seed is drawn and kept, so two photos show two leaks of the same camera
 * and a photo keeps its leak from then on. Anything else is returned as it is.
 */
export function withFrameSeed(p: FilmParams, random: () => number = Math.random): FilmParams {
  const lk = p.leak ?? LEAK_DEFAULT;
  if ((lk.kind === 'off' && !(lk.edge > 0)) || p.filmEdge.seeded) return p;
  const frameSeed = 1 + Math.floor(random() * (LEAK_SEED_MAX - 1));
  return { ...p, filmEdge: { ...p.filmEdge, frameSeed, seeded: true } };
}

export const EFFECT_RANGES = {
  grain: [0, 2],
  halation: [0, 4],
  scatter: [0, 1],
  highlightBoost: [0, 8],
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

/** Each film-edge format's gate, along x across the film in mm (engine overscan.cpp `kFormats`). */
export const FILM_EDGE_GATES: Record<string, readonly [number, number]> = {
  '135': [36.25, 24.3],
  '135_half': [18, 24],
  '135_xpan': [65, 24],
  '120_645': [41.5, 56],
  '120_6x6': [56, 56],
  '120_6x7': [69.5, 56],
  '120_6x8': [76, 56],
  '120_6x9': [84, 56],
  '120_6x12': [112, 56],
  '120_6x17': [168, 56],
  '135_sprocket': [72, 36],
};

/**
 * The cut a film edge needs (SpektraLab 2's `HostCut`): the engine takes the picture it is handed as
 * the gate and refuses one of another shape, so with the film edge on the host cuts the picture to the
 * gate's shape first (the long side over the short; the picture keeps its orientation). Null: no cut.
 */
/** The pair the host composes (whiteBalance.ts decodeWire), or null. */
export function pairDecode(p: FilmParams): { second: string; swap: boolean } | null {
  return p.pairWith ? { second: p.pairWith, swap: !!p.pairSwap } : null;
}

export function filmEdgeCutAspect(p: FilmParams, gate: FeatureGate = ALL_FEATURES): number | null {
  // A pair's piece is already the gate and an advance: the host makes it, nothing is cut.
  if (!gate.overscan || !p.filmEdge.active || p.pairWith) return null;
  const g = FILM_EDGE_GATES[p.filmEdge.format];
  if (!g) return null;
  return Math.max(g[0], g[1]) / Math.min(g[0], g[1]);
}

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
  /** The scan's carrier past the film's long edges: none (the film's width), black, open (light). */
  carrier: string;
  /** 120 cut from 65 mm cine film: its keyhole perforations ('ks65'), else 'none'. */
  perforation: string;
  /** The taking lens's light falloff towards the corners (135 full width), 0…1.5. */
  falloff: number;
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
  carrier: 'none',
  perforation: 'none',
  falloff: 0,
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
  /** Develop's half-frame pair: the second picture's path, beside this one on one piece of film ('' none). */
  pairWith: string;
  /** The second picture first along the film. */
  pairSwap: boolean;
  effects: EffectStrengths;
  linuxAdvanced: AdvancedParams;
  leak: LeakSettings;
  lens: LensSettings;
  printEffects: boolean;
  filmEdge: FilmEdgeSettings;
  dateBack: DateBackSettings;
}

export const FILM_PARAMS_DEFAULT: FilmParams = {
  filmStock: 'kodak_portra_400',
  printStock: 'kodak_supra_endura',
  exposureCompensationEV: 0,
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
  pairWith: '',
  pairSwap: false,
  effects: EFFECTS_DEFAULT,
  linuxAdvanced: ADVANCED_DEFAULT,
  leak: LEAK_DEFAULT,
  lens: LENS_DEFAULT,
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
  base.linuxAdvanced = decodeShape(o.linuxAdvanced, ADVANCED_DEFAULT);
  base.leak = decodeShape(o.leak, LEAK_DEFAULT);
  if (!(LEAK_KINDS as readonly string[]).includes(base.leak.kind)) base.leak.kind = 'off';
  base.lens = decodeShape(o.lens, LENS_DEFAULT);
  if (base.lens.filter !== null && !(SOFT_FILTERS as readonly string[]).includes(base.lens.filter)) base.lens.filter = null;
  if (base.lens.character !== null && !(LENS_CHARACTERS as readonly string[]).includes(base.lens.character)) base.lens.character = null;
  base.filmEdge = decodeShape(o.filmEdge, FILM_EDGE_DEFAULT);
  base.dateBack = decodeShape(o.dateBack, DATE_BACK_DEFAULT);
  if (o.filmEdge && !('seeded' in obj(o.filmEdge))) base.filmEdge.seeded = 'frameSeed' in obj(o.filmEdge);
  return base;
}

/** Features the host may refuse (`capabilities.backend.unsupported_features`). */
export interface FeatureGate {
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
  digitalIntermediate: true,
  sceneLatitude: true,
  contrastMask: true,
  overscan: true,
  dateImprint: true,
  diBlueCompensation: false,
  toneMask: false,
};

export function featureGate(unsupported: readonly string[] | undefined, diBlue = false): FeatureGate {
  const u = new Set(unsupported ?? []);
  return {
    digitalIntermediate: !u.has('digital_intermediate'),
    sceneLatitude: !u.has('scene_latitude_mapping'),
    contrastMask: !u.has('contrast_mask'),
    overscan: !u.has('overscan'),
    dateImprint: !u.has('date_imprint'),
    diBlueCompensation: diBlue,
    toneMask: false,
  };
}

export function effectiveEDR(p: FilmParams): boolean {
  return p.extendedDynamicRange && !p.scanFilm && !p.digitalIntermediate;
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
/**
 * These settings with the catalogue's rules applied (Stock.swift `heldToItsFilm`): a slide is
 * scanned, and a paper that cannot print the film gives way to the film's own.
 */
export function heldToItsFilm(p: FilmParams, cat: StockCatalog = activeCatalog()): FilmParams {
  const scan = p.scanFilm || cat.isSlide(p.filmStock);
  const paper = cat.paperPrinting(p.filmStock, p.printStock);
  if (scan === p.scanFilm && paper === p.printStock) return p;
  return { ...p, scanFilm: scan, printStock: paper };
}

export function wire(p0: FilmParams, gate: FeatureGate = ALL_FEATURES): WireField[] {
  // SpektraLab 2's rules (Stock.swift `wire` and `silver`), which only the catalogue can apply:
  // the settings held to their film, and what a black-and-white film on its paper needs that no
  // edit holds. With the empty catalogue (tests) nothing changes.
  const cat = activeCatalog();
  const p = heldToItsFilm(p0, cat);
  const monoFilm = cat.isMonochrome(p.filmStock);
  const monoPaper = cat.isMonochrome(p.printStock);
  const di = gate.digitalIntermediate && p.digitalIntermediate;
  const placement = p.placementIsRight ? p.sceneLatitudeOther : p.sceneLatitude;
  const f: WireField[] = [
    { name: 'film_stock', value: p.filmStock, layer: 'shoot' },
    { name: 'print_stock', value: p.printStock, layer: 'print' },
    { name: 'exposure_compensation_ev', value: p.exposureCompensationEV, layer: 'shoot' },
  ];
  if (p.autoExposureMethod != null) f.push({ name: 'auto_exposure_method', value: p.autoExposureMethod, layer: 'shoot' });
  f.push(
    { name: 'auto_exposure', value: p.autoExposure, layer: 'shoot' },
    // A pair's piece is 37 mm of film along its long edge (two 18 mm frames and the 1 mm between).
    { name: 'film_format_mm', value: p.pairWith ? 37 : clamp(p.filmFormatMM, 4, 200), layer: 'shoot' },
    { name: 'grain_active', value: p.grainActive, layer: 'shoot' },
    // A black-and-white film's grain is one layer, whatever the setting: sub-layers are the colour model.
    { name: 'grain_sublayers_active', value: p.grainActive && p.effects.grainLayered && !monoFilm, layer: 'shoot' },
    { name: 'halation_active', value: p.halationActive, layer: 'shoot' },
    { name: 'print_exposure', value: printExposure(p.printBrightnessStops), layer: 'print' },
    { name: 'y_filter_shift', value: clamp(p.yFilterShift, -1, 1), layer: 'print' },
    { name: 'm_filter_shift', value: clamp(p.mFilterShift, -1, 1), layer: 'print' },
    { name: 'filter_shift_scale', value: FILTER_SHIFT_CC, layer: 'print' },
    { name: 'glare_active', value: p.glareActive && p.printEffects, layer: 'print' },
    { name: 'scan_film', value: p.scanFilm, layer: 'print' },
    // A silver paper has no EDR calibration: the engine refuses the open by name.
    { name: 'extended_dynamic_range', value: effectiveEDR(p) && !monoPaper, layer: 'print' },
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
    );
  }
  const e = p.effects;
  const r = EFFECT_RANGES;
  f.push(
    { name: 'halation_amount', value: clamp(e.halation, r.halation[0], r.halation[1]), layer: 'shoot' },
    { name: 'halation_scatter_amount', value: clamp(e.scatter, r.scatter[0], r.scatter[1]), layer: 'shoot' },
    // The Grain strength as it is, for every film. SpektraLab 2 multiplies it by the catalogue's
    // per-film `grain` (Stock.swift `silver`: `cat.stock(film)?.grain`); reverted here at the
    // owner's request on 2026-11-18 so the grain can be judged against what it was.
    { name: 'grain_amount', value: clamp(e.grain, r.grain[0], r.grain[1]), layer: 'shoot' },
    { name: 'dir_couplers_active', value: e.couplersActive, layer: 'shoot' },
    { name: 'dir_couplers_amount', value: clamp(e.couplers, r.couplers[0], r.couplers[1]), layer: 'shoot' },
    { name: 'glare_amount', value: clamp(e.glare, r.glare[0], r.glare[1]), layer: 'print' },
    { name: 'antihalation_removed', value: e.antihalationRemoved, layer: 'shoot' },
    { name: 'halation_boost_ev', value: clamp(e.highlightBoost, r.highlightBoost[0], r.highlightBoost[1]), layer: 'shoot' },
  );
  const a = p.linuxAdvanced ?? ADVANCED_DEFAULT;
  const ar = ADVANCED_RANGES;
  f.push(
    { name: 'lens_blur_um', value: clamp(a.lensBlurUM, ar.lensBlurUM[0], ar.lensBlurUM[1]), layer: 'shoot' },
    { name: 'density_curve_gamma', value: clamp(a.developGamma, ar.developGamma[0], ar.developGamma[1]), layer: 'shoot' },
    { name: 'halation_headroom_ev', value: clamp(a.headroomEV, ar.headroomEV[0], ar.headroomEV[1]), layer: 'shoot' },
    { name: 'scanner_lens_blur', value: clamp(a.scannerBlur, ar.scannerBlur[0], ar.scannerBlur[1]), layer: 'print' },
    // The engine has no black/white correction for a slide scanned directly (it refuses the render), so
    // there they stay off whatever the switch says (the Advanced section greys them).
    { name: 'scanner_white_correction', value: a.scannerWhite && !(p.scanFilm && cat.isPositive(p.filmStock)), layer: 'print' },
    { name: 'scanner_black_correction', value: a.scannerBlack && !(p.scanFilm && cat.isPositive(p.filmStock)), layer: 'print' },
  );
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
    f.push({ name: 'overscan_active', value: fe.active, layer: 'shoot' });
    if (fe.active) {
      f.push(
        // A pair is two half frames on one piece: the engine's 135_half, told the input holds both.
        { name: 'overscan_format', value: p.pairWith ? '135_half' : fe.format, layer: 'shoot' },
        { name: 'overscan_pair', value: !!p.pairWith, layer: 'shoot' },
        { name: 'overscan_mode', value: fe.view, layer: 'shoot' },
        { name: 'overscan_gate', value: fe.gate, layer: 'shoot' },
        { name: 'overscan_holes', value: fe.holes, layer: 'shoot' },
        { name: 'overscan_camera_seed', value: clamp(Math.round(fe.cameraSeed), 0, 2147483647), layer: 'shoot' },
        { name: 'overscan_frame_seed', value: clamp(Math.round(fe.frameSeed), 0, 2147483647), layer: 'shoot' },
        { name: 'overscan_frame_number', value: clamp(Math.round(fe.frameNumber), 0, 99), layer: 'shoot' },
        { name: 'overscan_fog', value: clamp(fe.fog, 0, 4), layer: 'shoot' },
        { name: 'overscan_leaks', value: clamp(fe.leaks, 0, 4), layer: 'shoot' },
        // The film's own edge words unless the photo set its own (SpektraLab 2's `Stock.edgeText(gauge:)`).
        { name: 'overscan_edge_text', value: fe.edgeText || edgeTextFor(cat, p.filmStock, fe.format), layer: 'shoot' },
        { name: 'overscan_f_number', value: clamp(fe.fNumber, 0, 64), layer: 'shoot' },
        { name: 'overscan_carrier', value: ['none', 'black', 'open'].includes(fe.carrier) ? fe.carrier : 'none', layer: 'shoot' },
        // 65 mm keyholes only on 120; the engine draws them nowhere else.
        { name: 'overscan_perforation', value: fe.perforation === 'ks65' && fe.format.startsWith('120') ? 'ks65' : 'none', layer: 'shoot' },
        { name: 'overscan_falloff', value: clamp(fe.falloff, 0, 1.5), layer: 'shoot' },
      );
    }
  }
  if (gate.dateImprint) {
    const d = p.dateBack;
    const on = d.active && (d.face === 'data' || d.placement === 'frame' || (gate.overscan && p.filmEdge.active));
    f.push({ name: 'date_imprint_active', value: on, layer: 'shoot' });
    if (on) {
      if (!(gate.overscan && p.filmEdge.active))
        f.push({ name: 'overscan_format', value: d.camera ?? '135', layer: 'shoot' });
      f.push(
        { name: 'date_imprint_style', value: d.face, layer: 'shoot' },
        { name: 'date_imprint_text', value: d.customText ?? d.text, layer: 'shoot' },
        { name: 'date_imprint_placement', value: d.placement, layer: 'shoot' },
        { name: 'date_imprint_corner', value: d.corner, layer: 'shoot' },
        { name: 'date_imprint_inset_x', value: clamp(d.insetXMM, 0, 30), layer: 'shoot' },
        { name: 'date_imprint_inset_y', value: clamp(d.insetYMM, 0, 30), layer: 'shoot' },
        { name: 'date_imprint_size', value: clamp(d.size, 0.4, 3), layer: 'shoot' },
        { name: 'date_imprint_ev', value: clamp(d.brightnessEV, -2, 8), layer: 'shoot' },
        { name: 'date_imprint_data_text', value: d.withData ? d.dataText : '', layer: 'shoot' },
      );
    }
  }
  // Light Leak (SpektraLab 2's `leakWire`). Its switches are always sent, so turning it off reaches
  // the engine; `leak_rate` 1, one picture edited alone always shows its camera's leak; `leak_front`
  // -1, the camera's share of front light.
  const lk = p.leak ?? LEAK_DEFAULT;
  const kindOn = lk.kind !== 'off';
  const edgeOn = lk.edge > 0;
  f.push(
    { name: 'leak_kind', value: kindOn ? lk.kind : 'off', layer: 'shoot' },
    { name: 'leak_amount', value: clamp(lk.amount, LEAK_RANGE[0], LEAK_RANGE[1]), layer: 'shoot' },
    { name: 'leak_edge', value: edgeOn ? clamp(lk.edge, LEAK_RANGE[0], LEAK_RANGE[1]) : 0, layer: 'shoot' },
    { name: 'leak_seed', value: clamp(Math.round(lk.seed), 0, LEAK_SEED_MAX), layer: 'shoot' },
    { name: 'leak_rate', value: 1, layer: 'shoot' },
    { name: 'leak_front', value: -1, layer: 'shoot' },
  );
  // With the film edge off, the leak is laid on a camera's gate: the seeds and format the film edge
  // would send, so it does not move when the film edge goes on (a date back's camera when it sent one).
  if ((kindOn || edgeOn) && !(gate.overscan && p.filmEdge.active)) {
    const fe = p.filmEdge;
    if (!f.some((x) => x.name === 'overscan_format')) f.push({ name: 'overscan_format', value: '135', layer: 'shoot' });
    f.push(
      { name: 'overscan_camera_seed', value: clamp(Math.round(fe.cameraSeed), 0, LEAK_SEED_MAX), layer: 'shoot' },
      { name: 'overscan_frame_seed', value: clamp(Math.round(fe.frameSeed), 0, LEAK_SEED_MAX), layer: 'shoot' },
      { name: 'overscan_frame_number', value: clamp(Math.round(fe.frameNumber), 0, 99), layer: 'shoot' },
    );
  }
  // Lens: the soft filter and the lens's character, each switch always sent.
  const ln = p.lens ?? LENS_DEFAULT;
  f.push({ name: 'diffusion_filter_active', value: ln.filter !== null, layer: 'shoot' });
  if (ln.filter !== null)
    f.push(
      { name: 'diffusion_filter_family', value: ln.filter, layer: 'shoot' },
      { name: 'diffusion_filter_strength', value: clamp(ln.strength, 0, 2), layer: 'shoot' },
    );
  f.push({ name: 'lens_aberrations_active', value: ln.character !== null, layer: 'shoot' });
  if (ln.character !== null) f.push(...lensCharacterWire(ln.character, ln.amount));
  // A silver pair's enlarger pack: the engine's table has no row for a silver paper, and a session
  // coming from a colour pair would keep that pair's. Going back, the engine takes the colour pair's
  // own row again when print_stock changes, so nothing is sent for it.
  const pack = cat.stock(p.printStock)?.neutralPack;
  if (monoFilm && monoPaper && pack && pack.length === 3) {
    const [c, m, y] = pack as [number, number, number];
    f.push(
      { name: 'c_filter_neutral', value: c, layer: 'print' },
      { name: 'm_filter_neutral', value: m, layer: 'print' },
      { name: 'y_filter_neutral', value: y, layer: 'print' },
    );
  }
  return f;
}

export function fullDelta(p: FilmParams, gate?: FeatureGate): Record<string, WireValue> {
  const out: Record<string, WireValue> = {};
  for (const f of wire(p, gate)) out[f.name] = f.value;
  return out;
}

/** The delta that turns `from` into `to`, and the layers it touches. */
export function delta(
  to: FilmParams,
  from: FilmParams,
  gate?: FeatureGate,
): { delta: Record<string, WireValue>; layers: Set<ParamLayer> } {
  const theirs = new Map(wire(from, gate).map((f) => [f.name, f.value]));
  const out: Record<string, WireValue> = {};
  const layers = new Set<ParamLayer>();
  for (const f of wire(to, gate)) {
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
