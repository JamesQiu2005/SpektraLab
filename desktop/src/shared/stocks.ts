// stocks.ts — the film and paper catalogue (`Model/StockCatalog.swift`, and SpektraLab 2's
// `app/SpektraLab/Sources/Model/Stock.swift`), read from StockCatalog.json in public/assets.
//
// The file is SpektraLab 2's catalogue (app/SpektraLab/Resources/StockCatalog.json), with the 1.x
// app's film covers merged in by id (scripts/copy-assets.mjs). The 1.x catalogue this port was
// written against has no `monochrome`, `grain` or `neutralPack`, and without them the rules below
// cannot be kept: a black-and-white film printed on a colour paper (a red-brown picture), a slide
// printed as a negative (inverted colours), every film at one grain.

export interface Stock {
  id: string;
  name: string;
  shortName?: string;
  kind?: string;
  stage: 'filming' | 'printing' | string;
  use: 'still' | 'cine' | string;
  type?: string | null;
  targetPrint?: string | null;
  iso?: number | null;
  swatch?: string;
  /** A black-and-white stock: one silver emulsion, or a silver paper (`channel_model: bw`). */
  monochrome?: boolean;
  /** The film's own grain: the `grain_amount` at which the engine renders its published granularity. */
  grain?: number | null;
  /** A silver paper's enlarger pack (C, M, Y): the engine's table has no row for it, so it is sent. */
  neutralPack?: number[] | null;
  hasPreviewLUT?: boolean;
  pairedFilm?: string | null;
  cover?: string | null;
  formats?: string[] | null;
}

export class StockCatalog {
  readonly stocks: Stock[];
  constructor(stocks: Stock[]) {
    this.stocks = stocks;
  }
  get films() {
    return this.stocks.filter((s) => s.stage === 'filming');
  }
  get papers() {
    return this.stocks.filter((s) => s.stage === 'printing');
  }
  stock(id: string) {
    return this.stocks.find((s) => s.id === id);
  }
  isPositive(id: string) {
    return this.stock(id)?.type === 'positive';
  }
  /** A slide: already a viewable image, so it is scanned, never printed. */
  isSlide(id: string) {
    return this.isPositive(id);
  }
  isMonochrome(id: string) {
    return !!this.stock(id)?.monochrome;
  }
  /**
   * Whether `paper` can print `film`: silver on silver, colour on colour. A stock the catalogue
   * does not know rules nothing out (Stock.swift `canPrint`).
   */
  canPrint(film: string, paper: string) {
    const f = this.stock(film), p = this.stock(paper);
    if (!f || !p) return true;
    return !!f.monochrome === !!p.monochrome;
  }
  /** The paper a newly selected film brings (Stock.swift `ownPaper`). */
  ownPaper(film: string): string | undefined {
    const f = this.stock(film);
    if (!f) return undefined;
    let recommended: string | null | undefined;
    if (film === 'kodak_gold_200' || film === 'kodak_ektar_100') recommended = 'kodak_supra_endura';
    else if (film === 'kodak_ultramax_400') recommended = 'kodak_ultra_endura';
    else recommended = f.targetPrint;
    const own = recommended ? this.stock(recommended) : undefined;
    if (own && own.stage === 'printing' && !!own.monochrome === !!f.monochrome) return own.id;
    return this.papers.find((p) => !!p.monochrome === !!f.monochrome)?.id;
  }
  /** `paper` if it prints `film`, the film's own paper otherwise. */
  paperPrinting(film: string, kept: string): string {
    return this.canPrint(film, kept) ? kept : (this.ownPaper(film) ?? kept);
  }
  /** Why `paper` waits under `film`, or null where it prints it. */
  whyNotPrinted(film: string, paper: string): string | null {
    if (this.canPrint(film, paper)) return null;
    return this.isMonochrome(film)
      ? 'A colour paper: a black-and-white film prints on a black-and-white paper'
      : 'A black-and-white paper: choose a black-and-white film to print on it';
  }
  /** Still first, then cine, as the Mac picker orders them; then by polarity. */
  filmGroups(): { title: 'Positive' | 'Negative'; films: Stock[] }[] {
    // Develop (the owner, 2026-11-19): by brand, then by name (numbers in order, so 50 before 100),
    // cine stocks after the still ones as before. The brand is the name's first word: the
    // catalogue has no maker field, and every name starts with its maker.
    const brand = (s: Stock) => s.name.split(' ')[0] ?? '';
    const ordered = [...this.films].sort(
      (a, b) =>
        Number(a.use === 'cine') - Number(b.use === 'cine') ||
        brand(a).localeCompare(brand(b)) ||
        a.name.localeCompare(b.name, undefined, { numeric: true }),
    );
    return [
      { title: 'Positive', films: ordered.filter((s) => s.type === 'positive') },
      { title: 'Negative', films: ordered.filter((s) => s.type !== 'positive') },
    ];
  }
  paperGroups(): { title: 'Still' | 'Cine'; papers: Stock[] }[] {
    return [
      { title: 'Still', papers: this.papers.filter((s) => s.use !== 'cine') },
      { title: 'Cine', papers: this.papers.filter((s) => s.use === 'cine') },
    ];
  }
  coverURL(id: string): string | null {
    const c = this.stock(id)?.cover;
    return c ? `assets/FilmCovers/${c}` : null;
  }
}

