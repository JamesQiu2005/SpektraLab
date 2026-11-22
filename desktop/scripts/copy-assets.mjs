// copy-assets.mjs — tracked Windows assets copied into
// `public/assets/` (generated, gitignored) before `vite` runs:
//   StockCatalog.json, the film covers, the licence texts.

import { cpSync, mkdirSync, readdirSync, unlinkSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const app = resolve(here, '../assets');
const licenses = resolve(here, '../../license/profiles');
const out = resolve(here, '../public/assets');
mkdirSync(out, { recursive: true });
cpSync(resolve(app, 'StockCatalog.json'), resolve(out, 'StockCatalog.json'));
cpSync(resolve(app, 'FilmCovers'), resolve(out, 'FilmCovers'), { recursive: true });
const licenseOut = resolve(out, 'licenses');
mkdirSync(licenseOut, { recursive: true });
const licenseFiles = new Set(readdirSync(licenses).filter((file) => file.endsWith('.txt')));
for (const entry of readdirSync(licenseOut, { withFileTypes: true })) {
  if (entry.isFile() && entry.name.endsWith('.txt') && !licenseFiles.has(entry.name))
    unlinkSync(resolve(licenseOut, entry.name));
}
for (const file of licenseFiles) cpSync(resolve(licenses, file), resolve(licenseOut, file));
console.log('assets: copied to public/assets');
