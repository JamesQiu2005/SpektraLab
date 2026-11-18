// dump.ts — print a region of a design page (a tool for reading the drawing):
//   npx tsx tests/design/dump.ts win_edit.svg x0 x1 y0 y1
import { readPage } from './svg';

const [file, x0, x1, y0, y1] = process.argv.slice(2);
const p = readPage(file!);
const inR = (x: number, y: number) => x >= +x0! && x <= +x1! && y >= +y0! && y <= +y1!;
for (const r of p.rects) if (inR(r.x, r.y)) console.log('R', r.x, r.y, r.width, r.height, r.fill, r.stroke);
for (const l of p.lines) if (inR(l.x1, l.y1)) console.log('L', l.x1, l.y1, l.x2, l.y2, l.stroke);
for (const t of p.texts) if (inR(t.x, t.y)) console.log('T', t.x, t.y, t.size, t.weight, t.fill, t.anchor, t.text);
