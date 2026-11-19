// lens.ts — lens correction at decode (Develop, Linux): which lens a photo was taken with, and the
// owner's own lenses ("My Lenses") for those lensfun's database does not have.
//
// The host corrects with lensfun (engine/host/lens_correct.cpp). A photo through a manual lens records
// no lens, so the lens is picked: a database lens by maker and model, or a custom lens by its numbers,
// which are lensfun's own models set by eye:
//   distortion  POLY3 k1:        < 0 the lens bows lines outward (barrel), > 0 inward (pincushion);
//   vignetting  PA k1:           < 0 the lens darkens its corners;
//   tcaR, tcaB  LINEAR scale:    red's / blue's magnification against green, 1 = none.
// The photo keeps the whole pick, numbers included, so it develops the same without the owner's list.

export interface CustomLensNumbers {
  distortion: number;
  vignetting: number;
  tcaR: number;
  tcaB: number;
}
export const CUSTOM_LENS_DEFAULT: CustomLensNumbers = { distortion: 0, vignetting: 0, tcaR: 1, tcaB: 1 };

export interface LensPick {
  maker: string;
  model: string;
  /** mm; 0 = the file's, or a prime's own. */
  focalMM: number;
  /** f-number; 0 = the file's (none: no dark-corner correction for a database lens). */
  aperture: number;
  /** A custom lens's numbers; null for a database lens. */
  custom: CustomLensNumbers | null;
}

/** One of the owner's own lenses, kept in the app's settings. */
export interface MyLens {
  name: string;
  focalMM: number;
  aperture: number;
  numbers: CustomLensNumbers;
}
/** The maker a custom lens is sent under. */
export const MY_LENS_MAKER = 'My Lenses';

/** A database lens as the host lists it (`lenses`). */
export interface LensEntry {
  maker: string;
  model: string;
  min_focal: number;
  max_focal: number;
  min_aperture?: number;
  mounts: string[];
  distortion: boolean;
  tca: boolean;
  vignetting: boolean;
}
export interface LensList {
  available: boolean;
  lenses: LensEntry[];
  crop_factor?: number;
  camera_known?: boolean;
}

/** What the host did at the last decode (`open`/`redecode` → `lens_correction`). */
export interface LensCorrectionReply {
  applied: boolean;
  error?: string;
  maker?: string;
  model?: string;
  focal_mm?: number;
  aperture?: number;
  distortion?: boolean;
  tca?: boolean;
  vignetting?: boolean;
}

// The sliders a custom lens is set with, in plain units, and the numbers they stand for. Ranges sit
// inside the host's (lens_correct: distortion ±0.2, vignetting ±0.95, TCA 0.99…1.01).
export const LENS_SLIDERS = {
  /** −100 strong barrel … +100 strong pincushion → k1 ±0.1. */
  distortion: { range: [-100, 100] as [number, number], toNumber: (v: number) => v * 0.001, fromNumber: (k: number) => k / 0.001 },
  /** 0 none … 100 corners about 1.3 stops dark → k1 0 … −0.6. */
  corners: { range: [0, 100] as [number, number], toNumber: (v: number) => -v * 0.006, fromNumber: (k: number) => -k / 0.006 },
  /** −100 … +100 → a colour's scale 1 ∓ 0.002 (about 4 px at a 24 MP corner). */
  fringe: { range: [-100, 100] as [number, number], toNumber: (v: number) => 1 + v * 0.00002, fromNumber: (s: number) => (s - 1) / 0.00002 },
};

const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export function decodeCustomNumbers(raw: unknown): CustomLensNumbers {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  return {
    distortion: clamp(num(o.distortion, 0), -0.2, 0.2),
    vignetting: clamp(num(o.vignetting, 0), -0.95, 0.95),
    tcaR: clamp(num(o.tcaR, 1), 0.99, 1.01),
    tcaB: clamp(num(o.tcaB, 1), 0.99, 1.01),
  };
}

export function decodeLensPick(raw: unknown): LensPick | null {
  if (!raw || typeof raw !== 'object') return null;
  const o = raw as Record<string, unknown>;
  if (typeof o.model !== 'string' || !o.model) return null;
  return {
    maker: typeof o.maker === 'string' ? o.maker : '',
    model: o.model,
    focalMM: clamp(num(o.focalMM, 0), 0, 5000),
    aperture: clamp(num(o.aperture, 0), 0, 128),
    custom: o.custom && typeof o.custom === 'object' ? decodeCustomNumbers(o.custom) : null,
  };
}

export function decodeMyLenses(raw: unknown): MyLens[] {
  if (!Array.isArray(raw)) return [];
  const out: MyLens[] = [];
  for (const r of raw) {
    if (!r || typeof r !== 'object') continue;
    const o = r as Record<string, unknown>;
    if (typeof o.name !== 'string' || !o.name.trim()) continue;
    if (out.some((m) => m.name === o.name)) continue;
    out.push({
      name: o.name.trim(),
      focalMM: clamp(num(o.focalMM, 0), 0, 5000),
      aperture: clamp(num(o.aperture, 0), 0, 128),
      numbers: decodeCustomNumbers(o.numbers),
    });
  }
  return out;
}

/** `decode.lens` for the host. */
export function lensWire(p: LensPick): Record<string, unknown> {
  const out: Record<string, unknown> = { maker: p.maker, model: p.model };
  if (p.focalMM > 0) out.focal_mm = p.focalMM;
  if (p.aperture > 0) out.aperture = p.aperture;
  if (p.custom) out.custom = { distortion: p.custom.distortion, vignetting: p.custom.vignetting, tca_r: p.custom.tcaR, tca_b: p.custom.tcaB };
  return out;
}

export function pickOfMyLens(m: MyLens): LensPick {
  return { maker: MY_LENS_MAKER, model: m.name, focalMM: m.focalMM, aperture: m.aperture, custom: { ...m.numbers } };
}

/** Database lenses matching every word of `query` (maker and model), best first, at most `limit`. */
export function searchLenses(list: readonly LensEntry[], query: string, limit = 80): LensEntry[] {
  const words = query.toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const hits: { e: LensEntry; score: number }[] = [];
  for (const e of list) {
    const hay = `${e.maker} ${e.model}`.toLowerCase();
    if (!words.every((w) => hay.includes(w))) continue;
    // Whole hits first: a number not run into more digits ("50" in "50mm", not in "500mm"), a word
    // not run into more letters. Then shorter names.
    const score = words.reduce((s, w) => {
      const esc = w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const after = /[0-9]$/.test(w) ? '(?![0-9])' : '(?![0-9a-z])';
      return s + (new RegExp(`(^|[^0-9a-z])${esc}${after}`).test(hay) ? 0 : 1);
    }, 0);
    hits.push({ e, score: score * 1000 + hay.length });
  }
  hits.sort((a, b) => a.score - b.score);
  return hits.slice(0, limit).map((h) => h.e);
}

/** What a database lens corrects, in words. */
export function lensFixes(e: { distortion?: boolean; tca?: boolean; vignetting?: boolean }): string[] {
  const out: string[] = [];
  if (e.distortion) out.push('distortion');
  if (e.vignetting) out.push('dark corners');
  if (e.tca) out.push('colour fringing');
  return out;
}
