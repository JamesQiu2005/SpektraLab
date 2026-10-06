// copy-assets.mjs — the macOS app's data the interface reads, copied into
// `public/assets/` (generated, gitignored) before `vite` runs:
//   StockCatalog.json, the film covers, the licence texts.
// One source of truth: edit them under modern_UI/, not here.

import { cpSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, '../../modern_UI/Spektrafilm/Spektrafilm/Resources');
const out = resolve(here, '../public/assets');
mkdirSync(out, { recursive: true });
cpSync(resolve(app, 'StockCatalog.json'), resolve(out, 'StockCatalog.json'));
cpSync(resolve(app, 'FilmCovers'), resolve(out, 'FilmCovers'), { recursive: true });
mkdirSync(resolve(out, 'licenses'), { recursive: true });
for (const f of readdirSync(resolve(app, 'Licenses'))) {
  if (f.endsWith('.txt')) cpSync(resolve(app, 'Licenses', f), resolve(out, 'licenses', f));
}
const root = resolve(here, '../../LICENSE');
if (existsSync(root)) cpSync(root, resolve(out, 'licenses', 'LICENSE.txt'));
console.log('assets: copied to public/assets');
