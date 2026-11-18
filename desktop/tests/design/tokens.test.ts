// The tokens are the drawing's: every colour is one the pages fill or stroke
// with, and the window's rectangles are where PC-E1 draws its walls.

import { describe, expect, it } from 'vitest';
import { colours, geometry } from '../../src/theme/tokens';
import { designFiles, normal, readIndex, readPage } from './svg';

const edit = readPage('win_edit.svg');
const everyColour = new Set(designFiles().flatMap((f) => [...readPage(f).colours]));

describe('design tokens', () => {
  it('reads the 34 pages INDEX.md lists, every one present as a file', () => {
    const rows = readIndex();
    expect(rows).toHaveLength(34);
    const files = new Set(designFiles());
    for (const r of rows) expect(files.has(r.file), r.file).toBe(true);
  });

  it.each(Object.entries(colours))('colour %s is one the pages use', (_name, value) => {
    // The two flyout/danger colours are drawn on the pages that show them.
    expect(everyColour.has(normal(value)), value).toBe(true);
  });

  it('the window is 1536 × 816 epx, the title bar 32', () => {
    expect([edit.width, edit.height]).toEqual([1536, 816]);
    const bar = edit.lines.find((l) => l.y1 === l.y2 && l.x1 === 0 && l.x2 === 1536);
    expect(bar?.stroke).toBe(normal(colours.wall));
    expect(Math.round(bar!.y1)).toBe(geometry.titleBar);
  });

  it('the rails are 320 each, walled in the wall colour, and the filmstrip 80', () => {
    const walls = edit.lines.filter((l) => l.x1 === l.x2 && l.stroke === normal(colours.wall)).map((l) => Math.floor(l.x1));
    expect(walls).toContain(geometry.rail);
    expect(walls).toContain(1536 - geometry.rail - 1);
    const strip = edit.lines.find((l) => l.y1 === l.y2 && l.x1 === 321 && l.x2 === 1215 && l.y1 > 600);
    expect(816 - Math.round(strip!.y1)).toBe(geometry.filmstrip);
    const toolbar = edit.lines.find((l) => l.y1 === l.y2 && l.x1 === 321 && l.x2 === 1215 && l.y1 < 100);
    expect(Math.round(toolbar!.y1) - geometry.titleBar).toBe(geometry.toolbar);
  });

  it('labels are 14 Semibold and the least type is 12 (README §2)', () => {
    const sizes = new Set(edit.texts.filter((t) => t.y > 32).map((t) => t.size));
    expect(Math.min(...sizes)).toBe(12);
    const develop = edit.texts.find((t) => t.text === 'Develop')!;
    expect([develop.size, develop.weight]).toEqual([14, 600]);
  });
});
