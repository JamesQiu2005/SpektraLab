import { describe, expect, it } from 'vitest';
import { LAYOUT_DEFAULT, SCOPE, cellRects, coverPlacement, decodeLayout, sheetSize } from './layouts';

describe('multi-photo layouts', () => {
  it('a triptych is three equal cells inside the border, the gaps between them', () => {
    const doc = { ...LAYOUT_DEFAULT, template: 'triptych-h', aspect: '3:2', margin: 5, gap: 2 };
    const { width, height } = sheetSize(doc, 3000);
    expect([width, height]).toEqual([3000, 2000]);
    const r = cellRects(doc, width, height);
    expect(r).toHaveLength(3);
    expect(r[0]!.x).toBe(100);                       // 5 % of the short edge
    expect(r[1]!.x - (r[0]!.x + r[0]!.w)).toBeCloseTo(40, -1);   // 2 % gap
    expect(Math.abs(r[0]!.w - r[2]!.w)).toBeLessThanOrEqual(1);
  });
  it('keeps cinematic stills at 2.39:1 whatever the border and gap', () => {
    for (const margin of [0, 3, 8])
      for (const id of ['cinema-2', 'cinema-3', 'cinema-strip']) {
        const doc = { ...LAYOUT_DEFAULT, template: id, margin, gap: 2 };
        const { width, height } = sheetSize(doc, 4000);
        for (const c of cellRects(doc, width, height)) expect(c.w / c.h).toBeCloseTo(SCOPE, 1);
      }
  });
  it('covers its cell and pans inside the crop', () => {
    const p = coverPlacement(3000, 2000, 500, 500, { panX: 0, panY: 0, zoom: 1 });
    expect(p.h).toBe(500);
    expect(p.w).toBe(750);
    expect(p.ox).toBe(-125);
    expect(coverPlacement(3000, 2000, 500, 500, { panX: -1, panY: 0, zoom: 1 }).ox).toBe(0);
    expect(coverPlacement(3000, 2000, 500, 500, { panX: 1, panY: 0, zoom: 1 }).ox).toBe(-250);
  });
  it('reads a saved layout tolerantly', () => {
    const d = decodeLayout({ template: 'nope', cells: [{ path: '/a.ARW', zoom: 9 }, 3], gap: 50 });
    expect(d.template).toBe(LAYOUT_DEFAULT.template);
    expect(d.cells).toEqual([{ path: '/a.ARW', panX: 0, panY: 0, zoom: 4 }, null]);
    expect(d.gap).toBe(10);
  });
});
