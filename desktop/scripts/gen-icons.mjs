// gen-icons.mjs — the app icon from the macOS Icon Composer document
// (`SpektraLab.icon/Assets/*.svg` + icon.json): a white rounded square with
// the C, M, Y pills and the dark K pill (资源 1, translated 252 pt down).
// Rendered with rsvg-convert (librsvg2-bin) and composited with ImageMagick,
// then handed to `tauri icon`, which writes every size Tauri bundles
// (PNG, .ico for NSIS/Windows, .icns).
//
//   node scripts/gen-icons.mjs        (writes src-tauri/icons/*)

import { execFileSync } from 'node:child_process';
import { mkdirSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const A = resolve(here, '../../modern_UI/Spektrafilm/Spektrafilm/SpektraLab.icon/Assets');
const work = resolve(tmpdir(), 'spektralab-icon-' + process.pid);
mkdirSync(work, { recursive: true });
const S = 1024;
const svg = (name, out, w = S) => execFileSync('rsvg-convert', ['-w', String(w), resolve(A, name), '-o', resolve(work, out)]);

// The shape's own art is a mask; draw the plate ourselves at the same radius
// as macOS's squircle-ish 22.4 % corner, inset 10 % as Big Sur icons are.
const inset = Math.round(S * 0.1);
const radius = Math.round((S - 2 * inset) * 0.224);
execFileSync('convert', [
  '-size', `${S}x${S}`, 'xc:none',
  '-fill', 'white', '-draw', `roundrectangle ${inset},${inset} ${S - inset},${S - inset} ${radius},${radius}`,
  resolve(work, 'plate.png'),
]);
svg('4.1 – layer.svg', 'c.png');
svg('3.4 – layer.svg', 'm.png');
svg('2.2 – layer.svg', 'y.png');
// 资源 1 is 842×328 pt, centred in the 1024 canvas and moved 252 pt down.
svg('资源 1.svg', 'k.png', Math.round(842 * (S / 1024)));
execFileSync('convert', [
  resolve(work, 'plate.png'),
  resolve(work, 'k.png'), '-gravity', 'center', '-geometry', `+0+${Math.round(252 * (S / 1024))}`, '-composite',
  resolve(work, 'y.png'), '-gravity', 'center', '-geometry', '+0+0', '-composite',
  resolve(work, 'm.png'), '-composite',
  resolve(work, 'c.png'), '-composite',
  resolve(work, 'icon-1024.png'),
]);
execFileSync('npx', ['tauri', 'icon', resolve(work, 'icon-1024.png'), '-o', resolve(here, '../src-tauri/icons')], { stdio: 'inherit' });
rmSync(work, { recursive: true, force: true });
