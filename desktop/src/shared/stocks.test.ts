import { afterEach, describe, expect, it } from 'vitest';
import catalogFile from '../../../app/SpektraLab/Resources/StockCatalog.json';
import { FILM_PARAMS_DEFAULT, delta, fullDelta, heldToItsFilm } from './params';
import { EMPTY_CATALOG, StockCatalog, setActiveCatalog, type Stock } from './stocks';

// SpektraLab 2's own catalogue: the rules are Stock.swift's, so they are checked on its data.
const cat = new StockCatalog((catalogFile as { stocks: Stock[] }).stocks);

afterEach(() => setActiveCatalog(EMPTY_CATALOG));

describe('the film and paper rules (Stock.swift)', () => {
  it('prints silver on silver and colour on colour', () => {
    expect(cat.canPrint('ilford_hp5_plus_400', 'ilford_multigrade_iv_rc')).toBe(true);
    expect(cat.canPrint('ilford_hp5_plus_400', 'kodak_portra_endura')).toBe(false);
    expect(cat.canPrint('kodak_portra_400', 'ilford_multigrade_iv_rc')).toBe(false);
    expect(cat.canPrint('kodak_portra_400', 'kodak_portra_endura')).toBe(true);
    expect(cat.canPrint('unknown_film', 'kodak_portra_endura')).toBe(true);
  });

  it("brings each film's own paper", () => {
    expect(cat.ownPaper('ilford_hp5_plus_400')).toBe('ilford_multigrade_iv_rc');
    expect(cat.ownPaper('kodak_gold_200')).toBe('kodak_supra_endura');
    expect(cat.ownPaper('kodak_ultramax_400')).toBe('kodak_ultra_endura');
    expect(cat.ownPaper('cinestill_800t')).toBe('kodak_2383');
    for (const f of cat.films) {
      const paper = cat.ownPaper(f.id);
      expect(paper, f.id).toBeDefined();
      expect(cat.canPrint(f.id, paper!), f.id).toBe(true);
    }
  });

  it('scans a slide and holds a paper to its film', () => {
    const slide = heldToItsFilm({ ...FILM_PARAMS_DEFAULT, filmStock: 'fujifilm_velvia_100', scanFilm: false }, cat);
    expect(slide.scanFilm).toBe(true);
    const bw = heldToItsFilm({ ...FILM_PARAMS_DEFAULT, filmStock: 'kodak_tri_x_400', printStock: 'kodak_portra_endura' }, cat);
    expect(bw.printStock).toBe('ilford_multigrade_iv_rc');
  });
});

describe('the wire with the catalogue', () => {
  it('sends a slide scanned, whatever the edit holds (no inverted slides)', () => {
    setActiveCatalog(cat);
    const w = fullDelta({ ...FILM_PARAMS_DEFAULT, filmStock: 'kodak_ektachrome_100', scanFilm: false });
    expect(w.scan_film).toBe(true);
  });

  it("sends a black-and-white pair on its paper, with the paper's pack and one grain layer", () => {
    setActiveCatalog(cat);
    const w = fullDelta({ ...FILM_PARAMS_DEFAULT, filmStock: 'ilford_hp5_plus_400', printStock: 'kodak_portra_endura' });
    expect(w.print_stock).toBe('ilford_multigrade_iv_rc');
    expect(w.c_filter_neutral).toBe(0);
    expect(w.m_filter_neutral).toBe(0);
    expect(w.y_filter_neutral).toBe(68);
    expect(w.grain_sublayers_active).toBe(false);
    expect(w.extended_dynamic_range).toBe(false);
  });

  it('sends the Grain strength as it is, for every film (the per-film scale is off)', () => {
    setActiveCatalog(cat);
    for (const film of ['kodak_tri_x_400', 'kodak_portra_400', 'kodak_portra_160']) {
      const w = fullDelta({ ...FILM_PARAMS_DEFAULT, filmStock: film });
      expect(w.grain_amount, film).toBe(FILM_PARAMS_DEFAULT.effects.grain);
    }
  });

  it('changes the film and its paper in one delta', () => {
    setActiveCatalog(cat);
    const from = { ...FILM_PARAMS_DEFAULT, filmStock: 'kodak_portra_400', printStock: 'kodak_portra_endura' };
    const to = { ...from, filmStock: 'ilford_hp5_plus_400' };
    const d = delta(to, from);
    expect(d.delta.film_stock).toBe('ilford_hp5_plus_400');
    expect(d.delta.print_stock).toBe('ilford_multigrade_iv_rc');
    expect(d.layers.has('shoot')).toBe(true);
  });

  it('leaves a colour pair as it was without a catalogue', () => {
    const w = fullDelta({ ...FILM_PARAMS_DEFAULT, filmStock: 'ilford_hp5_plus_400', printStock: 'kodak_portra_endura' });
    expect(w.print_stock).toBe('kodak_portra_endura');
    expect('m_filter_neutral' in w).toBe(false);
  });
});
