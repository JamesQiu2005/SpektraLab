import { describe, expect, it } from 'vitest';
import { LENS_SLIDERS, decodeLensPick, decodeMyLenses, lensWire, pickOfMyLens, searchLenses, type LensEntry } from './lens';
import { decodeWire } from './whiteBalance';
import { DECODE_DEFAULT, decodeSidecar, encodeSidecar, newSidecar } from './sidecar';

const entry = (maker: string, model: string, f0: number, f1 = f0): LensEntry => ({
  maker, model, min_focal: f0, max_focal: f1, mounts: [], distortion: true, tca: false, vignetting: true,
});

describe('lens correction (lens.ts)', () => {
  it('sends nothing until it is on, and only what is set', () => {
    expect(decodeWire(DECODE_DEFAULT, false)).toBeNull();
    expect(decodeWire({ ...DECODE_DEFAULT, lensCorrection: true }, false)).toEqual({ lens_correction: true });
    const pick = { maker: 'Canon', model: 'Canon FD 50mm f/1.4 S.C.C.', focalMM: 50, aperture: 1.4, custom: null };
    expect(decodeWire({ ...DECODE_DEFAULT, lensCorrection: true, lens: pick }, true)).toEqual({
      white_balance: { mode: 'as_shot' }, lens_correction: true,
      lens: { maker: 'Canon', model: 'Canon FD 50mm f/1.4 S.C.C.', focal_mm: 50, aperture: 1.4 },
    });
  });
  it('sends a custom lens by its numbers', () => {
    const m = { name: 'Tokina RMC 500mm', focalMM: 500, aperture: 0, numbers: { distortion: 0, vignetting: -0.3, tcaR: 1, tcaB: 1 } };
    expect(lensWire(pickOfMyLens(m))).toEqual({
      maker: 'My Lenses', model: 'Tokina RMC 500mm', focal_mm: 500,
      custom: { distortion: 0, vignetting: -0.3, tca_r: 1, tca_b: 1 },
    });
  });
  it('keeps the pick in the photo, numbers clamped to the host ranges', () => {
    const s = newSidecar();
    s.decode = { ...s.decode, lensCorrection: true, lens: { maker: 'My Lenses', model: 'Helios', focalMM: 58, aperture: 2, custom: { distortion: 0.5, vignetting: -0.2, tcaR: 1, tcaB: 1 } } };
    const back = decodeSidecar(JSON.parse(JSON.stringify(encodeSidecar(s))));
    expect(back.decode.lens?.model).toBe('Helios');
    expect(back.decode.lens?.custom?.distortion).toBe(0.2);
    expect(decodeLensPick({ maker: 'x' })).toBeNull();
  });
  it('reads My Lenses tolerantly', () => {
    expect(decodeMyLenses([{ name: 'A' }, { name: 'A' }, { name: '' }, 3, { name: ' B ', numbers: { tcaR: 2 } }])).toEqual([
      { name: 'A', focalMM: 0, aperture: 0, numbers: { distortion: 0, vignetting: 0, tcaR: 1, tcaB: 1 } },
      { name: 'B', focalMM: 0, aperture: 0, numbers: { distortion: 0, vignetting: 0, tcaR: 1.01, tcaB: 1 } },
    ]);
  });
  it('finds a lens by every word, whole numbers first', () => {
    const list = [entry('Canon', 'Canon FD 500mm f/8', 500), entry('Canon', 'Canon FD 50mm f/1.4 S.C.C.', 50), entry('Nikon', 'Nikkor 50mm f/1.4', 50)];
    expect(searchLenses(list, 'fd 50').map((e) => e.model)).toEqual(['Canon FD 50mm f/1.4 S.C.C.', 'Canon FD 500mm f/8']);
    expect(searchLenses(list, '')).toEqual([]);
  });
  it('maps the sliders both ways', () => {
    for (const s of [LENS_SLIDERS.distortion, LENS_SLIDERS.corners, LENS_SLIDERS.fringe])
      for (const v of [s.range[0], 0, s.range[1]]) expect(s.fromNumber(s.toNumber(v))).toBeCloseTo(v, 6);
  });
});
