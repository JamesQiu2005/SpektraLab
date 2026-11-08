// extract-strings.mjs — the macOS string table (Localization/Strings.swift)
// → src/i18n/en.json + src/i18n/zh-Hans.json.
//
// Run after the Swift table changes: `npm run gen:strings`. The JSON is
// committed (the Swift file is the source; this is a mechanical copy). Swift
// interpolation `\(x)` has no place in the table today; the script fails if it
// ever appears rather than emit a key with a literal backslash.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const src = resolve(here, '../../modern_UI/Spektrafilm/Spektrafilm/Localization/Strings.swift');
const swift = readFileSync(src, 'utf8');

function block(name) {
  const start = swift.indexOf(`var ${name}: String {`);
  if (start < 0) throw new Error(`no ${name} block`);
  let depth = 0;
  for (let i = swift.indexOf('{', start); i < swift.length; i++) {
    if (swift[i] === '{') depth++;
    else if (swift[i] === '}' && --depth === 0) return swift.slice(start, i);
  }
  throw new Error('unbalanced');
}

function unescape(s) {
  if (/\\\(/.test(s)) throw new Error(`interpolation in table: ${s}`);
  return s.replace(/\\(["\\nt])/g, (_, c) => (c === 'n' ? '\n' : c === 't' ? '\t' : c));
}

function parse(text) {
  const out = {};
  const re = /case\s+((?:\.\w+\s*,\s*)*\.\w+)\s*:\s*((?:"(?:[^"\\]|\\.)*"\s*(?:\+\s*)?)+)/g;
  let m;
  while ((m = re.exec(text))) {
    const keys = m[1].split(',').map((k) => k.trim().slice(1));
    const value = [...m[2].matchAll(/"((?:[^"\\]|\\.)*)"/g)].map((x) => unescape(x[1])).join('');
    for (const k of keys) out[k] = value;
  }
  return out;
}

const en = parse(block('english'));
const zh = parse(block('simplifiedChinese'));
const out = resolve(here, '../src/i18n');
mkdirSync(out, { recursive: true });
const sorted = (o) => Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]]));
writeFileSync(resolve(out, 'en.json'), JSON.stringify(sorted(en), null, 1) + '\n');
writeFileSync(resolve(out, 'zh-Hans.json'), JSON.stringify(sorted(zh), null, 1) + '\n');
console.log(`strings: ${Object.keys(en).length} en, ${Object.keys(zh).length} zh-Hans`);
