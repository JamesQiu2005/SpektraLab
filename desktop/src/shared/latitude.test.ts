import { describe, expect, it } from 'vitest';
import fixtures from './fixtures/latitude-fit.json';
import { SCENE_LATITUDE_DEFAULT } from './params';
import { applyLatitudeFit, fitPlacement, placementIntent, placementLanding, placementMessage, placementWindow,
  type LatitudeFit, type PlacementMeasured } from './latitude';
const measured: PlacementMeasured = { highlightExtreme: 7, highlightBoundary: 4, shadowExtreme: -8, shadowBoundary: -5 };

describe('Scene Placement against the engine CPU oracle', () => {
  it('matches 1,620 valid curves and first refusals across rolloff, lift bounds and scene widths', () => {
    expect(fixtures).toHaveLength(1620);
    for (const f of fixtures) {
      const at = { highlightExtreme: f.at[0]!, highlightBoundary: f.at[1]!, shadowExtreme: f.at[2]!, shadowBoundary: f.at[3]! };
      const result = fitPlacement(at, f.h, f.s, { ...SCENE_LATITUDE_DEFAULT, rolloff: f.rolloff, maxLift: f.maxLift });
      if (f.issue) expect(result.issue, JSON.stringify(f)).toMatchObject({ code: f.issue[0], side: f.issue[1] });
      else {
        expect(result.issue, JSON.stringify(f)).toBeUndefined();
        const p = result.placed!;
        [p.highlightKnee, p.highlightRoom, p.shadowKnee, p.shadowRoom].forEach((v, i) => expect(v).toBeCloseTo(f.curve![i]!, 9));
        expect(p.active).toBe(f.h > 0 || f.s > 0);
      }
    }
  });

  it('rounds accepted slider endpoints inward and leaves zero available', () => {
    for (const side of ['highlight', 'shadow'] as const) {
      const w = placementWindow(measured, side, 0, SCENE_LATITUDE_DEFAULT);
      expect(w.span).not.toBeNull();
      const [lo, hi] = w.span!;
      expect(lo).toBeGreaterThan(3);
      for (let x = lo; x <= hi; x += 0.01) {
        expect(fitPlacement(measured, side === 'highlight' ? x : 0, side === 'shadow' ? x : 0, SCENE_LATITUDE_DEFAULT).issue).toBeUndefined();
      }
      expect(placementLanding(w, 0)).toEqual({ value: 0, issue: null });
      expect(placementLanding(w, 0.25).value).toBe(lo);
      expect(placementLanding(w, 99).value).toBe(hi);
    }
  });

  it('does not fabricate a curve when the scene cannot fit or another side closes the window', () => {
    const w = placementWindow({ ...measured, highlightExtreme: 20 }, 'highlight', 0, SCENE_LATITUDE_DEFAULT);
    expect(w.span).toBeNull();
    expect(placementLanding(w, 8)).toMatchObject({ value: 0, issue: { code: 'no_window' } });
    expect(fitPlacement(measured, Number.NaN, 0, SCENE_LATITUDE_DEFAULT).issue?.code).toBe('out_of_range');
  });

  it('requires complete engine fit deltas and never carries a source photo curve into copied intent', () => {
    const source = { ...SCENE_LATITUDE_DEFAULT, active: true, highlightPullBack: 4, highlightKnee: -3, highlightRoom: 7 };
    expect(placementIntent(source)).toMatchObject({ active: false, highlightPullBack: 4, highlightRoom: 0, highlightKnee: 2 });
    expect(applyLatitudeFit(source, { valid: true } as LatitudeFit)).toBeNull();
    expect(applyLatitudeFit(source, { valid: false } as LatitudeFit)).toBeNull();
    expect(placementMessage({ code: 'knees_cross', side: 'both', message: '' }, 'highlight', null, true)).toContain('交叉');
  });
});
