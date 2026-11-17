// items.ts — a page of the Windows design as drawing items: the icons it
// draws (glyphs) and the shapes it draws as controls (tiles, capsules,
// buttons, discs). `svg.ts` reads texts, lines and rectangles; this reads the
// rest, as an element tree, so a glyph drawn as a scale-about-centre group, a
// styled group or a bare path is one item at one place.
//
// Used by T2b (tests/e2e/design.spec.ts: every drawn glyph and control in a
// claimed region is built at its place, or is listed as not built) and by
// scripts/gen-glyphs.ts (which cuts the app's glyphs out of the same pages).

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { DESIGN_DIR, normal, readPage, type SvgText } from './svg';

const SHAPES = new Set(['path', 'circle', 'ellipse', 'rect', 'line', 'polyline', 'polygon']);
/** The drawing's ink: the colours a glyph is drawn in (text, labels, dim, ground on a white disc). */
const INK = new Set(['#F9F7F3', '#DAD8D4', '#FFFFFF', '#FAF8F4', '#898989', '#0F0E0E']);
/** The fills a control is drawn in: card, accent, white (selected), well, flyout, danger. */
const CONTROL_FILLS = new Set(['#2D2D2C', '#E1A95F', '#FFFFFF', '#1E1F1E', '#2A2A29', '#442726']);

export interface Node { tag: string; attrs: string; children: Node[]; offset: [number, number]; scaleAbout: boolean; start: number; end: number; raw: () => string }

export function parseTree(file: string): Node {
  const raw = readFileSync(join(DESIGN_DIR, file), 'utf8').replace(/data:image\/[^"]+/g, '');
  const mk = (tag: string, attrs: string, start: number, end: number, offset: [number, number], scaleAbout: boolean): Node => {
    const n: Node = { tag, attrs, children: [], offset, scaleAbout, start, end, raw: () => raw.slice(n.start, n.end) };
    return n;
  };
  const root = mk('#root', '', 0, raw.length, [0, 0], false);
  const stack: Node[] = [root];
  const tagRe = /<(\/?)([a-zA-Z][\w:-]*)([^>]*?)(\/?)>/g;
  let m: RegExpExecArray | null;
  while ((m = tagRe.exec(raw))) {
    const [all, close, tag, attrs, self] = m as unknown as [string, string, string, string, string];
    if (close) {
      for (let i = stack.length - 1; i > 0; i--) {
        if (stack[i]!.tag === tag) { stack[i]!.end = m.index + all.length; stack.length = i; break; }
      }
      continue;
    }
    const parent = stack[stack.length - 1]!;
    const tr = /\btransform="([^"]*)"/.exec(attrs)?.[1]?.trim() ?? '';
    const t = /^translate\(([-\d.]+)[ ,]+([-\d.]+)\)$/.exec(tr);
    const node = mk(tag, attrs, m.index, m.index + all.length,
      t ? [parent.offset[0] + Number(t[1]), parent.offset[1] + Number(t[2])] : parent.offset,
      /^translate\([^)]*\) scale\([^)]*\) translate\([^)]*\)$/.test(tr));
    parent.children.push(node);
    if (!self) stack.push(node);
  }
  return root;
}

export const attrNum = (a: string, k: string): number | undefined => { const r = new RegExp(`(?:^|\\s)${k}="([-\\d.]+)"`).exec(a); return r ? Number(r[1]) : undefined; };
const attrStr = (a: string, k: string) => new RegExp(`(?:^|\\s)${k}="([^"]*)"`).exec(a)?.[1] ?? '';