/**
 * The words a film prints on its edge (SpektraLab 2's `EdgeWords` and `Stock.edgeText(gauge:)`,
 * FilmEdgeStock.swift): the film's own where it prints something other than its name, read off real
 * strips (135, 120); else its name in capitals, without a push's "(Push 1)". The engine draws no maker's
 * name of its own: this is `overscan_edge_text`.
 */
export const EDGE_WORDS: Record<string, readonly [string, string]> = {
  kodak_gold_200: ['KODAK GB 200-7', 'KODAK 200'],
  kodak_portra_800: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_portra_800_push1: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_portra_800_push2: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_ultramax_400: ['KODAK GC 400', 'KODAK GC 400'],
  kodak_portra_160nc: ['KODAK 160NC', 'KODAK 160NC-2'],
  kodak_portra_160vc: ['KODAK 160VC', 'KODAK 160VC-2'],
  kodak_portra_400nc: ['KODAK 400NC', 'KODAK 400NC-3'],
  kodak_portra_400vc: ['KODAK 400VC', 'KODAK 400VC-3'],
  kodak_ektachrome_100: ['KODAK E100', 'KODAK E100'],
  fujifilm_c200: ['FUJI 200', 'FUJI 200'],
  fujifilm_xtra_400: ['S-400', 'FUJI S-400'],
  fujifilm_pro_400h: ['PRO400H', 'FUJI PRO400H'],
  fujifilm_provia_100f: ['FUJI RDPIII', 'FUJI RDPIII'],
  fujifilm_velvia_100: ['RVP100', 'FUJI RVP100'],
  kodak_vision3_50d: ['EASTMAN 5203', 'EASTMAN 5203'],
  kodak_vision3_250d: ['EASTMAN 5207', 'EASTMAN 5207'],
  kodak_vision3_200t: ['EASTMAN 5213', 'EASTMAN 5213'],
  kodak_vision3_500t: ['EASTMAN 5219', 'EASTMAN 5219'],
  kodak_tri_x_400: ['KODAK 400TX', 'KODAK 400TX'],
  kodak_tmax_100: ['KODAK 100TMX', 'KODAK 100TMX'],
  fujifilm_neopan_acros_100_ii: ['FUJI 100 ACROS II', 'FUJI 100 ACROS II'],
  ilford_hp5_plus_400: ['ILFORD HP5 PLUS', 'ILFORD HP5 PLUS'],
};

/** A film's edge words for a film-edge format ("135", "135_half", "120_6x6"…). */
export function edgeTextFor(cat: StockCatalog, filmId: string, format: string): string {
  const gauge = format.startsWith('120') ? 1 : 0;
  const own = EDGE_WORDS[filmId];
  if (own) return own[gauge]!;
  const name = cat.stock(filmId)?.name ?? '';
  return name.split('(')[0]!.trim().toUpperCase();
}

export const EMPTY_CATALOG = new StockCatalog([]);

// The catalogue the wire is built with (params.ts `wire`). Set once the file is loaded; until then,
// and in tests that do not set it, the empty catalogue applies no rule.
let active: StockCatalog = EMPTY_CATALOG;
export function setActiveCatalog(c: StockCatalog) {
  active = c;
}
export function activeCatalog(): StockCatalog {
  return active;
}

export async function loadCatalog(): Promise<StockCatalog> {
  try {
    const r = await fetch('assets/StockCatalog.json');
    const j = (await r.json()) as { stocks: Stock[] };
    const c = new StockCatalog(j.stocks ?? []);
    setActiveCatalog(c);
    return c;
  } catch {
    return EMPTY_CATALOG;
  }
}
