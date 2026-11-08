import { describe, expect, it } from 'vitest';
import { decodeSidecar, encodeSidecar, newSidecar } from './sidecar';

// A sidecar as the macOS app writes it (abridged, real key names).
const mac = {
  schemaVersion: 3,
  decoder: 'coreimage',
  decode: { whiteBalance: 'As Shot', temperature: 5500, tint: 0, lensCorrection: false },
  params: {
    filmStock: 'kodak_portra_160',
    printStock: 'kodak_2383',
    exposureCompensationEV: 0.6,
    autoExposureMethod: 'balanced',
    autoExposure: false,
    filmFormatMM: 36,
    filmFrame: '135',
    filmSide: 'short',
    sideLengthMM: 24,
    grainActive: true,
    halationActive: true,
    printBrightnessStops: 0,
    yFilterShift: 0,
    mFilterShift: 0,
    glareActive: true,
    scanFilm: false,
  },
  adjustments: { enabled: true, temperature: 0, tint: 0, exposure: 0.3 },
  geometry: { crop: { x: 0.1, y: 0.1, width: 0.8, height: 0.8 }, angle: -0.5, quarterTurns: 1, flipH: false, flipV: false, aspect: 'r3x2' },
  masks: [{ id: 'kept', kind: 'radial' }],
  heldCrop: { crop: { x: 0, y: 0, width: 1, height: 1 } },
  state: { processed: {} },
  source: { path: '/a/b.NEF', inode: 1, volumeID: 2, size: 3 },
};

describe('sidecar', () => {
  it('reads the Mac shape and keeps what it does not model', () => {
    const s = decodeSidecar(mac);
    expect(s.params.filmStock).toBe('kodak_portra_160');
    expect(s.params.autoExposure).toBe(false);
    expect(s.geometry.quarterTurns).toBe(1);
    expect(s.state).toBe('processed');
    const out = encodeSidecar(s);
    expect(out.masks).toEqual(mac.masks);
    expect(out.heldCrop).toEqual(mac.heldCrop);
    expect(out.state).toEqual({ processed: {} });
    expect((out.params as Record<string, unknown>).exposureCompensationEV).toBe(0.6);
  });

  it('a legacy `crop` becomes a geometry', () => {
    const s = decodeSidecar({ crop: { x: 0.2, y: 0, width: 0.5, height: 1 } });
    expect(s.geometry.crop.x).toBe(0.2);
    expect('crop' in encodeSidecar(s)).toBe(false);
  });

  it('a new sidecar round-trips', () => {
    const s = newSidecar();
    const back = decodeSidecar(JSON.parse(JSON.stringify(encodeSidecar(s))));
    expect(back.params).toEqual(s.params);
    expect(back.adjustments).toEqual(s.adjustments);
    expect(back.geometry).toEqual({ ...s.geometry });
  });
});
