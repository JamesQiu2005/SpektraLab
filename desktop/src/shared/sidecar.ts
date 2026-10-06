// sidecar.ts — a frame's edits, in the macOS `Sidecar` JSON shape
// (`Model/Sidecar.swift`, schemaVersion 3).
//
// Where it lives is the core's business (`src-tauri/src/files.rs`:
// `<app data>/Sidecars/<file>-<sha256(path)[:16]>.spektra.json`). What is in
// it is this file's. Keys the port does not model (masks, `heldCrop`, the
// pair's fields) are carried through untouched, so opening a Mac sidecar here
// and saving it does not lose anything the Mac wrote.

import { type Adjustments, ADJUSTMENTS_DEFAULT, decodeAdjustments } from './adjustments';
import { type Geometry, GEOMETRY_DEFAULT, decodeGeometry, encodeGeometry } from './geometry';
import { type FilmParams, FILM_PARAMS_DEFAULT, decodeFilmParams } from './params';

export type FrameState = 'unprocessed' | 'processed' | 'stale';

export interface DecodeSettings {
  whiteBalance: string;
  temperature: number;
  tint: number;
  lensCorrection: boolean;
}
export const DECODE_DEFAULT: DecodeSettings = {
  whiteBalance: 'As Shot',
  temperature: 5500,
  tint: 0,
  lensCorrection: false,
};

export interface Sidecar {
  schemaVersion: number;
  decoder: string;
  decode: DecodeSettings;
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
  solvedEV?: number | null;
  placementNeedsFit: boolean;
  state: FrameState;
  /** Everything as read, for the keys the port carries but does not model. */
  raw: Record<string, unknown>;
}

export function newSidecar(): Sidecar {
  return {
    schemaVersion: 3,
    decoder: 'libraw',
    decode: DECODE_DEFAULT,
    params: FILM_PARAMS_DEFAULT,
    adjustments: ADJUSTMENTS_DEFAULT,
    geometry: GEOMETRY_DEFAULT,
    solvedEV: null,
    placementNeedsFit: false,
    state: 'unprocessed',
    raw: {},
  };
}

/** Swift encodes a payload-less enum case as `{"processed": {}}`. */
function decodeState(v: unknown): FrameState {
  if (typeof v === 'string' && ['unprocessed', 'processed', 'stale'].includes(v)) return v as FrameState;
  if (v && typeof v === 'object') {
    const k = Object.keys(v)[0];
    if (k === 'processed' || k === 'stale' || k === 'unprocessed') return k;
  }
  return 'unprocessed';
}

export function decodeSidecar(raw: unknown): Sidecar {
  const o = raw && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  const d = o.decode && typeof o.decode === 'object' ? (o.decode as Record<string, unknown>) : {};
  let geometry = GEOMETRY_DEFAULT;
  if (o.geometry) geometry = decodeGeometry(o.geometry);
  else if (o.crop) geometry = decodeGeometry({ crop: o.crop });
  return {
    schemaVersion: 3,
    decoder: typeof o.decoder === 'string' ? o.decoder : 'coreimage',
    decode: {
      whiteBalance: typeof d.whiteBalance === 'string' ? d.whiteBalance : DECODE_DEFAULT.whiteBalance,
      temperature: typeof d.temperature === 'number' ? d.temperature : DECODE_DEFAULT.temperature,
      tint: typeof d.tint === 'number' ? d.tint : DECODE_DEFAULT.tint,
      lensCorrection: d.lensCorrection === true,
    },
    params: o.params ? decodeFilmParams(o.params) : FILM_PARAMS_DEFAULT,
    adjustments: o.adjustments ? decodeAdjustments(o.adjustments) : ADJUSTMENTS_DEFAULT,
    geometry,
    solvedEV: typeof o.solvedEV === 'number' ? o.solvedEV : null,
    placementNeedsFit: o.placementNeedsFit === true,
    state: decodeState(o.state),
    raw: o,
  };
}

export function encodeSidecar(s: Sidecar): Record<string, unknown> {
  const out: Record<string, unknown> = { ...s.raw };
  delete out.crop; // legacy key, superseded by geometry
  out.schemaVersion = 3;
  out.decoder = s.decoder;
  out.decode = s.decode;
  out.params = s.params;
  out.adjustments = s.adjustments;
  out.geometry = encodeGeometry(s.geometry);
  if (s.solvedEV != null) out.solvedEV = s.solvedEV;
  else delete out.solvedEV;
  if (s.placementNeedsFit) out.placementNeedsFit = true;
  else delete out.placementNeedsFit;
  out.state = { [s.state]: {} };
  // `source` is written by the core from the file itself.
  return out;
}
