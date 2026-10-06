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
});
