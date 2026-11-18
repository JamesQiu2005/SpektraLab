// gen-glyphs.ts — the app's glyphs, cut out of the Windows design itself.
//
//   npx tsx scripts/gen-glyphs.ts                              write src/theme/glyphs.generated.ts
//   npx tsx scripts/gen-glyphs.ts --list <page.svg> [x0 y0 x1 y1]   print a page's drawing items
//
// The pages draw every icon inline — a stroked group, a scale-about-centre
// group around one, bare paths and circles. `tests/design/items.ts` reads a
// page into those items with the translation of the groups around each; this
// cuts a named glyph out of a region of its page (every item whose anchor
// falls in the region, minus the region's own face: a tile, a disc, a button)
// and writes it as markup in the region's own coordinates. The ink becomes
// `currentColor`, so a selected (white) tile draws its glyph dark. Nothing is
// drawn by hand: a glyph that changes in the design changes here when this
// runs again. README §2 names the Segoe Fluent Icons these stand for; the
// drawings approximate them, and so do these.

import { writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { attrNum, itemsOf, type Item } from '../tests/design/items';

const desktop = resolve(dirname(fileURLToPath(import.meta.url)), '..');
type Region = [number, number, number, number];

const BADGE = /fill="#E1A95F"/i; // a tile's edited dot is drawn by the tile, not the glyph

export function cut(file: string, [x0, y0, x1, y1]: Region, all: Item[] = itemsOf(file)): string {
  const w = x1 - x0, h = y1 - y0;
  const hit = all.filter(({ node, at }) => {
    if (!at || at[0] < x0 || at[0] > x1 || at[1] < y0 || at[1] > y1) return false;
    const a = node.attrs;
    // the region's own face: a tile, a button, a disc
    if (node.tag === 'rect' && (attrNum(a, 'width') ?? 0) >= 0.6 * w && (attrNum(a, 'height') ?? 0) >= 0.6 * h) return false;
    if (node.tag === 'circle' && (attrNum(a, 'r') ?? 0) * 2 >= 0.6 * w && !/fill="none"/.test(a)) return false;
    if (node.tag === 'circle' && BADGE.test(a)) return false;
    // a rule passing through the region (the compare split's line) is not the glyph
    if (node.tag === 'line' && Math.abs((attrNum(a, 'x2') ?? 0) - (attrNum(a, 'x1') ?? 0)) + Math.abs((attrNum(a, 'y2') ?? 0) - (attrNum(a, 'y1') ?? 0)) > 2 * Math.max(w, h)) return false;
    return true;
  });
  if (!hit.length) throw new Error(`${file}: no glyph in [${x0} ${y0} ${x1} ${y1}]`);
  const ids = new Set(hit.flatMap(({ node }) => [...node.raw().matchAll(/url\(#([^)]+)\)/g)].map((m) => m[1])));
  const defs = all.filter((d) => d.def && ids.has(/id="([^"]+)"/.exec(d.node.attrs)?.[1] ?? ''));
  return [...defs, ...hit].map(({ node }) => {
    const [ox, oy] = node.offset;
    return `<g transform="translate(${+(ox - x0).toFixed(3)} ${+(oy - y0).toFixed(3)})">${node.raw()}</g>`;
  }).join('').replace(/#(F9F7F3|DAD8D4|FFFFFF|0F0E0E)\b/gi, 'currentColor').replace(/\s+/g, ' ');
}

// ------------------------------------------------------- the glyphs we use
const E = 'win_edit.svg';
const X3 = 'win_picture_menu.svg';
const E9 = 'win_edit_crop.svg';
const L = 'win_library_catalog.svg';
const L0 = 'win_library_first_run.svg';
const S = 'win_settings_general.svg';
const box = (cx: number, cy: number, r = 24): Region => [cx - r, cy - r, cx + r, cy + r];
const sq = (cx: number, cy: number, r = 12): Region => [cx - r, cy - r, cx + r, cy + r];
export const SPEC: [string, string, Region][] = [
  // Adjust's eleven tiles (PC-E1: 48 epx faces at 1266.5 + 73k, 270 + 72r) and Darkroom's three
  ['brightness', E, box(1266.5, 270)], ['contrast', E, box(1339.5, 270)], ['tone', E, box(1412.5, 270)], ['hsl', E, box(1485.5, 270)],
  ['channels', E, box(1266.5, 342)], ['wheels', E, box(1339.5, 342)], ['vibrance', E, box(1412.5, 342)], ['saturation', E, box(1485.5, 342)],
  ['temperature', E, box(1266.5, 414)], ['curve', E, box(1339.5, 414)], ['vignette', E, box(1412.5, 414)],
  ['enlarger', E, box(1278.7, 674)], ['decode', E, box(1376, 674)], ['effects', E, box(1473.3, 674)],
  // the toolbar (PC-E1)
  ['dockLeft', E, sq(346, 56)], ['back', E, sq(380, 56)], ['forward', E, sq(412, 56)], ['crop', E, sq(854, 54)],
  ['compare', E, sq(971, 56)], ['more', E, sq(1025.25, 56)], ['paste', E, sq(1063, 57)], ['dockRight', E, sq(1188, 56)],
  ['dropDown', E, sq(814.9, 56, 6)],
  // section heads, the filter capsules, the crop-to-card button, the Tone head
  ['chevronDown', E, sq(16, 314, 8)], ['chevronRight', E, sq(1231.75, 742, 8)], ['reset', E, sq(276, 311, 10)],
  ['sectionMore', E, sq(300, 314, 10)], ['filterChevron', E, sq(87.3, 348, 6)], ['cropToCard', E, [276, 336, 306, 360]],
  ['trash', E, sq(1244, 481, 14)], ['undo', E, sq(1278, 481, 14)], ['check', E, sq(1508, 481, 14)],
  ['latitudeChevron', E, sq(1311.1, 96.25, 6)],
  // the picture's command bar flyout (PC-X3)
  ['copy', X3, sq(827, 446)], ['export', X3, sq(1053, 446)],
  // Crop (PC-E9): flip and turn, the orientation pair
  // the Library (PC-L1): the toolbar, the source card, the sidebar's rows
  ['crumb', L, sq(483.4, 51, 6)], ['import', L, sq(858.8, 55.5, 12)], ['gridView', L, sq(1116, 56, 8)], ['listView', L, sq(1145, 56, 8)],
  ['library', L, sq(35, 146.5, 10)], ['sourceSwitch', L, sq(290, 153, 9)], ['capsChevron', L, sq(294, 208, 6)],
  ['collection', L, sq(30, 236, 10)], ['heart', L, sq(30, 264, 10)], ['developing', L, sq(30, 291, 10)], ['recentImports', L, sq(30, 318.5, 10)],
  ['table', L, sq(30, 383, 10)], ['folder', L, sq(30, 790, 10)],
  ['lock', 'win_library_capture_one.svg', sq(537.3, 50, 6)],
  // the empty Library (PC-L0): its four ways in
  ['captureOne', L0, sq(544, 576, 10)], ['addFolder', L0, sq(804, 575.5, 10)],
  // Settings' panes (PC-G2; the page's origin is the window's)
  ['paneGeneral', S, sq(30, 65, 10)], ['paneRecipes', S, sq(30, 102.5, 10)], ['paneRendering', S, sq(30, 179, 10)],
  ['paneEngine', S, sq(30, 217, 10)], ['paneDiagnostics', S, sq(30, 254, 10)],
  // Compare (PC-E10): the split's handle
  ['split', 'win_edit_compare.svg', sq(751.5, 408, 12)],
  ['flip', E9, sq(1248, 390)], ['rotate', E9, sq(1276, 390)], ['portrait', E9, sq(1249, 524, 9)], ['landscape', E9, sq(1284.5, 524, 9)],
];

function main() {
  const args = process.argv.slice(2);
  if (args[0] === '--list') {
    const [file, ...r] = args.slice(1);
    const [x0, y0, x1, y1] = r.length ? r.map(Number) : [-1e9, -1e9, 1e9, 1e9];
    for (const { node, at } of itemsOf(file!)) {
      if (at && at[0] >= x0! && at[0] <= x1! && at[1] >= y0! && at[1] <= y1!)
        console.log(at[0].toFixed(1).padStart(7), at[1].toFixed(1).padStart(6), node.raw().slice(0, 170).replace(/\s+/g, ' '));
    }
    return;
  }
  const cache = new Map<string, Item[]>();
  const lines: string[] = [];
  for (const [name, file, region] of SPEC) {
    if (!cache.has(file)) cache.set(file, itemsOf(file));
    const markup = cut(file, region, cache.get(file));
    lines.push(`  ${name}: { w: ${+(region[2] - region[0]).toFixed(2)}, h: ${+(region[3] - region[1]).toFixed(2)}, svg: ${JSON.stringify(markup)} },`);
  }
  const ts = `// glyphs.generated.ts — written by scripts/gen-glyphs.ts from desktop/design/windows; do not edit.\n` +
    `export const GLYPHS = {\n${lines.join('\n')}\n} as const satisfies Record<string, { w: number; h: number; svg: string }>;\n` +
    `export type GlyphName = keyof typeof GLYPHS;\n`;
  writeFileSync(join(desktop, 'src', 'theme', 'glyphs.generated.ts'), ts);
  console.log(`glyphs: ${SPEC.length} written to src/theme/glyphs.generated.ts`);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
