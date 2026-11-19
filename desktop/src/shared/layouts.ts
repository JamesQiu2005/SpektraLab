// layouts.ts — Develop's multi-photo layouts: several developed photographs on one print, the way
// photographers lay out diptychs, triptychs, contact-sheet grids and cinematic stills, with a gap between
// them and a border round them. Pure layout: where each cell is on the sheet. The pixels are made by
// export/layoutExport.ts (each photograph developed with its own settings) and previewed by LayoutPage.
//
// A template is cells in a unit square of the sheet's inner area (inside the border), before the gaps.
// A sheet's shape is a template's own (a cinematic stack: its frames' shape and count) or one chosen.

export interface CellBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface LayoutTemplate {
  id: string;
  name: string;
  /** Cells on a unit inner area: x, y, w, h in 0…1, gaps not yet taken. */
  cells: CellBox[];
  /** The sheet's own width over height, when the template has one (cinematic stacks). */
  aspect?: number;
}

const row = (n: number): CellBox[] => Array.from({ length: n }, (_, i) => ({ x: i / n, y: 0, w: 1 / n, h: 1 }));
const col = (n: number): CellBox[] => Array.from({ length: n }, (_, i) => ({ x: 0, y: i / n, w: 1, h: 1 / n }));
const grid = (c: number, r: number): CellBox[] =>
  Array.from({ length: c * r }, (_, i) => ({ x: (i % c) / c, y: Math.floor(i / c) / r, w: 1 / c, h: 1 / r }));

/** Cinema's widescreen, 2.39:1. */
export const SCOPE = 2.39;

export const LAYOUT_TEMPLATES: LayoutTemplate[] = [
  { id: 'diptych-h', name: 'Diptych, side by side', cells: row(2) },
  { id: 'diptych-v', name: 'Diptych, stacked', cells: col(2) },
  { id: 'triptych-h', name: 'Triptych, side by side', cells: row(3) },
  { id: 'triptych-v', name: 'Triptych, stacked', cells: col(3) },
  { id: 'feature-left', name: 'One large, two small', cells: [{ x: 0, y: 0, w: 2 / 3, h: 1 }, { x: 2 / 3, y: 0, w: 1 / 3, h: 0.5 }, { x: 2 / 3, y: 0.5, w: 1 / 3, h: 0.5 }] },
  { id: 'feature-top', name: 'One wide, two below', cells: [{ x: 0, y: 0, w: 1, h: 0.6 }, { x: 0, y: 0.6, w: 0.5, h: 0.4 }, { x: 0.5, y: 0.6, w: 0.5, h: 0.4 }] },
  { id: 'grid-2x2', name: 'Grid, 2 × 2', cells: grid(2, 2) },
  { id: 'grid-3x2', name: 'Grid, 3 × 2', cells: grid(3, 2) },
  { id: 'grid-3x3', name: 'Grid, 3 × 3', cells: grid(3, 3) },
  { id: 'cinema-2', name: 'Cinematic, 2 stills', cells: col(2), aspect: SCOPE / 2 },
  { id: 'cinema-3', name: 'Cinematic, 3 stills', cells: col(3), aspect: SCOPE / 3 },
  { id: 'cinema-4', name: 'Cinematic, 4 stills', cells: col(4), aspect: SCOPE / 4 },
  { id: 'cinema-strip', name: 'Cinematic, 3 across', cells: row(3), aspect: SCOPE * 3 },
];

export const LAYOUT_ASPECTS: { id: string; name: string; value: number | null }[] = [
  { id: 'auto', name: 'The template’s', value: null },
  { id: '1:1', name: '1:1', value: 1 },
  { id: '4:5', name: '4:5', value: 4 / 5 },
  { id: '5:4', name: '5:4', value: 5 / 4 },
  { id: '2:3', name: '2:3', value: 2 / 3 },
  { id: '3:2', name: '3:2', value: 3 / 2 },
  { id: '9:16', name: '9:16', value: 9 / 16 },
  { id: '16:9', name: '16:9', value: 16 / 9 },
];

/** A photograph in its cell: its place under the window (−1…1 each way) and how far it is enlarged (1…4). */
export interface CellPhoto {
  path: string;
  panX: number;
  panY: number;
  zoom: number;
}

export interface LayoutDoc {
  template: string;
  cells: (CellPhoto | null)[];
  /** The gap between cells, in % of the sheet's short edge (0…10). */
  gap: number;
  /** The border round them, in % of the sheet's short edge (0…15). */
  margin: number;
  /** The gap and border's grey: 0 black … 1 white. */
  tone: number;
  /** A LAYOUT_ASPECTS id. */
  aspect: string;
  /** The exported sheet's long edge, px. */
  longEdge: number;
}

export const LAYOUT_DEFAULT: LayoutDoc = { template: 'triptych-h', cells: [], gap: 1.5, margin: 3, tone: 1, aspect: 'auto', longEdge: 4000 };

export const templateOf = (id: string): LayoutTemplate => LAYOUT_TEMPLATES.find((t) => t.id === id) ?? LAYOUT_TEMPLATES[0]!;

