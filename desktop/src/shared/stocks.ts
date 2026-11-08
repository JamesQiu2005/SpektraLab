// stocks.ts — the film and paper catalogue (`Model/StockCatalog.swift`),
// read from the Mac app's `StockCatalog.json` (copied to public/assets).

export interface Stock {
  id: string;
  name: string;
  stage: 'filming' | 'printing' | string;
  use: 'still' | 'cine' | string;
  type?: string | null;
  targetPrint?: string | null;
  hasPreviewLUT: boolean;
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
  /** Still first, then cine, as the Mac picker orders them; then by polarity. */
  filmGroups(): { title: 'Positive' | 'Negative'; films: Stock[] }[] {
    const ordered = [...this.films.filter((s) => s.use !== 'cine'), ...this.films.filter((s) => s.use === 'cine')];
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

export const EMPTY_CATALOG = new StockCatalog([]);

export async function loadCatalog(): Promise<StockCatalog> {
  try {
    const r = await fetch('assets/StockCatalog.json');
    const j = (await r.json()) as { stocks: Stock[] };
    return new StockCatalog(j.stocks ?? []);
  } catch {
    return EMPTY_CATALOG;
  }
}
