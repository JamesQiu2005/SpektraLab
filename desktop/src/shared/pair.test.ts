import { describe, expect, it } from 'vitest';
import { GEOMETRY_DEFAULT } from './geometry';
import { decodePair, encodePair, newPair, newHole, pairLayout, pairRects, pairWithMeterReadings, placementSourceRect, sourcePairLayout, draggedPlacement, zoomedPlacement } from './pair';
describe('half-frame source recipes', () => {
  it('merges a meter reading across placement/grade edits, but rejects changed source, decode, geometry or intent', () => {
    const requested = { ...newPair('/owned'), left: newHole('/owned/a.ARW') };
    const reading = { left: { width: 1, height: 1, available: true, metered_ev: 1.25, metered_for: 'native-source-key' } };
    const live = { ...requested, left: { ...requested.left, exposureEV: 2, placement: { ...requested.left.placement, x: .7, scale: 2 } } };
    expect(pairWithMeterReadings(live, requested, reading, 'balanced').left).toMatchObject({ exposureEV: 2, placement: { x: .7, scale: 2 }, meteredEV: 1.25, meteredFor: 'native-source-key' });
    for (const patch of [{ path: '/owned/b.ARW' }, { decode: { ...live.left.decode, whiteBalance: 'Custom', temperature: 6100 } },
      { geometry: { ...live.left.geometry, angle: .1 } }, { meterMethod: 'center' }, { autoExposure: false }]) {
      const changed = { ...live, left: { ...live.left, ...patch } };
      expect(pairWithMeterReadings(changed, requested, reading, 'balanced')).toBe(changed);
    }
    expect(pairWithMeterReadings(live, requested, reading, 'center', 'balanced')).toBe(live);
    for (const ev of [NaN, Infinity, 65]) expect(pairWithMeterReadings(live, requested, { left: { ...reading.left, metered_ev: ev } }, 'balanced')).toBe(live);
    expect(pairWithMeterReadings(live, requested, { left: { ...reading.left, metered_for: '' } }, 'balanced')).toBe(live);
  });
  it('reads older Mac recipes with optional fields and refuses recursive pairs/nonfinite input', () => {
    const p = decodePair({ folder: '/owned', left: { path: '/owned/a.ARW', placement: { scale: 99, x: -9, y: NaN, quarterTurns: -1 } } })!;
    expect(p.left).toMatchObject({ exposureEV: 0, placement: { scale: 4, x: -1, y: 0, quarterTurns: 3 }, printScope: 'film', exposureScope: 'frame' });
    expect(p.right).toBeNull();
    expect(decodePair(encodePair(p))).toEqual(p);
    expect(decodePair({ folder: '/owned', left: { path: '/owned/a.spektrapair' } })).toBeNull();
    expect(decodePair({ folder: '/owned', schemaVersion: 2 })).toBeNull();
  });
  it('follows the physical 18×24 holes and 1 mm camera advance, including turned layouts', () => {
    expect(pairLayout(2400)).toMatchObject({ hole: { width: 1800, height: 2400 }, advance: 1900, size: { width: 3700, height: 2400 } });
    expect(pairLayout(2400, 1, true)).toMatchObject({ hole: { width: 2400, height: 1800 }, size: { width: 2400, height: 3700 }, rects: { right: { x: 0, y: 1900 } } });
    const p = { ...newPair('/owned'), spacingMM: 2, onStrip: true };
    expect(pairRects(p).right.x).toBeCloseTo(19 / 37, 12);
    expect(pairRects({ ...p, onStrip: false }).right.x).toBeCloseTo(20 / 38, 12);
  });
  it('bounds combined native size by the longest original and does not change pixel pitch on placement zoom/spacing', () => {
    const p = { ...newPair('/owned'), left: newHole('/owned/a.ARW'), right: newHole('/owned/b.ARW') };
    const sizes = { left: { width: 8256, height: 5504 }, right: { width: 6000, height: 4000 } };
    const l = sourcePairLayout(p, sizes);
    expect(Math.max(l.size.width, l.size.height)).toBeLessThanOrEqual(8256);
    const zoomed = { ...p, left: { ...p.left, placement: { ...p.left.placement, scale: 4 } }, spacingMM: 2 };
    expect(sourcePairLayout(zoomed, sizes).hole).toEqual(l.hole);
    const cropped = { ...p, right: { ...p.right, geometry: { ...GEOMETRY_DEFAULT, crop: { x: .25, y: .25, width: .5, height: .5 } } } };
    expect(sourcePairLayout(cropped, sizes).hole.height).toBe(2000);
  });
  it('keeps the zoom anchor fixed and clamps drags to source coverage for either orientation', () => {
    const p = { scale: 1.5, x: .1, y: -.2, quarterTurns: 0 }, source = { width: 6000, height: 4000 };
    for (const aspect of [.75, 4 / 3]) {
      const before = placementSourceRect(p, source, aspect), anchor = { x: .3, y: .7 };
      const next = zoomedPlacement(p, 1.2, anchor, source, aspect), after = placementSourceRect(next, source, aspect);
      expect(before.x + anchor.x * before.width).toBeCloseTo(after.x + anchor.x * after.width, 10);
      expect(before.y + anchor.y * before.height).toBeCloseTo(after.y + anchor.y * after.height, 10);
      const moved = draggedPlacement(p, { x: 100, y: -100 }, source, aspect);
      const cut = placementSourceRect(moved, source, aspect);
      expect(cut.x).toBeGreaterThanOrEqual(0); expect(cut.y).toBeGreaterThanOrEqual(0);
      expect(cut.x + cut.width).toBeLessThanOrEqual(source.width);
      expect(cut.y + cut.height).toBeLessThanOrEqual(source.height);
    }
  });
});
