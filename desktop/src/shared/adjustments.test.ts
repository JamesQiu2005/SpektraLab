import { describe, expect, it } from 'vitest';
import {
  ADJUSTMENTS_DEFAULT,
  CURVE_IDENTITY,
  SRGB_MID_GREY,
  applyLayer2,
  decodeAdjustments,
  evaluateCurve,
  insertPoint,
  isNeutral,
  tonePosition,
} from './adjustments';

describe('layer 2', () => {
  it('is the identity at its defaults', () => {
    const data = new Float32Array([0.1, 0.5, 0.9, 1, 0.3, 0.3, 0.3, 1]);
    const copy = data.slice();
    applyLayer2(data, 2, 1, ADJUSTMENTS_DEFAULT, SRGB_MID_GREY);
    for (let i = 0; i < data.length; i++) expect(data[i]).toBeCloseTo(copy[i]!, 6);
    expect(isNeutral(ADJUSTMENTS_DEFAULT)).toBe(true);
  });

  it('a stop of exposure brightens mid-grey', () => {
    const data = new Float32Array([SRGB_MID_GREY, SRGB_MID_GREY, SRGB_MID_GREY, 1]);
    applyLayer2(data, 1, 1, { ...ADJUSTMENTS_DEFAULT, exposure: 1 }, SRGB_MID_GREY);
    expect(data[0]).toBeGreaterThan(SRGB_MID_GREY + 0.1);
  });

  it('pivots the tone regions on mid-grey', () => {
    expect(tonePosition(SRGB_MID_GREY, SRGB_MID_GREY)).toBeCloseTo(0.5);
    expect(tonePosition(0, SRGB_MID_GREY)).toBe(0);
    expect(tonePosition(1, SRGB_MID_GREY)).toBeCloseTo(1);
  });

  it('curves: the identity is the identity, a point bends it', () => {
    for (const x of [0, 0.25, 0.5, 1]) expect(evaluateCurve(CURVE_IDENTITY, x)).toBeCloseTo(x, 6);
    const { curve } = insertPoint(CURVE_IDENTITY, 0.5, 0.7);
    expect(evaluateCurve(curve, 0.5)).toBeCloseTo(0.7, 6);
  });

  it('decodes Swift curves (CGPoint as [x, y])', () => {
    const a = decodeAdjustments({ curves: { rgb: { points: [[0, 0], [0.5, 0.6], [1, 1]] } }, exposure: 0.5 });
    expect(a.curves.rgb.points).toHaveLength(3);
    expect(a.exposure).toBe(0.5);
    expect(a.enabled).toBe(true);
  });
});
