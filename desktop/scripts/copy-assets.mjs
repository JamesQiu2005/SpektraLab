// copy-assets.mjs — the macOS app's data the interface reads, copied into
// `public/assets/` (generated, gitignored) before `vite` runs:
//   StockCatalog.json, the film covers, the licence texts.
// One source of truth: edit them under modern_UI/, not here.

import { cpSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, '../../modern_UI/Spektrafilm/Spektrafilm/Resources');
const out = resolve(here, '../public/assets');
mkdirSync(out, { recursive: true });
cpSync(resolve(app, 'StockCatalog.json'), resolve(out, 'StockCatalog.json'));
// Synchronous wire resolution needs names at module load. Public assets are
// fetched by URL in Vite dev, so keep this small generated source table too.
const stocks = JSON.parse(readFileSync(resolve(app, 'StockCatalog.json'), 'utf8')).stocks;
writeFileSync(resolve(here, '../src/shared/stockMetadata.json'), JSON.stringify(stocks, null, 2) + '\n');
writeFileSync(resolve(here, '../src/shared/stockNames.json'), JSON.stringify(Object.fromEntries(stocks.map((s) => [s.id, s.name])), null, 2) + '\n');
cpSync(resolve(app, 'FilmCovers'), resolve(out, 'FilmCovers'), { recursive: true });
mkdirSync(resolve(out, 'licenses'), { recursive: true });
for (const f of readdirSync(resolve(app, 'Licenses'))) {
  if (f.endsWith('.txt')) cpSync(resolve(app, 'Licenses', f), resolve(out, 'licenses', f));
}
console.log('assets: copied to public/assets');