/** Where a node sits, in its own coordinates. */
export function anchorOf(node: Node): [number, number] | null {
  const a = node.attrs;
  const n = (k: string) => attrNum(a, k) ?? 0;
  switch (node.tag) {
    case 'circle': case 'ellipse': return [n('cx'), n('cy')];
    case 'rect': return [n('x') + n('width') / 2, n('y') + n('height') / 2];
    case 'line': return [(n('x1') + n('x2')) / 2, (n('y1') + n('y2')) / 2];
    case 'path': { const r = /\bd="M\s*([-\d.]+)[ ,]+([-\d.]+)/.exec(a); return r ? [Number(r[1]), Number(r[2])] : null; }
    case 'polygon': case 'polyline': { const r = /points="\s*([-\d.]+)[ ,]+([-\d.]+)/.exec(a); return r ? [Number(r[1]), Number(r[2])] : null; }
    case 'g': {
      const s = /translate\(([-\d.]+)[ ,]+([-\d.]+)\) scale/.exec(a);
      if (s) return [Number(s[1]), Number(s[2])];
      const pts = node.children.map(anchorOf).filter((p): p is [number, number] => !!p);
      if (!pts.length) return null;
      return [pts.reduce((t, p) => t + p[0], 0) / pts.length, pts.reduce((t, p) => t + p[1], 0) / pts.length];
    }
    default: return null;
  }
}

export interface Item { node: Node; at: [number, number] | null; def?: boolean }

/** Every drawing item of a page: a styled or scaled group is one; a bare shape is one; a moving group is looked through. */
export function itemsOf(file: string): Item[] {
  const out: Item[] = [];
  const abs = (c: Node, a: [number, number] | null): [number, number] | null => (a ? [a[0] + c.offset[0], a[1] + c.offset[1]] : null);
  const walk = (node: Node) => {
    for (const c of node.children) {
      if (c.tag === 'g') {
        const clipped = /clip-path=/.test(c.attrs);
        const pureMove = !c.scaleAbout && !/\b(stroke|fill)="/.test(c.attrs) && !clipped;
        if (pureMove || (clipped && !c.scaleAbout && !/\bstroke="/.test(c.attrs))) { walk(c); continue; }
        out.push({ node: c, at: abs(c, anchorOf(c)) });
      } else if (SHAPES.has(c.tag)) out.push({ node: c, at: abs(c, anchorOf(c)) });
      else if (c.tag === 'clipPath') out.push({ node: c, at: null, def: true });
      else if (c.tag !== 'text' && c.tag !== 'image' && c.tag !== 'use' && c.tag !== 'defs') walk(c);
    }
  };
  walk(parseTree(file));
  return out;
}

export interface Drawn {
  kind: 'glyph' | 'control';
  /** A glyph's centre; a control's box. */
  at: [number, number];
  box?: { x: number; y: number; width: number; height: number };
  /** `glyph "Brightness"`, `control "Export"`, or `glyph @1416,16` — what T2b reports and NOT_BUILT names. */
  name: string;
  /** The drawing text this item is placed against (the label inside it or under its tile, else the nearest on its row). */
  owner?: SvgText;
  /** That text and the others on its row, nearest first: the first one on screen places the item. */
  owners: SvgText[];
  /** The label the item is named by (inside it, or under its tile): when it is not on screen, neither is the item. */
  label?: SvgText;
}

const isInk = (c: string) => INK.has(normal(c));

/** A text's centre, estimated from its anchor and a Segoe-ish advance. */
export function textCentre(t: SvgText): [number, number] {
  const w = t.text.length * t.size * 0.55;
  const x = t.anchor === 'middle' ? t.x : t.anchor === 'end' ? t.x - w / 2 : t.x + w / 2;
  return [x, t.y - t.size * 0.35];
}
const textBox = (t: SvgText) => { const [cx, cy] = textCentre(t); const w = t.text.length * t.size * 0.55; return { l: cx - w / 2, r: cx + w / 2, t: cy - t.size / 2, b: cy + t.size / 2 }; };

/** The glyphs and controls a page draws, named after the text nearest each. */
export function drawnOf(file: string): Drawn[] {
  const page = readPage(file);
  const items = itemsOf(file);
  const out: Drawn[] = [];
  const dots: [number, number][] = [];
  for (const { node, at } of items) {
    if (!at) continue;
    const a = node.attrs, raw = node.raw();
    if (/<(use|image|text)\b/.test(raw)) continue;
    const fill = normal(attrStr(a, 'fill')).replace(/^none$/i, 'NONE'), stroke = normal(attrStr(a, 'stroke'));
    if (node.tag === 'circle') {
      const r = attrNum(a, 'r') ?? 0;
      if (r <= 1.5 && isInk(fill)) { dots.push(at); continue; }
      if (r >= 10 && r <= 22 && CONTROL_FILLS.has(fill)) {
        out.push({ kind: 'control', at, box: { x: at[0] - r, y: at[1] - r, width: 2 * r, height: 2 * r }, name: '', owners: [] });
        continue;
      }
      if (r >= 2 && fill === 'NONE' && isInk(stroke)) { out.push({ kind: 'glyph', at, name: '', owners: [] }); continue; }
      continue;
    }
    if (node.tag === 'rect') {
      const w = attrNum(a, 'width') ?? 0, h = attrNum(a, 'height') ?? 0, rx = attrNum(a, 'rx') ?? 0;
      // a control's face, or a chip (black, ruled: the filmstrip's count)
      const chip = fill === '#000000' && stroke === '#262625' && h >= 14;
      if (rx >= 6 && (CONTROL_FILLS.has(fill) || chip) && w >= 20 && h >= (chip ? 14 : 20) && w <= 420 && h <= 160 && !/(^|\s)opacity="0\./.test(a))
        out.push({ kind: 'control', at, box: { x: at[0] - w / 2, y: at[1] - h / 2, width: w, height: h }, name: '', owners: [] });
      continue;
    }
    if (node.tag === 'path') {
      const d = /\bd="([^"]*)"/.exec(a)?.[1] ?? '';
      if (d.length > 400 || (d.match(/[A-Za-z]/g)?.length ?? 0) > 30) continue; // a curve or a histogram, not an icon
      if ((fill === 'NONE' || fill === '') && isInk(stroke)) out.push({ kind: 'glyph', at, name: '', owners: [] });
      continue;
    }
    if (node.tag === 'g') {
      const inked = node.scaleAbout ? /(stroke|fill)="#(F9F7F3|DAD8D4|FFFFFF|0F0E0E|898989)"/i.test(raw) : isInk(stroke) || isInk(fill);
      if (inked && !/<rect[^>]*width="(\d{3,})/.test(raw)) out.push({ kind: 'glyph', at, name: '', owners: [] });
    }
  }
  // The ··· glyph is three dots: one item.
  dots.sort((p, q) => p[1] - q[1] || p[0] - q[0]);
  for (let i = 0; i < dots.length;) {
    let j = i + 1;
    while (j < dots.length && Math.abs(dots[j]![1] - dots[i]![1]) < 0.5 && dots[j]![0] - dots[j - 1]![0] < 8) j++;
    if (j - i >= 3) out.push({ kind: 'glyph', at: [(dots[i]![0] + dots[j - 1]![0]) / 2, dots[i]![1]], name: '', owners: [] });
    i = j;
  }
  // Names and owners. A tile is a face with its label under it; the glyph on it takes the same label.
  const texts = page.texts.filter((t) => t.text && t.size >= 9);
  const walls = page.lines.filter((l) => l.x1 === l.x2 && l.stroke === '#262625' && l.y2 - l.y1 > 400).map((l) => l.x1).sort((p, q) => p - q);
  const column = (x: number) => walls.filter((w) => w < x).length;
  const tiles = out.filter((d) => d.kind === 'control' && d.box && d.box.height >= 40 && d.box.width <= 80);
  const labelUnder = (box: { x: number; y: number; width: number; height: number }) => texts
    .filter((t) => { const [cx, cy] = textCentre(t); return Math.abs(cx - (box.x + box.width / 2)) < box.width / 2 + 6 && cy > box.y + box.height && cy - (box.y + box.height) < 24; })
    .sort((p, q) => textCentre(p)[1] - textCentre(q)[1])[0];
  for (const d of out) {
    const inside = d.box ? texts.filter((t) => { const [cx, cy] = textCentre(t); return cx > d.box!.x && cx < d.box!.x + d.box!.width && cy > d.box!.y && cy < d.box!.y + d.box!.height; }) : [];
    const tile = d.kind === 'control' && tiles.includes(d) ? d : tiles.find((t) => d.kind === 'glyph' && d.at[0] > t.box!.x && d.at[0] < t.box!.x + t.box!.width && d.at[1] > t.box!.y && d.at[1] < t.box!.y + t.box!.height);
    const under = tile ? labelUnder(tile.box!) : undefined;
    // Named by the label inside it or under its tile; anything else by its place, which the drawing fixes.
    const label = inside[0] ?? under;
    d.name = label ? `${d.kind} "${label.text}"` : `${d.kind} @${Math.round(d.at[0])},${Math.round(d.at[1])}`;
    d.label = under ?? undefined;
    // The owner: that label, else the nearest text on its row in its own column (rail, picture, rail).
    // (a row's text within reach: a toolbar glyph at one end is not placed against the crumb at the other)
    const row = texts.filter((t) => { const [cx, cy] = textCentre(t); return Math.abs(cy - d.at[1]) < 12 && column(cx) === column(d.at[0]) && dist(t, d.at) < 300; });
    // ... and, last, a caption just above it in its column (RATIO over the orientation pair)
    const above = texts.filter((t) => { const [cx, cy] = textCentre(t); const b = textBox(t); return cy < d.at[1] - 8 && d.at[1] - cy < 30 && column(cx) === column(d.at[0]) && b.l - 20 < d.at[0] && b.r + 40 > d.at[0]; });
    d.owners = [...(label ? [label] : []), ...row.filter((t) => t !== label).sort((p, q) => dist(p, d.at) - dist(q, d.at)),
      ...(label ? [] : above.sort((p, q) => dist(p, d.at) - dist(q, d.at)))];
    d.owner = d.owners[0];
  }
  // Two items of one name (a glyph drawn on a disc, say) get their places.
  const seen = new Map<string, number>();
  for (const d of out) seen.set(d.name, (seen.get(d.name) ?? 0) + 1);
  for (const d of out) if ((seen.get(d.name) ?? 0) > 1) d.name += ` @${Math.round(d.at[0])},${Math.round(d.at[1])}`;
  return out;
}

function dist(t: SvgText, p: [number, number]) {
  const b = textBox(t);
  const dx = p[0] < b.l ? b.l - p[0] : p[0] > b.r ? p[0] - b.r : 0;
  const dy = p[1] < b.t ? b.t - p[1] : p[1] > b.b ? p[1] - b.b : 0;
  return Math.hypot(dx, dy);
}
