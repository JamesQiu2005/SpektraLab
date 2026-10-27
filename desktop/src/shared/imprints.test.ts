import { expect, it } from 'vitest';
import { FILM_PARAMS_DEFAULT, fullDelta } from './params';
import { resolveImprints, shootingLine } from './imprints';
import { GEOMETRY_DEFAULT } from './geometry';

it('uses the actual capture day without a time-zone shift or a fabricated current date', () => {
  const metadata = { datetime_original: '2026-10-01T23:58:00-12:00', aperture: 5.6 };
  const japan = resolveImprints(FILM_PARAMS_DEFAULT, metadata);
  expect(japan.dateBack.text).toBe("'26 10 1");
  expect(japan.filmEdge.fNumber).toBe(5.6);
  const us = resolveImprints({ ...FILM_PARAMS_DEFAULT, dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, order: 'us' } }, metadata);
  expect(us.dateBack.text).toBe("10 1 '26");
  expect(resolveImprints(FILM_PARAMS_DEFAULT, null).dateBack.text).toBe('');
  expect(resolveImprints(FILM_PARAMS_DEFAULT, { datetime_original: 'not a date' }).dateBack.text).toBe('');
  expect(FILM_PARAMS_DEFAULT.dateBack.text).toBe('');
});

it('prints the camera exposure, not the Film Exposure edit or an assumed 35mm equivalent', () => {
  expect(shootingLine({ shutter_s: 1/250, aperture: 5.6, exposure_program: 3, exposure_bias_ev: 0.333,
    focal_35mm: 24, iso: 800 })).toBe('1/250 F5.6 A +0.3 24mm');
  expect(shootingLine({ shutter_s: 2, aperture: 2, exposure_bias_ev: 0, focal_mm: 50 })).toBe('2s F2');
  expect(shootingLine({ shutter_s: 1/8000, aperture: 22, exposure_program: 1,
    exposure_bias_ev: -2.7, focal_35mm: 1200 })).toBe('1/8000 F22 M -2.7');
  expect(shootingLine({ shutter_s: NaN, aperture: -2, exposure_program: 7 })).toBe('');
  expect(shootingLine({ exposure_bias_ev: -0.05 })).toBe('-0.1');
});

it('keeps an explicit custom date, including deliberate empty text, while data is derived', () => {
  const p = { ...FILM_PARAMS_DEFAULT, exposureCompensationEV: 3,
    dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true, customText: '' } };
  const resolved = resolveImprints(p, { datetime_original: '2026-10-01T12:00:00', aperture: 8 });
  expect(fullDelta(resolved).date_imprint_text).toBe('');
  expect(resolved.dateBack.dataText).toBe('F8');
  expect(resolveImprints(resolved, { datetime_original: '2026-10-01T12:00:00', aperture: 8 })).toEqual(resolved);
});

it('selects only real date-back cameras and never draws a phantom date on panoramas or bare 120', () => {
  const on = { ...FILM_PARAMS_DEFAULT, dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true } };
  expect(resolveImprints(on, null).dateBack.camera).toBe('135');
  const square = { ...on, sideLengthMM: 56 };
  expect(fullDelta(resolveImprints(square, null, 1)).date_imprint_active).toBe(false);
  const pano = { ...on, filmEdge: { ...on.filmEdge, active: true, format: '135_xpan' } };
  expect(fullDelta(resolveImprints(pano, null)).date_imprint_active).toBe(false);
  const medium = { ...on, filmEdge: { ...on.filmEdge, active: true, format: '120_6x6' } };
  expect(fullDelta(resolveImprints(medium, null)).date_imprint_active).toBe(true);
});

it('keeps grain pitch and date proportions when the bare picture is cropped before exposure', () => {
  const p = { ...FILM_PARAMS_DEFAULT, filmFormatMM: 36,
    dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true } };
  const g = { ...GEOMETRY_DEFAULT, crop: { x: 0.2, y: 0.25, width: 0.5, height: 0.5 }, quarterTurns: 1 };
  const r = resolveImprints(p, null, 1.5, g, { width: 6000, height: 4000 });
  expect(r.dateBack.frameScale).toBe(0.5);
  const wire = fullDelta(r);
  expect(wire.film_format_mm).toBe(18);
  expect(wire.date_imprint_size).toBe(0.5);
  expect(wire.date_imprint_inset_x).toBe(1.5);
  expect(wire.date_imprint_inset_y).toBe(1.2);
  expect(fullDelta(resolveImprints(r, null, 1.5, GEOMETRY_DEFAULT, { width: 6000, height: 4000 })).film_format_mm).toBe(36);
  const edge = { ...r, filmEdge: { ...r.filmEdge, active: true } };
  expect(fullDelta(edge).film_format_mm).toBe(36);
  expect(fullDelta(edge).date_imprint_size).toBe(1);
});
