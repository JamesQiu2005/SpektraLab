import { describe, expect, it } from 'vitest';
import { ADJUSTMENTS_DEFAULT, BORDER_DEFAULT, borderCode, borderPixels, decodeAdjustments, isNeutral } from '@shared/adjustments';
import { withBorder } from './exporter';

describe('the border', () => {
  it('is off by default, and a sidecar without one reads as none', () => {
    expect(ADJUSTMENTS_DEFAULT.border.enabled).toBe(false);
    expect(decodeAdjustments({}).border).toEqual(BORDER_DEFAULT);
    expect(isNeutral(ADJUSTMENTS_DEFAULT)).toBe(true);
    expect(isNeutral({ ...ADJUSTMENTS_DEFAULT, border: { ...BORDER_DEFAULT, enabled: true } })).toBe(false);
  });

  it('sizes each side by the long edge, the bottom deeper when asked', () => {
    const b = { enabled: true, tone: 1, size: 5, bottomExtra: 10 };
    expect(borderPixels(b, 6000, 4000)).toEqual({ left: 300, right: 300, top: 300, bottom: 900 });
    expect(borderPixels({ ...b, enabled: false }, 6000, 4000)).toEqual({ left: 0, right: 0, top: 0, bottom: 0 });
  });

  it("frames the picture without changing a pixel of it", () => {
    const w = 4, h = 3;
    const px = new Uint16Array(w * h * 4);
    for (let i = 0; i < px.length; i++) px[i] = (i * 977) % 65536;
    const a = { ...ADJUSTMENTS_DEFAULT, border: { enabled: true, tone: 0, size: 25, bottomExtra: 25 } };
    const f = withBorder(px, { width: w, height: h }, a, 'sRGB');
    expect(f.width).toBe(w + 2);          // 25 % of 4 = 1 each side
    expect(f.height).toBe(h + 1 + 2);     // top 1, bottom 1 + 1
    for (let y = 0; y < h; y++)
      for (let x = 0; x < w; x++)
        for (let c = 0; c < 4; c++) expect(f.px[((y + 1) * f.width + x + 1) * 4 + c]).toBe(px[(y * w + x) * 4 + c]);
    expect(Array.from(f.px.subarray(0, 4))).toEqual([0, 0, 0, 65535]);
  });

  it('writes white and black exactly in every space, and a grey in each space’s own curve', () => {
    for (const s of ['sRGB', 'display-p3', 'prophoto'] as const) {
      expect(borderCode(1, s)).toBeCloseTo(1, 12);
      expect(borderCode(0, s)).toBe(0);
    }
    expect(borderCode(0.5, 'sRGB')).toBe(0.5);
    // sRGB 0.5 is linear 0.214; ProPhoto encodes that as 0.214^(1/1.8)
    expect(borderCode(0.5, 'prophoto')).toBeCloseTo(Math.pow(Math.pow((0.5 + 0.055) / 1.055, 2.4), 1 / 1.8), 9);
  });
});
