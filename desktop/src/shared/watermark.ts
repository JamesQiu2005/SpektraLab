// watermark.ts — Develop's text watermark: a signature or a copyright line laid over the finished picture,
// in the editor and in every exported file the same way (one drawing function for both: the canvas draws
// it at the size on screen, the export at the file's size).
//
// It sits on the picture, inside any border; its size is a share of the picture's short edge, so it reads
// the same at every export size. A grey tone, as the border's, so it means the same in every colour space.

export const WATERMARK_POSITIONS = ['tl', 'tc', 'tr', 'ml', 'mc', 'mr', 'bl', 'bc', 'br'] as const;
export type WatermarkPosition = (typeof WATERMARK_POSITIONS)[number];
export const WATERMARK_FONTS = ['sans', 'serif', 'mono', 'script'] as const;
export type WatermarkFont = (typeof WATERMARK_FONTS)[number];

export interface Watermark {
  enabled: boolean;
  text: string;
  font: WatermarkFont;
  bold: boolean;
  /** Cap height's share of the picture's short edge, in % (1…15). */
  size: number;
  /** 0 black … 1 white, as encoded on an sRGB display. */
  tone: number;
  /** 0…1. */
  opacity: number;
  position: WatermarkPosition;
  /** From the picture's edges, in % of its short edge (0…15). */
  margin: number;
}

export const WATERMARK_DEFAULT: Watermark = {
  enabled: false,
  text: '',
  font: 'sans',
  bold: false,
  size: 3,
  tone: 1,
  opacity: 0.7,
  position: 'br',
  margin: 3,
};

const FAMILY: Record<WatermarkFont, string> = {
  sans: '"Nimbus Sans", "Liberation Sans", "DejaVu Sans", sans-serif',
  serif: '"Nimbus Roman", "Liberation Serif", "DejaVu Serif", serif',
  mono: '"DejaVu Sans Mono", "Liberation Mono", monospace',
  script: '"URW Chancery L", "Z003", "TeX Gyre Chorus", cursive',
};

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

export function decodeWatermark(raw: unknown): Watermark {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const d = WATERMARK_DEFAULT;
  return {
    enabled: o.enabled === true,
    text: typeof o.text === 'string' ? o.text.slice(0, 200) : d.text,
    font: (WATERMARK_FONTS as readonly string[]).includes(o.font as string) ? (o.font as WatermarkFont) : d.font,
    bold: o.bold === true,
    size: clamp(num(o.size, d.size), 1, 15),
    tone: clamp(num(o.tone, d.tone), 0, 1),
    opacity: clamp(num(o.opacity, d.opacity), 0, 1),
    position: (WATERMARK_POSITIONS as readonly string[]).includes(o.position as string) ? (o.position as WatermarkPosition) : d.position,
    margin: clamp(num(o.margin, d.margin), 0, 15),
  };
}

export const watermarkShows = (w: Watermark | undefined): w is Watermark => !!w && w.enabled && w.text.trim().length > 0;

type Ctx2D = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

/**
 * Draws the watermark onto `ctx` over the picture's rectangle (x, y, w, h), in the watermark's grey at its
 * opacity. The editor passes the picture's place on screen, the export the file's picture area.
 */
export function drawWatermark(ctx: Ctx2D, x: number, y: number, w: number, h: number, wm: Watermark): void {
  if (!watermarkShows(wm) || w <= 0 || h <= 0) return;
  const short = Math.min(w, h);
  // the font size from the cap height wanted (a cap is about 0.72 of the em in these faces)
  const em = Math.max(1, (wm.size / 100) * short / 0.72);
  const margin = (wm.margin / 100) * short;
  ctx.save();
  ctx.font = `${wm.bold ? 'bold ' : ''}${em}px ${FAMILY[wm.font]}`;
  const g = Math.round(clamp(wm.tone, 0, 1) * 255);
  ctx.fillStyle = `rgb(${g},${g},${g})`;
  ctx.globalAlpha = clamp(wm.opacity, 0, 1);
  const col = wm.position[1] as 'l' | 'c' | 'r';
  const row = wm.position[0] as 't' | 'm' | 'b';
  ctx.textAlign = col === 'l' ? 'left' : col === 'c' ? 'center' : 'right';
  ctx.textBaseline = row === 't' ? 'top' : row === 'm' ? 'middle' : 'alphabetic';
  const tx = col === 'l' ? x + margin : col === 'c' ? x + w / 2 : x + w - margin;
  const ty = row === 't' ? y + margin : row === 'm' ? y + h / 2 : y + h - margin;
  ctx.fillText(wm.text, tx, ty);
  ctx.restore();
}

/**
 * The watermark blended into a file's RGBA16 pixels (the export, after the border): drawn white on an
 * OffscreenCanvas of the file's size, its coverage used as the alpha of the watermark's grey, encoded in the
 * file's space by `code` (0…1).
 */
export function blendWatermark(
  px: Uint16Array,
  width: number,
  height: number,
  picture: { x: number; y: number; width: number; height: number },
  wm: Watermark,
  code: (tone: number) => number,
): void {
  if (!watermarkShows(wm) || typeof OffscreenCanvas === 'undefined') return;
  const canvas = new OffscreenCanvas(width, height);
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  drawWatermark(ctx, picture.x, picture.y, picture.width, picture.height, { ...wm, tone: 1 });
  const cover = ctx.getImageData(0, 0, width, height).data;
  const v = Math.round(clamp(code(wm.tone), 0, 1) * 65535);
  for (let i = 0, n = width * height; i < n; i++) {
    const a = cover[i * 4 + 3]! / 255;
    if (a <= 0) continue;
    for (let c = 0; c < 3; c++) px[i * 4 + c] = Math.round(px[i * 4 + c]! * (1 - a) + v * a);
  }
}
