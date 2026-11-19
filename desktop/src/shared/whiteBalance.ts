// whiteBalance.ts — camera white balance at decode (the Mac's
// `DecodeSettings.WhiteBalance` and `WhiteBalanceBoxes` in `Model/Sidecar.swift`,
// the setters in `Model/Session.swift`), and its wire form (HOST-PROTOCOL §3,
// `open.decode.white_balance`, R2).
//
// The two "As Shot" boxes, as the Mac defines them:
//  - a box is ticked when the decode uses the camera's value for that axis:
//    `As Shot`, or `Custom` pinned exactly to the camera's value (the same
//    picture, so the same state);
//  - ticking pins that axis to the camera's value; both ticked is `As Shot`,
//    one ticked is `Custom` with the other axis where it was;
//  - unticking, or dragging the slider, is `Custom` at the current value;
//  - a preset sets the numbers itself.
// With no As Shot pair known yet (no decode has landed) the boxes read
// unticked and do nothing.

import type { DecodeSettings } from './sidecar';
import { lensWire } from './lens';

export type WhiteBalanceMode = 'As Shot' | 'Daylight' | 'Cloudy' | 'Shade' | 'Tungsten' | 'Fluorescent' | 'Custom';
export const WB_MODES: WhiteBalanceMode[] = ['As Shot', 'Daylight', 'Cloudy', 'Shade', 'Tungsten', 'Fluorescent', 'Custom'];
export const WB_KELVIN: Partial<Record<WhiteBalanceMode, number>> = {
  Daylight: 5500,
  Cloudy: 6500,
  Shade: 7500,
  Tungsten: 3200,
  Fluorescent: 4000,
};

/** The slider ranges (the Mac's rows); the wire takes 2000–50000 K. */
export const TEMPERATURE_RANGE: [number, number] = [2000, 12000];
export const TINT_RANGE: [number, number] = [-150, 150];

export interface AsShot {
  temperature: number;
  tint: number;
}

export function modeOf(d: DecodeSettings): WhiteBalanceMode {
  return (WB_MODES as string[]).includes(d.whiteBalance) ? (d.whiteBalance as WhiteBalanceMode) : 'As Shot';
}

/** What the rows show: for As Shot, the camera's pair once a decode reported it. */
export function shownDecode(d: DecodeSettings, asShot: AsShot | null): DecodeSettings {
  if (modeOf(d) === 'As Shot' && asShot) return { ...d, temperature: asShot.temperature, tint: asShot.tint };
  return d;
}

export interface Boxes {
  temp: boolean;
  tint: boolean;
}

export function boxesOf(d: DecodeSettings, asShot: AsShot | null): Boxes {
  if (!asShot) return { temp: false, tint: false };
  const following = modeOf(d) === 'As Shot';
  return { temp: following || d.temperature === asShot.temperature, tint: following || d.tint === asShot.tint };
}

/** One box ticked or unticked (`undefined` leaves a box alone). */
export function applyBoxes(d: DecodeSettings, asShot: AsShot | null, change: Partial<Boxes>): DecodeSettings {
  if (!asShot) return d;
  const b = { ...boxesOf(d, asShot), ...change };
  const base = shownDecode(d, asShot);
  return {
    ...base,
    temperature: b.temp ? asShot.temperature : base.temperature,
    tint: b.tint ? asShot.tint : base.tint,
    whiteBalance: b.temp && b.tint ? 'As Shot' : 'Custom',
  };
}

export function withTemperature(d: DecodeSettings, asShot: AsShot | null, kelvin: number): DecodeSettings {
  return { ...shownDecode(d, asShot), temperature: Math.round(kelvin), whiteBalance: 'Custom' };
}

export function withTint(d: DecodeSettings, asShot: AsShot | null, tint: number): DecodeSettings {
  return { ...shownDecode(d, asShot), tint: Math.round(tint * 10) / 10, whiteBalance: 'Custom' };
}

export function withPreset(d: DecodeSettings, asShot: AsShot | null, mode: WhiteBalanceMode): DecodeSettings {
  const k = WB_KELVIN[mode];
  if (k !== undefined) return { ...d, whiteBalance: mode, temperature: k, tint: 0 };
  if (mode === 'As Shot') return { ...d, whiteBalance: mode, ...(asShot ? { temperature: asShot.temperature, tint: asShot.tint } : {}) };
  return { ...d, whiteBalance: mode };
}

const RAW_EXT = new Set(['nef', 'nrw', 'arw', 'srf', 'sr2', 'cr2', 'cr3', 'crw', 'raf', 'dng', 'orf', 'rw2', 'pef', 'srw', 'raw', 'rwl', '3fr', 'iiq', 'erf', 'mrw', 'x3f', 'kdc', 'dcr', 'mos']);
export function isRawPath(path: string): boolean {
  return RAW_EXT.has((path.split('.').pop() ?? '').toLowerCase());
}

export interface WireDecode {
  white_balance?: { mode: 'as_shot' } | { mode: 'custom'; temperature_k: number; tint: number };
  lens_correction?: boolean;
  lens?: Record<string, unknown>;
  /** Develop: the film edge's gate shape the host cuts the picture to (params.ts `filmEdgeCutAspect`). */
  cut?: { aspect: number };
}

/**
 * `open.decode` / `redecode.decode`. White balance for a RAW only (the host refuses it elsewhere);
 * lens correction (Develop) for any file, sent only while on. Null: nothing to ask.
 */
export function decodeWire(d: DecodeSettings, isRaw: boolean, cutAspect: number | null = null): WireDecode | null {
  const out: WireDecode = {};
  if (cutAspect) out.cut = { aspect: cutAspect };
  if (isRaw) {
    if (modeOf(d) === 'As Shot') out.white_balance = { mode: 'as_shot' };
    else {
      const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
      out.white_balance = { mode: 'custom', temperature_k: clamp(d.temperature, 2000, 50000), tint: clamp(d.tint, -150, 150) };
    }
  }
  if (d.lensCorrection) {
    out.lens_correction = true;
    if (d.lens) out.lens = lensWire(d.lens);
  }
  return Object.keys(out).length ? out : null;
}
