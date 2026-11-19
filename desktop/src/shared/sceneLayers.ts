// sceneLayers.ts — Develop's local exposure layers, on the engine's RFC-052 scene layers: up to eight masks,
// each a local amount of Film Exposure (stops) and of warmth on the light, before the film -- a graduated
// sky darkened, a face lifted, a corner warmed, the way a printer dodges and burns but on the negative's
// exposure. The masks are drawn here as 16-bit planes in the decoded picture's own coordinates (S) and
// handed to the host (`scene_layers`); the wire names them by a stamp of their settings.

export const SCENE_LAYER_KINDS = ['linear', 'radial', 'whole'] as const;
export type SceneLayerKind = (typeof SCENE_LAYER_KINDS)[number];

export interface SceneLayer {
  enabled: boolean;
  kind: SceneLayerKind;
  /** Stops of exposure at full mask, −3…3. */
  exposure: number;
  /** −100 cool … 100 warm: the light's colour, on the cone responses. */
  warmth: number;
  /** 0…1. */
  opacity: number;
  invert: boolean;
  /** linear: which way the mask lies, degrees (0 = the top of the picture, 90 = its right). */
  angle: number;
  /** linear: where the fade's middle lies across the picture, 0…1; radial: the centre. */
  x: number;
  y: number;
  /** radial: radius in shares of the picture's short edge (0.05…1.5). */
  radius: number;
  /** The fade's width: linear, a share of the picture across it; radial, a share of the radius (0…1). */
  feather: number;
}

export const SCENE_LAYER_DEFAULT: SceneLayer = {
  enabled: true,
  kind: 'linear',
  exposure: -1,
  warmth: 0,
  opacity: 1,
  invert: false,
  angle: 0,
  x: 0.5,
  y: 0.4,
  radius: 0.4,
  feather: 0.5,
};
export const MAX_SCENE_LAYERS = 8;

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

export function decodeSceneLayers(raw: unknown): SceneLayer[] {
  if (!Array.isArray(raw)) return [];
  const d = SCENE_LAYER_DEFAULT;
  return raw.slice(0, MAX_SCENE_LAYERS).map((r) => {
    const o = r && typeof r === 'object' ? (r as Record<string, unknown>) : {};
    return {
      enabled: o.enabled !== false,
      kind: (SCENE_LAYER_KINDS as readonly string[]).includes(o.kind as string) ? (o.kind as SceneLayerKind) : d.kind,
      exposure: clamp(num(o.exposure, d.exposure), -3, 3),
      warmth: clamp(num(o.warmth, d.warmth), -100, 100),
      opacity: clamp(num(o.opacity, d.opacity), 0, 1),
      invert: o.invert === true,
      angle: num(o.angle, d.angle) % 360,
      x: clamp(num(o.x, d.x), -0.5, 1.5),
      y: clamp(num(o.y, d.y), -0.5, 1.5),
      radius: clamp(num(o.radius, d.radius), 0.05, 1.5),
      feather: clamp(num(o.feather, d.feather), 0, 1),
    };
  });
}

/** The layers the engine is handed: switched on and moving something. */
export const activeLayers = (ls: readonly SceneLayer[] | undefined) =>
  (ls ?? []).filter((l) => l.enabled && l.opacity > 0 && (l.exposure !== 0 || l.warmth !== 0));

/** The wire's stamp: names this set of masks and gains ('' none). */
export function sceneLayersStamp(ls: readonly SceneLayer[] | undefined): string {
  const a = activeLayers(ls);
  if (!a.length) return '';
  const s = JSON.stringify(a);
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
  return 'L' + h.toString(16).padStart(8, '0');
}

const smooth = (e0: number, e1: number, x: number) => {
  if (e1 <= e0) return x < e0 ? 0 : 1;
  const t = clamp((x - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
};

/**
 * A layer's mask as the engine takes it: a 16-bit plane over the picture (S), `w` × `h` texels, row-major,
 * top row first. Coordinates are measured in the picture's short edge so circles stay round.
 */
export function maskPlane(l: SceneLayer, w: number, h: number): Uint16Array {
  const out = new Uint16Array(w * h);
  const short = Math.min(w, h);
  const th = (l.angle * Math.PI) / 180;
  const dx = Math.sin(th), dy = -Math.cos(th);   // 0 deg: the mask covers the top (a sky)
  // linear: the fade across the picture's extent along the direction
  const extent = Math.abs(dx) * w + Math.abs(dy) * h;
  const fw = Math.max(1e-3, l.feather) * extent;
  for (let j = 0; j < h; j++)
    for (let i = 0; i < w; i++) {
      const px = i + 0.5, py = j + 0.5;
      let m: number;
      if (l.kind === 'whole') m = 1;
      else if (l.kind === 'radial') {
        const r = l.radius * short;
        const d = Math.hypot(px - l.x * w, py - l.y * h);
        m = 1 - smooth(r * (1 - l.feather), r, d);
      } else {
        const along = (px - l.x * w) * dx + (py - l.y * h) * dy;
        m = smooth(-fw / 2, fw / 2, along);
      }
      if (l.invert) m = 1 - m;
      out[j * w + i] = Math.round(clamp(m, 0, 1) * 65535);
    }
  return out;
}

/** The plane's size for a picture of `aspect` (width / height): 512 texels on its long edge. */
export function planeSize(aspect: number): { w: number; h: number } {
  const L = 512;
  return aspect >= 1 ? { w: L, h: Math.max(8, Math.round(L / aspect)) } : { w: Math.max(8, Math.round(L * aspect)), h: L };
}

/**
 * The host's `scene_layers` request for the active layers: each layer's three natural-log cone gains (the
 * exposure on all three, warmth raising the long-wave cone and lowering the short) and its coverage, and
 * every plane in turn as the payload.
 */
export function sceneLayersRequest(ls: readonly SceneLayer[] | undefined, aspect: number) {
  const a = activeLayers(ls);
  const { w, h } = planeSize(aspect);
  const planes = a.map((l) => maskPlane(l, w, h));
  const payload = new Uint8Array(planes.length * w * h * 2);
  planes.forEach((p, k) => payload.set(new Uint8Array(p.buffer, p.byteOffset, p.byteLength), k * w * h * 2));
  const layers = a.map((l) => {
    const e = l.exposure * Math.LN2, warm = (l.warmth / 100) * 0.25;
    return { width: w, height: h, log_gain: [e + warm, e, e - warm], coverage: clamp(l.opacity, 0, 1) };
  });
  return { stamp: sceneLayersStamp(ls), layers, payload };
}
