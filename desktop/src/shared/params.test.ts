import { describe, expect, it } from 'vitest';
import schema from '../../mock-host/schema-fields.json';
import {
  ALL_FEATURES,
  FILM_PARAMS_DEFAULT,
  aeMethodOf,
  applyAEMethod,
  decodeFilmParams,
  delta,
  featureGate,
  filmFormatMM,
  fullDelta,
  withFrameSeed,
  printExposure,
  wire,
} from './params';

const fields = new Map((schema as { name: string; layer: string; type: string; range?: number[] }[]).map((f) => [f.name, f]));

describe('the wire', () => {
  it('names only fields the engine schema declares, on the engine layer, with the right types', () => {
    // Every feature on, every optional row present.
    const p = {
      ...FILM_PARAMS_DEFAULT,
      filmEdge: { ...FILM_PARAMS_DEFAULT.filmEdge, active: true },
      dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true },
    };
    for (const f of wire(p, ALL_FEATURES)) {
      const s = fields.get(f.name);
      expect(s, f.name).toBeDefined();
      expect(f.layer, f.name).toBe(s!.layer);
      const t = typeof f.value;
      const want = s!.type === 'bool' ? 'boolean' : s!.type === 'str' ? 'string' : 'number';
      expect(t, f.name).toBe(want);
      if (s!.range && typeof f.value === 'number') {
        expect(f.value).toBeGreaterThanOrEqual(s!.range[0]!);
        expect(f.value).toBeLessThanOrEqual(s!.range[1]!);
      }
    }
  });

  it('sends no row for a feature the host cannot do', () => {
    const gate = featureGate(['digital_intermediate', 'scene_latitude_mapping', 'contrast_mask', 'overscan', 'date_imprint']);
    const names = new Set(wire({ ...FILM_PARAMS_DEFAULT, digitalIntermediate: true }, gate).map((f) => f.name));
    for (const n of ['digital_intermediate', 'scene_latitude_active', 'contrast_mask_active', 'overscan_active', 'date_imprint_active'])
      expect(names.has(n), n).toBe(false);
    expect(names.has('film_stock')).toBe(true);
  });

  it('a print-side edit is a print-layer delta; a film change touches both layers', () => {
    const a = FILM_PARAMS_DEFAULT;
    const b = { ...a, printBrightnessStops: 1 };
    const d = delta(b, a);
    expect(Object.keys(d.delta)).toEqual(['print_exposure']);
    expect([...d.layers]).toEqual(['print']);
    expect(d.delta.print_exposure).toBeCloseTo(0.5);
    const c = { ...a, filmStock: 'kodak_gold_200' };
    expect([...delta(c, a).layers].sort()).toEqual(['print', 'shoot']);
    expect(Object.keys(delta(a, a).delta)).toHaveLength(0);
  });

  it('print exposure is 2^-stops, clamped', () => {
    expect(printExposure(0)).toBe(1);
    expect(printExposure(-10)).toBe(20);
    expect(printExposure(10)).toBe(0.05);
  });

  it('a legacy sidecar (no method) sends no auto_exposure_method', () => {
    const legacy = decodeFilmParams({ ...FILM_PARAMS_DEFAULT, autoExposureMethod: undefined });
    expect(legacy.autoExposureMethod).toBeNull();
    expect('auto_exposure_method' in fullDelta(legacy)).toBe(false);
    expect(aeMethodOf(legacy)).toBe('legacy');
    expect(aeMethodOf(applyAEMethod(legacy, 'custom'))).toBe('custom');
    expect(aeMethodOf(applyAEMethod(legacy, 'center'))).toBe('center');
  });

  it('decodes a sparse sidecar with defaults for the newer fields', () => {
    const p = decodeFilmParams({ filmStock: 'kodak_gold_200', printStock: 'x', autoExposureMethod: 'balanced', effects: { grain: 1.5 } });
    expect(p.filmStock).toBe('kodak_gold_200');
    expect(p.effects.grain).toBe(1.5);
    expect(p.effects.halation).toBe(1);
    expect(p.contrastMask.scale).toBe(0.03);
  });

  it('derives the long edge from the side and the photograph', () => {
    expect(filmFormatMM('short', 24, 1.5)).toBeCloseTo(36);
    expect(filmFormatMM('long', 36, 1.5)).toBe(36);
    expect(filmFormatMM('short', 56, 1)).toBe(56);
    expect(filmFormatMM('short', 56, 70 / 56)).toBeCloseTo(70);
  });
});

