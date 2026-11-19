import { describe, expect, it } from 'vitest';
import { applyClip, clipChanges } from './clipboard';
import { newSidecar } from './sidecar';

describe('settings clipboard', () => {
  const src = newSidecar();
  src.params = { ...src.params, filmStock: 'kodak_gold_200', printBrightnessStops: 1, grainActive: false };
  src.geometry = { ...src.geometry, quarterTurns: 1 };
  it('writes only the ticked groups, never geometry', () => {
    const out = applyClip({ groups: ['filmAndPaper'], settings: src, sourceName: 'a' }, newSidecar());
    expect(out.params.filmStock).toBe('kodak_gold_200');
    expect(out.params.printBrightnessStops).toBe(0);
    expect(out.params.grainActive).toBe(true);
    expect(out.geometry.quarterTurns).toBe(0);
  });
  it('reports a no-op', () => {
    expect(clipChanges({ groups: ['printEffects'], settings: src, sourceName: 'a' }, newSidecar())).toBe(false);
    expect(clipChanges({ groups: ['exposure'], settings: src, sourceName: 'a' }, newSidecar())).toBe(true);
  });
  it('carries Light Leak, Lens and Advanced; each photo keeps a leak of its own', () => {
    const a = newSidecar();
    a.params = {
      ...a.params,
      leak: { kind: 'band', amount: 2, edge: 0, seed: 0 },
      lens: { filter: 'pro_mist', strength: 1, character: null, amount: 1 },
      linuxAdvanced: { ...a.params.linuxAdvanced, developGamma: 1.2 },
      filmEdge: { ...a.params.filmEdge, frameSeed: 4242, seeded: true },
    };
    const out = applyClip({ groups: ['filmEffects'], settings: a, sourceName: 'a' }, newSidecar());
    expect(out.params.leak.kind).toBe('band');
    expect(out.params.lens.filter).toBe('pro_mist');
    expect(out.params.linuxAdvanced.developGamma).toBe(1.2);
    expect(out.params.filmEdge.seeded).toBe(true);
    expect(out.params.filmEdge.frameSeed).not.toBe(4242);
  });
  it('carries the lens choice for a whole shoot', () => {
    const a = newSidecar();
    a.decode = { ...a.decode, lensCorrection: true, lens: { maker: 'My Lenses', model: 'Tokina RMC 500mm', focalMM: 500, aperture: 8, custom: { distortion: 0, vignetting: -0.3, tcaR: 1, tcaB: 1 } } };
    const out = applyClip({ groups: ['lensCorrection'], settings: a, sourceName: 'a' }, newSidecar());
    expect(out.decode.lensCorrection).toBe(true);
    expect(out.decode.lens?.model).toBe('Tokina RMC 500mm');
    expect(out.decode.whiteBalance).toBe(newSidecar().decode.whiteBalance);
  });
});
