// svg.ts — read a page of the Windows design (`desktop/design/windows/*.svg`)
// into absolute shapes: texts, lines and rectangles, each with the
// translation of the groups around it applied. The pages are written by the
// design's generator in a small, regular dialect (translate-only groups,
// embedded pictures as data URIs), so a regular-expression reader is enough
// and needs no DOM. Used by the token test (vitest) and the design
// conformance cases (Playwright).

import { readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const DESIGN_DIR = resolve(dirname(fileURLToPath(import.meta.url)), '../../design/windows');

export interface SvgText { x: number; y: number; text: string; size: number; weight: number; fill: string; anchor: string }
export interface SvgLine { x1: number; y1: number; x2: number; y2: number; stroke: string }
export interface SvgRect { x: number; y: number; width: number; height: number; fill: string; stroke: string }
export interface SvgPage { file: string; width: number; height: number; title: string; texts: SvgText[]; lines: SvgLine[]; rects: SvgRect[]; colours: Set<string> }

const num = (a: string, k: string) => {
  const m = new RegExp(`(?:^|\\s)${k}="([-\\d.]+)"`).exec(a);
  return m ? Number(m[1]) : 0;
};
const str = (a: string, k: string) => new RegExp(`(?:^|\\s)${k}="([^"]*)"`).exec(a)?.[1] ?? '';
const decode = (s: string) => s.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&#39;/g, "'");

export function readPage(file: string): SvgPage {
  const raw = readFileSync(join(DESIGN_DIR, file), 'utf8').replace(/data:image\/[^"]+/g, '');
  const head = /<svg ([^>]*)>/.exec(raw)?.[1] ?? '';
  const page: SvgPage = {
    file, width: num(head, 'width'), height: num(head, 'height'),
    title: decode(/<title>([^<]*)<\/title>/.exec(raw)?.[1] ?? ''),
    texts: [], lines: [], rects: [], colours: new Set(),
  };
  for (const m of raw.matchAll(/(?:fill|stroke|stop-color)="(#[0-9A-Fa-f]{3,6})"/g)) page.colours.add(normal(m[1]!));
  const stack: [number, number][] = [[0, 0]];
  const re = /<g(\s[^>]*)?>|<\/g>|<text ([^>]*)>([^<]*)<\/text>|<line ([^>]*?)\/?>|<rect ([^>]*?)\/?>/g;
  for (const m of raw.matchAll(re)) {
    const [ox, oy] = stack[stack.length - 1]!;
    if (m[0].startsWith('<g')) {
      const t = /translate\(([-\d.]+)[ ,]+([-\d.]+)\)/.exec(m[1] ?? '');
      stack.push(t ? [ox + Number(t[1]), oy + Number(t[2])] : [ox, oy]);
    } else if (m[0] === '</g>') {
      if (stack.length > 1) stack.pop();
    } else if (m[2] !== undefined) {
      const a = m[2];
      page.texts.push({ x: ox + num(a, 'x'), y: oy + num(a, 'y'), text: decode(m[3] ?? '').trim(), size: num(a, 'font-size'),
        weight: num(a, 'font-weight') || 400, fill: normal(str(a, 'fill')), anchor: str(a, 'text-anchor') || 'start' });
    } else if (m[4] !== undefined) {
      const a = m[4];
      page.lines.push({ x1: ox + num(a, 'x1'), y1: oy + num(a, 'y1'), x2: ox + num(a, 'x2'), y2: oy + num(a, 'y2'), stroke: normal(str(a, 'stroke')) });
    } else if (m[5] !== undefined) {
      const a = m[5];
      page.rects.push({ x: ox + num(a, 'x'), y: oy + num(a, 'y'), width: num(a, 'width'), height: num(a, 'height'), fill: normal(str(a, 'fill')), stroke: normal(str(a, 'stroke')) });
    }
  }
  return page;
}

/** `#000` → `#000000`, upper case. */
export function normal(c: string): string {
  if (!c.startsWith('#')) return c;
  const h = c.slice(1);
  return '#' + (h.length === 3 ? h.split('').map((x) => x + x).join('') : h).toUpperCase();
}

/** The first text whose content is `text` (and, optionally, near a point). */
export function findText(p: SvgPage, text: string, near?: { x?: number; y?: number }): SvgText | undefined {
  const all = p.texts.filter((t) => t.text === text);
  if (!near) return all[0];
  const d = (t: SvgText) => Math.abs((near.x ?? t.x) - t.x) + Math.abs((near.y ?? t.y) - t.y);
  return all.sort((a, b) => d(a) - d(b))[0];
}

/** The design's page table: id, title, file — from INDEX.md, the generator's own list. */
export interface IndexRow { id: string; page: string; file: string; lane: string }
export function readIndex(): IndexRow[] {
  const md = readFileSync(join(DESIGN_DIR, 'INDEX.md'), 'utf8');
  const rows: IndexRow[] = [];
  for (const line of md.split('\n')) {
    const m = /^\| (PC-[A-Z]\d+) \| (.+?) \| \[([^\]]+)\]\([^)]+\) \| (.+?) \|/.exec(line);
    if (m) rows.push({ id: m[1]!, page: m[2]!, file: m[3]!, lane: m[4]! });
  }
  return rows;
}

export const designFiles = () => readdirSync(DESIGN_DIR).filter((f) => f.endsWith('.svg'));