/**
 * The sheet's width over height. A cinematic template keeps each still at its own shape (2.39:1) whatever
 * the border and gaps: the sheet grows round them. Every other template takes the aspect chosen, or 3:2.
 */
export function sheetAspect(doc: LayoutDoc): number {
  const chosen = LAYOUT_ASPECTS.find((a) => a.id === doc.aspect)?.value ?? null;
  if (chosen) return chosen;
  const t = templateOf(doc.template);
  if (!t.aspect) return 3 / 2;
  const rows = new Set(t.cells.map((c) => c.y)).size, cols = new Set(t.cells.map((c) => c.x)).size;
  const cell = (t.aspect * rows) / cols;   // one still's width over height
  // On a sheet 1 wide: everything scales with it, so solve for the height (the short edge sets the
  // border and gaps, so a few rounds settle it).
  const M = doc.margin / 100, G = doc.gap / 100;
  let h = 1 / t.aspect;
  for (let k = 0; k < 8; k++) {
    const sh = Math.min(1, h), m = M * sh, g = G * sh;
    const cw = (1 - 2 * m - (cols - 1) * g) / cols;
    h = 2 * m + rows * (cw / cell) + (rows - 1) * g;
  }
  return 1 / h;
}

/** The sheet's size in px for its long edge. */
export function sheetSize(doc: LayoutDoc, longEdge = doc.longEdge): { width: number; height: number } {
  const a = sheetAspect(doc);
  return a >= 1
    ? { width: Math.round(longEdge), height: Math.max(1, Math.round(longEdge / a)) }
    : { width: Math.max(1, Math.round(longEdge * a)), height: Math.round(longEdge) };
}

/** Each cell's rectangle on a sheet of `width` × `height` px: inside the border, less half a gap each side. */
export function cellRects(doc: LayoutDoc, width: number, height: number): { x: number; y: number; w: number; h: number }[] {
  const t = templateOf(doc.template);
  const short = Math.min(width, height);
  const m = (doc.margin / 100) * short, g = (doc.gap / 100) * short;
  const iw = width - 2 * m, ih = height - 2 * m;
  return t.cells.map((c) => {
    const left = c.x <= 1e-6 ? 0 : g / 2, right = c.x + c.w >= 1 - 1e-6 ? 0 : g / 2;
    const top = c.y <= 1e-6 ? 0 : g / 2, bottom = c.y + c.h >= 1 - 1e-6 ? 0 : g / 2;
    const x = Math.round(m + c.x * iw + left), y = Math.round(m + c.y * ih + top);
    const x2 = Math.round(m + (c.x + c.w) * iw - right), y2 = Math.round(m + (c.y + c.h) * ih - bottom);
    return { x, y, w: Math.max(1, x2 - x), h: Math.max(1, y2 - y) };
  });
}

/**
 * A photograph of `pw` × `ph` covering a cell of `cw` × `ch` at `zoom`, moved by its pan: the size to draw it
 * at and where its top-left lies relative to the cell (the part outside is cropped). The preview and the
 * export both place it with this.
 */
export function coverPlacement(pw: number, ph: number, cw: number, ch: number, photo: Pick<CellPhoto, 'panX' | 'panY' | 'zoom'>) {
  const k = Math.max(cw / pw, ch / ph) * Math.min(Math.max(photo.zoom, 1), 4);
  const w = Math.max(cw, Math.ceil(pw * k)), h = Math.max(ch, Math.ceil(ph * k));
  const sx = w - cw, sy = h - ch;
  const ox = -Math.round(sx * (0.5 + 0.5 * Math.min(Math.max(photo.panX, -1), 1))) || 0;
  const oy = -Math.round(sy * (0.5 + 0.5 * Math.min(Math.max(photo.panY, -1), 1))) || 0;
  return { w, h, ox, oy };
}

const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);
const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

export function decodeLayout(raw: unknown): LayoutDoc {
  const o = raw && typeof raw === 'object' ? (raw as Record<string, unknown>) : {};
  const d = LAYOUT_DEFAULT;
  const cells = Array.isArray(o.cells)
    ? o.cells.map((c) => {
        if (!c || typeof c !== 'object' || typeof (c as Record<string, unknown>).path !== 'string') return null;
        const p = c as Record<string, unknown>;
        return { path: p.path as string, panX: clamp(num(p.panX, 0), -1, 1), panY: clamp(num(p.panY, 0), -1, 1), zoom: clamp(num(p.zoom, 1), 1, 4) };
      })
    : [];
  return {
    template: LAYOUT_TEMPLATES.some((t) => t.id === o.template) ? (o.template as string) : d.template,
    cells,
    gap: clamp(num(o.gap, d.gap), 0, 10),
    margin: clamp(num(o.margin, d.margin), 0, 15),
    tone: clamp(num(o.tone, d.tone), 0, 1),
    aspect: LAYOUT_ASPECTS.some((a) => a.id === o.aspect) ? (o.aspect as string) : d.aspect,
    longEdge: clamp(Math.round(num(o.longEdge, d.longEdge)), 500, 12000),
  };
}
