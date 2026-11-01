// Application preferences apply only when a photograph has no saved edits.
// Keep newSidecar() neutral: decoding old documents and resetting a frame must
// not depend on this machine's preferences.
import { normalizeStockPair, FILM_PARAMS_DEFAULT } from './params.ts';
import { newSidecar, type Sidecar } from './sidecar.ts';
import type { StockCatalog } from './stocks.ts';

export interface NewPhotoDefaults {
  newPhotoFilmStock: string;
  newPhotoPrintStock: string;
}

export const NEW_PHOTO_DEFAULTS: NewPhotoDefaults = {
  newPhotoFilmStock: FILM_PARAMS_DEFAULT.filmStock,
  newPhotoPrintStock: FILM_PARAMS_DEFAULT.printStock,
};

/** Resolve removed/unknown profiles and incompatible colour/silver pairs
 * before sending anything to the engine. A not-yet-loaded catalog retains the
 * built-in defaults rather than accepting unvalidated preference IDs. */
export function newPhotoStocks(catalog: StockCatalog, defaults: NewPhotoDefaults) {
  const film = catalog.films.find((s) => s.id === defaults.newPhotoFilmStock)
    ?? catalog.films.find((s) => s.id === NEW_PHOTO_DEFAULTS.newPhotoFilmStock)
    ?? catalog.films[0];
  if (!film) return { filmStock: NEW_PHOTO_DEFAULTS.newPhotoFilmStock, printStock: NEW_PHOTO_DEFAULTS.newPhotoPrintStock };
  // Filter before falling back: a stored colour paper must not survive a
  // switch to a silver film, even when that paper ID still exists.
  const papers = catalog.papers.filter((p) => catalog.canPrint(film.id, p.id));
  const paper = papers.find((p) => p.id === defaults.newPhotoPrintStock)
    ?? papers.find((p) => p.id === film.targetPrint)
    ?? papers.find((p) => p.id === NEW_PHOTO_DEFAULTS.newPhotoPrintStock)
    ?? papers[0];
  return { filmStock: film.id, printStock: paper?.id ?? NEW_PHOTO_DEFAULTS.newPhotoPrintStock };
}

export function newPhotoSidecar(catalog: StockCatalog, defaults: NewPhotoDefaults): Sidecar {
  const sidecar = newSidecar();
  // Use the editor's stock-pair rules so a preferred reversal film opens as
  // a direct scan on its first render, before any stock picker is touched.
  return { ...sidecar, params: normalizeStockPair({ ...sidecar.params, ...newPhotoStocks(catalog, defaults) }, catalog) };
}
