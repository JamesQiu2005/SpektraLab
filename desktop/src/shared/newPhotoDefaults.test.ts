import { describe, expect, it } from 'vitest';
import { NEW_PHOTO_DEFAULTS, newPhotoSidecar, newPhotoStocks } from './newPhotoDefaults';
import { EMPTY_CATALOG, StockCatalog } from './stocks';
import { newSidecar } from './sidecar';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';

const catalog = new StockCatalog(stockData.stocks);

describe('resolving new photograph defaults', () => {
  it('falls back from removed stocks and rejects a paper ID used as a film ID', () => {
    for (const film of ['retired_stock', 'kodak_2383']) {
      const stocks = newPhotoStocks(catalog, { newPhotoFilmStock: film, newPhotoPrintStock: 'missing_paper' });
      expect(stocks.filmStock).toBe(NEW_PHOTO_DEFAULTS.newPhotoFilmStock);
      expect(catalog.papers.some((p) => p.id === stocks.printStock)).toBe(true);
      expect(catalog.canPrint(stocks.filmStock, stocks.printStock)).toBe(true);
    }
  });

  it('retains built-in defaults until the catalog is available', () => {
    expect(newPhotoStocks(EMPTY_CATALOG, { newPhotoFilmStock: 'unknown', newPhotoPrintStock: 'unknown' })).toEqual({
      filmStock: NEW_PHOTO_DEFAULTS.newPhotoFilmStock, printStock: NEW_PHOTO_DEFAULTS.newPhotoPrintStock,
    });
  });

  it('keeps neutral sidecar creation and reset independent of application preferences', () => {
    const neutral = structuredClone(newSidecar());
    const preferred = newPhotoSidecar(catalog, { newPhotoFilmStock: 'kodak_tri_x_400', newPhotoPrintStock: 'kodak_2383' });
    expect(preferred.params).toMatchObject({ filmStock: 'kodak_tri_x_400', printStock: 'ilford_multigrade_iv_rc' });
    expect(newSidecar()).toEqual(neutral);
    expect(NEW_PHOTO_DEFAULTS).toEqual({ newPhotoFilmStock: neutral.params.filmStock, newPhotoPrintStock: neutral.params.printStock });
  });
});
