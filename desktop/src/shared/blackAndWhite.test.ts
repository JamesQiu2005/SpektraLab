import { describe, expect, it } from 'vitest';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';
import schema from '../../mock-host/schema-fields.json';
import { StockCatalog } from './stocks';
import { ALL_FEATURES, FILM_PARAMS_DEFAULT, delta, fullDelta, normalizeStockPair } from './params';

const silverPaper = 'ilford_multigrade_iv_rc';
const films = [
  ['kodak_tri_x_400', 1.70], ['ilford_hp5_plus_400', 1.49],
  ['kodak_tmax_100', 0.74], ['fujifilm_neopan_acros_100_ii', 0.64],
] as const;
const catalog = new StockCatalog(stockData.stocks);
const mono = (filmStock: string = films[0][0]) => ({ ...structuredClone(FILM_PARAMS_DEFAULT), filmStock, printStock: silverPaper });

describe('the released black-and-white catalogue and wire', () => {
  it('offers the four silver films separately, each on the declared silver paper', () => {
    expect(catalog.filmGroups().find((g) => g.title === 'Black & White')?.films.map((s) => s.id).sort()).toEqual(films.map(([id]) => id).sort());
    for (const [id] of films) {
      expect(catalog.stock(id)?.targetPrint).toBe(silverPaper);
      expect(catalog.canPrint(id, silverPaper)).toBe(true);
      expect(catalog.canPrint(id, FILM_PARAMS_DEFAULT.printStock)).toBe(false);
    }
    expect(catalog.canPrint(FILM_PARAMS_DEFAULT.filmStock, silverPaper)).toBe(false);
    // A stale or loading catalogue must not invent a replacement for an unknown stock.
    expect(catalog.canPrint('unknown', silverPaper)).toBe(true);
  });

  it.each(films)('%s uses its calibrated single-layer grain and grade-2 filter pack', (id, amount) => {
    const p = mono(id);
    p.extendedDynamicRange = true;
    p.effects.grainLayered = true;
    expect(fullDelta(p, ALL_FEATURES, catalog)).toMatchObject({
      grain_amount: amount, grain_sublayers_active: false, extended_dynamic_range: false,
      c_filter_neutral: 0, m_filter_neutral: 0, y_filter_neutral: 68,
    });
    expect(p.extendedDynamicRange).toBe(true);
    expect(p.effects.grainLayered).toBe(true);
    for (const [name, value] of Object.entries(fullDelta(p, ALL_FEATURES, catalog))) {
      const field = schema.find((f) => f.name === name);
      expect(field, name).toBeDefined();
      if (typeof value === 'number' && field && 'range' in field && field.range) {
        expect(value, name).toBeGreaterThanOrEqual(field.range[0]!);
        expect(value, name).toBeLessThanOrEqual(field.range[1]!);
      }
    }
    p.effects.grain = 2;
    expect(fullDelta(p, ALL_FEATURES, catalog).grain_amount).toBe(Math.min(2, 2 * amount));
  });

  it('leaves the colour wire unchanged and restores its grain/EDR settings when leaving silver', () => {
    const colour = { ...structuredClone(FILM_PARAMS_DEFAULT), extendedDynamicRange: true };
    expect(fullDelta(colour, ALL_FEATURES, catalog)).toEqual(fullDelta(colour, ALL_FEATURES));
    const d = delta(colour, { ...mono(), extendedDynamicRange: true }, ALL_FEATURES, catalog);
    expect(d.delta).toMatchObject({ grain_amount: 1, grain_sublayers_active: true, extended_dynamic_range: true });
    expect('c_filter_neutral' in d.delta).toBe(false);
    expect('y_filter_neutral' in d.delta).toBe(false);
  });

  it('repairs incompatible pairs without discarding exposure or an explicit scan preference', () => {
    const p = { ...mono(), printStock: FILM_PARAMS_DEFAULT.printStock, scanFilm: true, exposureCompensationEV: 1.5 };
    expect(normalizeStockPair(p, catalog)).toMatchObject({ printStock: silverPaper, scanFilm: true, exposureCompensationEV: 1.5 });
    expect(p.printStock).toBe(FILM_PARAMS_DEFAULT.printStock);
    const colour = { ...mono(), filmStock: FILM_PARAMS_DEFAULT.filmStock };
    expect(normalizeStockPair(colour, catalog).printStock).toBe(catalog.stock(FILM_PARAMS_DEFAULT.filmStock)?.targetPrint);
    const unknown = { ...mono(), filmStock: 'unknown' };
    expect(normalizeStockPair(unknown, catalog)).toBe(unknown);
    expect(normalizeStockPair(p, new StockCatalog([]))).toBe(p);
  });
});
