import { describe, expect, it } from 'vitest';
import { ALL_FEATURES, FILM_PARAMS_DEFAULT, fullDelta } from './params';
import { GEOMETRY_DEFAULT, outputSize } from './geometry';
import { StockCatalog } from './stocks';
import { captureDate, shootingText, edgeText, resolveFilmEdgeParams, canvasGeometryFor, sourceGeometryFor, gateFramed, datePrints, dateEffective } from './filmEdge';
import { decodeSidecar, encodeSidecar, newSidecar } from './sidecar';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';
const catalog = new StockCatalog(stockData.stocks);
const native = { width: 6000, height: 4000 };
const crop = { ...GEOMETRY_DEFAULT, crop: { x: .1, y: .1, width: .6, height: .7 }, angle: 3, quarterTurns: 1, flipH: true };

describe('the camera gate and date back contract', () => {
  it('accepts host ISO and EXIF dates without inventing unavailable or invalid shooting data', () => {
    expect(captureDate('2026-10-01T12:34:56', 'japan')).toBe("'26 10 1");
    expect(captureDate('2026:10:01 12:34:56', 'us')).toBe("10 1 '26");
    expect(captureDate('2026-02-29T12:00:00', 'japan')).toBe('');
    expect(captureDate('2024-02-29', 'japan')).toBe("'24 2 29");
    expect(shootingText(null)).toBe('');
    expect(shootingText({ focal_mm: 50 })).toBe(''); // not equivalent focal length
    expect(shootingText({ shutter_s: 1 / 250, aperture: 2.8, exposure_program: 3, exposure_bias_ev: .3, focal_35mm: 50 })).toBe('1/250 F2.8 A +0.3 50mm');
  });
  it('uses released silver-stock lettering and resolves metadata identically on repeated passes', () => {
    expect(edgeText(catalog.stock('kodak_tri_x_400'), '135')).toBe('KODAK 400TX');
    expect(edgeText(catalog.stock('fujifilm_neopan_acros_100_ii'), '120_6x6')).toBe('FUJI 100 ACROS II');
    const p = { ...FILM_PARAMS_DEFAULT, filmStock: 'kodak_tri_x_400' };
    const metadata = { datetime_original: '2026-10-01T12:00:00', aperture: 4 };
    const resolved = resolveFilmEdgeParams(p, crop, metadata, catalog, native);
    expect(resolveFilmEdgeParams(resolved, crop, metadata, catalog, native)).toEqual(resolved);
    expect(resolved).toMatchObject({ filmEdge: { edgeText: 'KODAK 400TX', fNumber: 4 }, dateBack: { text: "'26 10 1", framing: expect.any(String) } });
  });
  it('holds a physical gate ratio, with post geometry identity and original crop retained in the sidecar', () => {
    const p = { ...FILM_PARAMS_DEFAULT, filmEdge: { ...FILM_PARAMS_DEFAULT.filmEdge, active: true, format: '135_half' } };
    const g = gateFramed(crop, p.filmEdge, native);
    expect(g.crop.width * native.width / (g.crop.height * native.height)).toBeCloseTo(4 / 3, 8);
    expect(sourceGeometryFor(p, g)).toBe(g);
    expect(canvasGeometryFor(p, g)).toEqual(GEOMETRY_DEFAULT);
    const sc = { ...newSidecar(), params: p, geometry: g, heldCrop: crop };
    expect(decodeSidecar(encodeSidecar(sc))).toMatchObject({ geometry: g, heldCrop: crop });
    expect(encodeSidecar({ ...sc, heldCrop: null })).not.toHaveProperty('heldCrop');
    expect(sourceGeometryFor(p, g, { ...ALL_FEATURES, overscan: false })).toBeNull();
  });
  it('allows bare 135 dates, requires an edge for data/120, and refuses panoramic backs', () => {
    const d = { ...FILM_PARAMS_DEFAULT.dateBack, active: true };
    const e = FILM_PARAMS_DEFAULT.filmEdge;
    expect(dateEffective(d, e)).toBe(true);
    expect(datePrints('data', d, e)).toBe(false);
    expect(dateEffective({ ...d, camera: '120_645' }, e)).toBe(false);
    expect(dateEffective(d, { ...e, active: true, format: '120_645' })).toBe(true);
    expect(dateEffective(d, { ...e, active: true, format: '135_xpan' })).toBe(false);
    const p = { ...FILM_PARAMS_DEFAULT, dateBack: d };
    expect(sourceGeometryFor(p, GEOMETRY_DEFAULT)).toBeNull();
    expect(sourceGeometryFor(p, crop)).toBe(crop);
  });
  it('scales date-only physical pitch on the cut and emits real metadata, never a stale other-frame date', () => {
    const p = { ...FILM_PARAMS_DEFAULT, filmFormatMM: 36, dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true, withData: true } };
    const cut = { ...GEOMETRY_DEFAULT, crop: { x: .25, y: .25, width: .5, height: .5 } };
    const resolved = resolveFilmEdgeParams(p, cut, { datetime_original: '2026-10-01T00:00:00' }, catalog, native);
    expect(fullDelta(resolved)).toMatchObject({ date_imprint_active: true, date_imprint_text: "'26 10 1", date_imprint_data_text: '', film_format_mm: 18 });
    expect(outputSize(cut, native)).toEqual({ width: 3000, height: 2000 });
    expect(fullDelta(resolveFilmEdgeParams(resolved, cut, null, catalog, native))).toHaveProperty('date_imprint_text', '');
  });
});