describe('light leak and lens (SpektraLab 2 LensEdge.swift)', () => {
  const names = new Set((schema as { name: string }[]).map((f) => f.name));
  const on = {
    ...FILM_PARAMS_DEFAULT,
    leak: { kind: 'band', amount: 2, edge: 1.5, seed: 77 },
    lens: { filter: 'cinebloom', strength: 0.25, character: 'plastic', amount: 0.5 },
  };
  it('sends only fields the engine has', () => {
    for (const f of [...Object.keys(fullDelta(FILM_PARAMS_DEFAULT)), ...Object.keys(fullDelta(on))]) expect(names.has(f), f).toBe(true);
  });
  it('is off by default, its switches still sent', () => {
    const d = fullDelta(FILM_PARAMS_DEFAULT);
    expect(d.leak_kind).toBe('off');
    expect(d.leak_edge).toBe(0);
    expect(d.diffusion_filter_active).toBe(false);
    expect(d.lens_aberrations_active).toBe(false);
    expect('diffusion_filter_family' in d).toBe(false);
    expect('lens_coma_um' in d).toBe(false);
  });
  it('lays a leak on a 135 gate with the film edge off', () => {
    const d = fullDelta(on, { ...ALL_FEATURES, overscan: false, dateImprint: false });
    expect(d).toMatchObject({ leak_kind: 'band', leak_amount: 2, leak_edge: 1.5, leak_seed: 77, overscan_format: '135' });
    expect(d.overscan_camera_seed).toBe(FILM_PARAMS_DEFAULT.filmEdge.cameraSeed);
    expect('overscan_active' in d).toBe(false);
  });
  it('scales the character by its amount, the field shape is the lens own', () => {
    const d = fullDelta(on);
    expect(d).toMatchObject({ diffusion_filter_active: true, diffusion_filter_family: 'cinebloom', diffusion_filter_strength: 0.25 });
    expect(d).toMatchObject({ lens_aberrations_active: true, lens_field_curvature_um: 17.5, lens_lateral_ca_r: 0.75, lens_lateral_ca_b: -0.75 });
    expect(d).toMatchObject({ lens_spherical_amount: 0.125, lens_spherical_um: 120, lens_loca_um: 5, lens_loca_sign: 'purple' });
  });
  it('decodes unknown names as off', () => {
    const p = decodeFilmParams({ leak: { kind: 'laser' }, lens: { filter: 'vaseline', character: 'fisheye' } });
    expect(p.leak.kind).toBe('off');
    expect(p.lens.filter).toBeNull();
    expect(p.lens.character).toBeNull();
  });
  it('turning a leak off reaches the engine', () => {
    const { delta: d } = delta(FILM_PARAMS_DEFAULT, on);
    expect(d).toMatchObject({ leak_kind: 'off', leak_edge: 0, diffusion_filter_active: false, lens_aberrations_active: false });
  });
});

describe('each photo its own leak (withFrameSeed)', () => {
  it('draws a frame seed once, the first time a leak is on', () => {
    const off = FILM_PARAMS_DEFAULT;
    expect(withFrameSeed(off, () => 0.5)).toBe(off);
    const on = { ...off, leak: { ...off.leak, kind: 'band' } };
    const a = withFrameSeed(on, () => 0.5);
    expect(a.filmEdge.seeded).toBe(true);
    expect(a.filmEdge.frameSeed).not.toBe(off.filmEdge.frameSeed);
    expect(withFrameSeed(a, () => 0.9)).toBe(a);
    const edge = withFrameSeed({ ...off, leak: { ...off.leak, edge: 1 } }, () => 0.25);
    expect(edge.filmEdge.seeded).toBe(true);
  });
});
