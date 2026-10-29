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
  it('round-trips per-photo film bypass and removes the old true value when switched off', () => {
    expect(newSidecar().noFilm).toBe(false);
    expect(decodeSidecar(mac).noFilm).toBe(false);
    expect(decodeSidecar({ ...mac, noFilm: 'true' }).noFilm).toBe(false);
    const s = decodeSidecar({ ...mac, noFilm: true });
    expect(s.noFilm).toBe(true);
    expect(encodeSidecar(s).noFilm).toBe(true);
    expect(decodeSidecar(JSON.parse(JSON.stringify(encodeSidecar(s)))).noFilm).toBe(true);
    const off = encodeSidecar({ ...s, noFilm: false });
    expect(off).not.toHaveProperty('noFilm');
    expect(decodeSidecar(off).noFilm).toBe(false);
    expect(off.params).toEqual(encodeSidecar(decodeSidecar(mac)).params);
  });
  it('carries the revision of each editing snapshot independently through edits', () => {
    const oldToken = { key: 'D:/owned/a.json', base: 'a'.repeat(64) };
    const old = decodeSidecar({ ...mac, _spkRevision: oldToken });
    const fresh = decodeSidecar({ ...mac, _spkRevision: { ...oldToken, base: 'b'.repeat(64) } });
    const edited = { ...old, adjustments: { ...old.adjustments, exposure: 2 } };
    expect(encodeSidecar(edited)._spkRevision).toEqual(oldToken);
    expect(encodeSidecar(fresh)._spkRevision).not.toEqual(oldToken);
  });
  it('reads the Mac shape and keeps what it does not model', () => {
    const s = decodeSidecar(mac);
    expect(s.params.filmStock).toBe('kodak_portra_160');
    expect(s.params.autoExposure).toBe(false);
    expect(s.geometry.quarterTurns).toBe(1);
    expect(s.state).toBe('processed');
    const out = encodeSidecar(s);
    expect(out.masks).toEqual(mac.masks);
    expect(out.heldCrop).toMatchObject(mac.heldCrop);
    expect(decodeSidecar(out).heldCrop).toEqual(s.heldCrop);
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

  it('preserves newer nested parameters through edits, resets and repeated JSON saves', () => {
    const raw = {
      ...mac,
      params: { ...mac.params, futureFilmOption: { mode: 'new', curve: [0, 0.25, 1] },
        effects: { grain: 1.7, highlightHeadroom: 6, futureHalation: { active: true, weights: [1, 2] } },
        sceneLatitude: { highlightPullBack: 2, futureFit: { bounds: [-4, 5] } },
        dateBack: { text: 'old', futureFace: ['a', 'b'] } },
    };
    const original = JSON.stringify(raw);
    let s = decodeSidecar(raw);
    s = { ...s, params: { ...s.params, exposureCompensationEV: -2,
      effects: { ...s.params.effects, grain: 0 }, dateBack: { ...s.params.dateBack, text: '' } } };
    for (let i = 0; i < 3; i++) {
      const out = JSON.parse(JSON.stringify(encodeSidecar(s)));
      expect(out.params).toMatchObject({ exposureCompensationEV: -2,
        futureFilmOption: raw.params.futureFilmOption,
        effects: { grain: 0, highlightHeadroom: 6, futureHalation: raw.params.effects.futureHalation },
        sceneLatitude: { futureFit: raw.params.sceneLatitude.futureFit },
        dateBack: { text: '', futureFace: ['a', 'b'] } });
      s = decodeSidecar(out);
    }
    s = { ...s, params: newSidecar().params };
    expect(encodeSidecar(s).params).toMatchObject({ effects: { grain: 1, futureHalation: raw.params.effects.futureHalation },
      futureFilmOption: raw.params.futureFilmOption });
    expect(JSON.stringify(raw)).toBe(original);
  });

  it('lets current values replace saved false, null and array values without reviving removed state', () => {
    const s = decodeSidecar({ ...mac, params: { ...mac.params, autoExposure: true,
      autoExposureMethod: 'balanced', futureToggle: true, futureCurve: [0, 0.5, 1] },
      geometry: { ...mac.geometry, intendedSize: [400, 300], lockedRatio: 4 / 3 } });
    s.params = { ...s.params, autoExposure: false, autoExposureMethod: null,
      ...{ futureToggle: false, futureCurve: [0, 1] } };
    s.adjustments = newSidecar().adjustments;
    s.geometry = newSidecar().geometry;
    s.heldCrop = null;
    s.solvedEV = null;
    const out = encodeSidecar(s);
    expect(out.params).toMatchObject({ autoExposure: false, autoExposureMethod: null,
      futureToggle: false, futureCurve: [0, 1] });
    expect(out.adjustments).toEqual(newSidecar().adjustments);
    expect(out.geometry).not.toHaveProperty('intendedSize');
    expect(out.geometry).not.toHaveProperty('lockedRatio');
    expect(out).not.toHaveProperty('heldCrop');
    expect(out).not.toHaveProperty('solvedEV');
  });
});
