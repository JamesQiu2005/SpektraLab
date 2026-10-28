import { describe, expect, it } from 'vitest';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';
import schema from '../../mock-host/schema-fields.json';
import { StockCatalog } from './stocks';
import { ALL_FEATURES, EFFECTS_DEFAULT, FILM_PARAMS_DEFAULT, decodeFilmParams, wire } from './params';
import { edgeText } from './filmEdge';

// 1.3.4: CineStill 800T (`CineStillTests.swift`, API-SPEC §18).
const catalog = new StockCatalog(stockData.stocks);
const cinestill = () => ({ ...structuredClone(FILM_PARAMS_DEFAULT), filmStock: 'cinestill_800t', printStock: 'kodak_2383' });
const field = (p: ReturnType<typeof cinestill>, name: string) => wire(p, ALL_FEATURES, catalog).find((f) => f.name === name)?.value;

describe('CineStill 800T', () => {
  it('is a colour negative with no anti-halation layer, and no other film is', () => {
    const s = catalog.stock('cinestill_800t');
    expect(s?.name).toBe('CineStill 800T');
    expect(catalog.hasNoAntihalationLayer('cinestill_800t')).toBe(true);
    expect(catalog.isMonochrome('cinestill_800t')).toBe(false);
    expect(catalog.filmGroups().find((g) => g.title === 'Negative')?.films.map((f) => f.id)).toContain('cinestill_800t');
    expect(catalog.films.filter((f) => catalog.hasNoAntihalationLayer(f.id)).map((f) => f.id)).toEqual(['cinestill_800t']);
  });

  it('sends halation_headroom_ev always, at the engine default 4, clamped to the wire range', () => {
    expect(EFFECTS_DEFAULT.highlightHeadroom).toBe(4);
    expect(field(cinestill(), 'halation_headroom_ev')).toBe(4);
    // Every other film's engine ignores it byte for byte, so it is sent on the same rule.
    expect(wire(structuredClone(FILM_PARAMS_DEFAULT)).find((f) => f.name === 'halation_headroom_ev')?.value).toBe(4);
    const p = cinestill();
    p.effects.highlightHeadroom = 11;
    expect(field(p, 'halation_headroom_ev')).toBe(8);
    p.effects.highlightHeadroom = -1;
    expect(field(p, 'halation_headroom_ev')).toBe(0);
    const s = (schema as { name: string; layer: string; range?: number[] }[]).find((f) => f.name === 'halation_headroom_ev');
    expect(s).toMatchObject({ layer: 'shoot', range: [0, 8] });
  });

  it('reads a sidecar without the key as the default, and keeps a saved value', () => {
    expect(decodeFilmParams({ filmStock: 'cinestill_800t', effects: { halation: 2 } }).effects.highlightHeadroom).toBe(4);
    expect(decodeFilmParams({ filmStock: 'cinestill_800t', effects: { highlightHeadroom: 1.5 } }).effects.highlightHeadroom).toBe(1.5);
  });

  it('prints "CINESTILL 800T" on its edge on both gauges', () => {
    expect(edgeText(catalog.stock('cinestill_800t'), '135')).toBe('CINESTILL 800T');
    expect(edgeText(catalog.stock('cinestill_800t'), '120_6x7')).toBe('CINESTILL 800T');
  });
});
