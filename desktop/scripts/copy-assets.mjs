// copy-assets.mjs — the macOS app's data the interface reads, copied into
// `public/assets/` (generated, gitignored) before `vite` runs:
//   StockCatalog.json, the film covers, the licence texts.
// One source of truth: edit them under app/SpektraLab/ and modern_UI/, not here.
//
// The catalogue is SpektraLab 2's (app/SpektraLab/Resources/StockCatalog.json, generated from the
// engine's profiles by tools/gen_catalog.py): it carries `monochrome`, each film's `grain` and the
// silver paper's `neutralPack`, which the film/paper rules need (src/shared/stocks.ts). The 1.x
// catalogue under modern_UI/ only adds what 2 does not have -- the film covers and the preview-LUT
// flags -- merged in by id.

import { cpSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, '../../modern_UI/Spektrafilm/Spektrafilm/Resources');
const app2 = resolve(here, '../../app/SpektraLab/Resources');
const out = resolve(here, '../public/assets');
mkdirSync(out, { recursive: true });

const v1 = JSON.parse(readFileSync(resolve(app, 'StockCatalog.json'), 'utf8')).stocks ?? [];
const v2 = JSON.parse(readFileSync(resolve(app2, 'StockCatalog.json'), 'utf8')).stocks ?? [];
const old = new Map(v1.map((s) => [s.id, s]));
const merged = v2.map((s) => {
  const o = old.get(s.id) ?? {};
  return {
    ...s,
    cover: o.cover ?? null,
    hasPreviewLUT: o.hasPreviewLUT ?? false,
    pairedFilm: o.pairedFilm ?? null,
    formats: o.formats ?? null,
  };
});
writeFileSync(resolve(out, 'StockCatalog.json'), JSON.stringify({ stocks: merged }, null, 2));

cpSync(resolve(app, 'FilmCovers'), resolve(out, 'FilmCovers'), { recursive: true });
mkdirSync(resolve(out, 'licenses'), { recursive: true });
for (const f of readdirSync(resolve(app, 'Licenses'))) {
  if (f.endsWith('.txt')) cpSync(resolve(app, 'Licenses', f), resolve(out, 'licenses', f));
}
console.log(`assets: copied to public/assets (catalogue: ${merged.length} stocks, SpektraLab 2 + 1.x covers)`);
