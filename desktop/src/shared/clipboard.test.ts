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
  it('copies Scene Placement intent and leaves a fresh identity until the target is fitted', () => {
    const source = structuredClone(src);
    source.params.sceneLatitude = { ...source.params.sceneLatitude, active: true, highlightPullBack: 4, shadowPullBack: 1,
      highlightKnee: -3, highlightRoom: 7, shadowKnee: -1, shadowRoom: 4 };
    const out = applyClip({ groups: ['scenePlacement'], settings: source, sourceName: 'a' }, newSidecar());
    expect(out.placementNeedsFit).toBe(true);
    expect(out.params.sceneLatitude).toMatchObject({ active: false, highlightPullBack: 4, shadowPullBack: 1,
      highlightRoom: 0, shadowRoom: 0, highlightKnee: 2, shadowKnee: -2 });
    expect(source.params.sceneLatitude.highlightRoom).toBe(7);
  });
});
