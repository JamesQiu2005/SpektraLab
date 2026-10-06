import { describe, expect, it } from 'vitest';
import { DECODE_DEFAULT } from './sidecar';
import { applyBoxes, boxesOf, decodeWire, isRawPath, shownDecode, withPreset, withTemperature, withTint } from './whiteBalance';

const shot = { temperature: 4870, tint: 7.5 };

describe('the As Shot boxes (WhiteBalanceBoxes)', () => {
  it('read unticked and do nothing before a decode reported the camera pair', () => {
    expect(boxesOf(DECODE_DEFAULT, null)).toEqual({ temp: false, tint: false });
    expect(applyBoxes(DECODE_DEFAULT, null, { temp: false })).toBe(DECODE_DEFAULT);
  });
  it('As Shot reads both ticked and shows the camera pair', () => {
    expect(boxesOf(DECODE_DEFAULT, shot)).toEqual({ temp: true, tint: true });
    expect(shownDecode(DECODE_DEFAULT, shot)).toMatchObject({ temperature: 4870, tint: 7.5 });
  });
  it('dragging one axis is Custom; the other box stays ticked', () => {
    const d = withTemperature(DECODE_DEFAULT, shot, 6000);
    expect(d).toMatchObject({ whiteBalance: 'Custom', temperature: 6000, tint: 7.5 });
    expect(boxesOf(d, shot)).toEqual({ temp: false, tint: true });
  });
  it('a Custom value pinned to the camera reads ticked; ticking both is As Shot', () => {
    const d = withTint(withTemperature(DECODE_DEFAULT, shot, 6000), shot, 20);
    expect(boxesOf(d, shot)).toEqual({ temp: false, tint: false });
    const t = applyBoxes(d, shot, { temp: true });
    expect(t).toMatchObject({ whiteBalance: 'Custom', temperature: 4870, tint: 20 });
    expect(applyBoxes(t, shot, { tint: true }).whiteBalance).toBe('As Shot');
  });
  it('unticking leaves the value where it was, as Custom', () => {
    expect(applyBoxes(DECODE_DEFAULT, shot, { tint: false })).toMatchObject({ whiteBalance: 'Custom', temperature: 4870, tint: 7.5 });
  });
  it('a preset sets its own pair', () => {
    expect(withPreset(DECODE_DEFAULT, shot, 'Tungsten')).toMatchObject({ whiteBalance: 'Tungsten', temperature: 3200, tint: 0 });
    expect(withPreset({ ...DECODE_DEFAULT, whiteBalance: 'Shade', temperature: 7500 }, shot, 'As Shot')).toMatchObject({ temperature: 4870, tint: 7.5 });
  });
});

describe('the wire', () => {
  it('As Shot is the camera mode; everything else is custom numbers', () => {
    expect(decodeWire(DECODE_DEFAULT, true)).toEqual({ white_balance: { mode: 'as_shot' } });
    expect(decodeWire({ ...DECODE_DEFAULT, whiteBalance: 'Daylight', temperature: 5500, tint: 0 }, true)).toEqual({
      white_balance: { mode: 'custom', temperature_k: 5500, tint: 0 },
    });
  });
  it('a raster carries no decode white balance (the host refuses it)', () => {
    expect(decodeWire({ ...DECODE_DEFAULT, whiteBalance: 'Custom' }, false)).toBeNull();
    expect(isRawPath('/a/B.CR2')).toBe(true);
    expect(isRawPath('/a/b.tif')).toBe(false);
  });
});
