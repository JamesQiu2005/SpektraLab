// Against the real engine host, when one is staged: the export path end to
// end — open a RAW, render the print as rgba16 in ProPhoto, crop + quarter
// turn + a grade through `filePixels` (the canvas's arithmetic), hand it to
// `write_image`, and check the file the host wrote.
//
//   SPEKTRALAB_HOST_DIR=../build/host-linux-x64 SPEKTRALAB_TEST_RAW=/path/x.CR2 npx vitest run realhost
//
// Skipped (and says so) without both variables: a CI box with no GPU host
// must not report this as passing.

import { spawn } from 'node:child_process';
import { closeSync, existsSync, mkdtempSync, openSync, readFileSync, readSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { FrameDecoder, encodeFrame } from '@shared/framing';
import { ADJUSTMENTS_DEFAULT, PROPHOTO_MID_GREY, SRGB_MID_GREY } from '@shared/adjustments';
import { GEOMETRY_DEFAULT, outputSize } from '@shared/geometry';
import { FILM_PARAMS_DEFAULT, fullDelta } from '@shared/params';
import { engineGeometry, printGeometry } from '@shared/filmFrame';
import { resolveImprints } from '@shared/imprints';
import { filePixels } from './exporter';

const dir = process.env.SPEKTRALAB_HOST_DIR;
const raw = process.env.SPEKTRALAB_TEST_RAW;
const hostName = process.platform === 'win32' ? 'spektralab-host.exe' : 'spektralab-host';
const enabled = !!dir && !!raw && existsSync(join(dir, hostName));

function hostConn(d: string) {
  const p = spawn(join(d, hostName), ['--resources', join(d, 'engine')], { stdio: ['pipe', 'pipe', 'inherit'] });
  const dec = new FrameDecoder();
  const waiting = new Map<number, (r: { header: Record<string, unknown>; payload: Uint8Array }) => void>();
  p.stdout!.on('data', (c: Buffer) => {
    for (const f of dec.push(new Uint8Array(c))) {
      const h = f.header as Record<string, unknown>;
      if (typeof h.id === 'number') { const resolve = waiting.get(h.id); waiting.delete(h.id); resolve?.({ header: h, payload: f.payload }); }
    }
  });
  let id = 1;
  return {
    call(method: string, params: Record<string, unknown>, payload?: Uint8Array) {
      const i = id++;
      return new Promise<{ header: Record<string, unknown>; payload: Uint8Array }>((res) => {
        waiting.set(i, res);
        p.stdin!.write(encodeFrame({ id: i, method, params }, payload));
      });
    },
    close: () => p.stdin!.end(),
  };
}

describe.skipIf(!enabled)('the real host', () => {
  it('prints the bare date into the cropped and turned negative, with no date lost or second crop', async () => {
    const h = hostConn(dir!);
    try {
      const opened = await h.call('open', { path: raw, params: { preview_long_edge: 800 } });
      expect(opened.header.ok, JSON.stringify(opened.header.error)).toBe(true);
      const info = opened.header.result as { session: string; width: number; height: number };
      const g = { ...GEOMETRY_DEFAULT, crop: { x: 0.2, y: 0.2, width: 0.5, height: 0.5 }, quarterTurns: 1 };
      const p = resolveImprints({ ...FILM_PARAMS_DEFAULT, autoExposure: false, filmFormatMM: 36,
        grainActive: false, glareActive: false, halationActive: false,
        dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true, customText: "'26 10 1" } }, null, 1.5, g, info);
      const delta = { ...fullDelta(p), ...engineGeometry(p, g, info) };
      async function render(active: boolean) {
        const set = await h.call('set_params', { session: info.session, delta: { ...delta, date_imprint_active: active } });
        expect(set.header.ok, JSON.stringify(set.header.error)).toBe(true);
        const r = await h.call('render', { session: info.session, tier: 'live', format: 'rgba16', display: 'srgb' });
        expect(r.header.ok, JSON.stringify(r.header.error)).toBe(true);
        const image = (r.header.result as { image: { width: number; height: number } }).image;
        return { image, pixels: new Uint16Array(r.payload.slice().buffer) };
      }
      const plain = await render(false), dated = await render(true);
      expect(dated.image).toEqual(plain.image);
      expect(dated.image.width / dated.image.height).toBeCloseTo(info.height / info.width, 2);
      const out = outputSize(printGeometry(p, g), dated.image);
      expect(dated.image).toMatchObject(out);
      let changed = 0, sumX = 0, sumY = 0;
      const bounds = { left: out.width, top: out.height, right: 0, bottom: 0 };
      for (let y = 0; y < out.height; y++) for (let x = 0; x < out.width; x++) {
        const i = (y*out.width+x)*4;
        // Same developed-date detection threshold as overscan_checks.py;
        // faint optical scatter is not the glyph's bounding box.
        if ([0,1,2].reduce((sum, c) => sum+Math.abs(dated.pixels[i+c]!-plain.pixels[i+c]!), 0) > 2000) {
          changed++;
          sumX += x; sumY += y;
          bounds.left = Math.min(bounds.left, x); bounds.top = Math.min(bounds.top, y);
          bounds.right = Math.max(bounds.right, x); bounds.bottom = Math.max(bounds.bottom, y);
          // Original RFC-032: a portrait 135 carries the film's BR date
          // vertically at the picture's lower left, not upright on-screen.
        }
      }
      expect(changed).toBeGreaterThan(30);
      const destination = mkdtempSync(join(tmpdir(), 'spk-bare-date-crop-'));
      for (const [name, image] of [['plain', plain], ['dated', dated]] as const) {
        const result = await h.call('write_image', { path: join(destination, `${name}.tif`),
          format: 'tiff16', color_space: 'sRGB', ...out }, new Uint8Array(image.pixels.buffer));
        expect(result.header.ok, JSON.stringify(result.header.error)).toBe(true);
      }
      console.log(JSON.stringify({ destination, ...out, changed, centre: [sumX/changed, sumY/changed], bounds }));
      expect(sumX/changed).toBeLessThan(out.width*0.4);
      expect(sumY/changed).toBeGreaterThan(out.height*0.6);
      expect(bounds.bottom-bounds.top).toBeGreaterThan(2.5*(bounds.right-bounds.left));
    } finally { h.close(); }
  }, 300_000);
  it('writes a developed film edge, date and grade in JPEG, PNG and TIFF without a second crop', async () => {
    const h = hostConn(dir!);
    try {
      const p = { ...FILM_PARAMS_DEFAULT, grainActive: false, glareActive: false,
        filmEdge: { ...FILM_PARAMS_DEFAULT.filmEdge, active: true, frameNumber: 50, carrier: 'black' },
        dateBack: { ...FILM_PARAMS_DEFAULT.dateBack, active: true, customText: '26 10 26' } };
      const opened = await h.call('open', { path: raw, params: { ...fullDelta(p), preview_long_edge: 800 } });
      expect(opened.header.ok, JSON.stringify(opened.header.error)).toBe(true);
      const info = opened.header.result as { session: string; width: number; height: number };
      const g = { ...GEOMETRY_DEFAULT, quarterTurns: 1 };
      const set = await h.call('set_params', { session: info.session, delta: engineGeometry(p, g, info) });
      expect(set.header.ok, JSON.stringify(set.header.error)).toBe(true);
      const tier = process.env.SPEKTRALAB_TEST_FULL === '1' ? 'full' : 'live';
      const rendered = await h.call('render', { session: info.session, tier, format: 'rgba16', display: 'srgb' });
      expect(rendered.header.ok, JSON.stringify(rendered.header.error)).toBe(true);
      const image = (rendered.header.result as { image: { width: number; height: number } }).image;
      const layout = await h.call('overscan_geometry', { session: info.session });
      expect(layout.header.ok).toBe(true);
      expect((layout.header.result as { valid: boolean }).valid).toBe(true);
      expect((layout.header.result as { vertical: boolean }).vertical).toBe(true);
      const src = new Uint16Array(rendered.payload.buffer.slice(rendered.payload.byteOffset, rendered.payload.byteOffset + image.width * image.height * 8));
      const out = outputSize(printGeometry(p, g), image);
      expect(out).toEqual({ width: image.width, height: image.height });
      const px = filePixels(src, image, printGeometry(p, g), { ...ADJUSTMENTS_DEFAULT, exposure: 0.3 }, out, SRGB_MID_GREY);
      expect(px.some((v, i) => i % 4 !== 3 && v !== src[i])).toBe(true);
      const destination = mkdtempSync(join(tmpdir(), 'spk-film-edge-'));
      for (const [format, ext, magic] of [['jpeg', 'jpg', [255, 216]], ['png', 'png', [137, 80]], ['tiff16', 'tif', [73, 73]]] as const) {
        const target = join(destination, `Portra_400_50.${ext}`);
        const written = await h.call('write_image', { path: target, format, color_space: 'sRGB', width: out.width, height: out.height, source_path: raw }, new Uint8Array(px.buffer));
        expect(written.header.ok, JSON.stringify(written.header.error)).toBe(true);
        expect((written.header.result as { width: number; height: number })).toMatchObject(out);
        const fd = openSync(target, 'r'), signature = Buffer.alloc(2);
        try { readSync(fd, signature, 0, 2, 0); } finally { closeSync(fd); }
        expect([...signature]).toEqual(magic);
        expect(statSync(target).size).toBeGreaterThan(1024);
      }
      console.log(JSON.stringify({ tier, destination, width: out.width, height: out.height }));
    } finally { h.close(); }
  }, 600_000);
  it('writes the canvas frame (crop + turn + grade) through write_image', async () => {
    const h = hostConn(dir!);
    try {
      const hello = await h.call('hello', {});
      expect((hello.header.result as { methods: string[] }).methods).toContain('write_image');
      const open = await h.call('open', { path: raw, params: { preview_long_edge: 800 } });
      expect(open.header.ok, JSON.stringify(open.header.error)).toBe(true);
      const sid = (open.header.result as { session: string }).session;
      const r = await h.call('render', { session: sid, tier: 'live', format: 'rgba16', display: 'prophoto' });
      expect(r.header.ok, JSON.stringify(r.header.error)).toBe(true);
      const img = (r.header.result as { image: { width: number; height: number; color_space: string } }).image;
      expect(img.color_space).toMatch(/ProPhoto/i);
      const src = new Uint16Array(r.payload.buffer.slice(r.payload.byteOffset, r.payload.byteOffset + img.width * img.height * 8));
      const g = { ...GEOMETRY_DEFAULT, crop: { x: 0.1, y: 0.1, width: 0.6, height: 0.7 }, quarterTurns: 1 };
      const out = outputSize(g, img);
      const px = filePixels(src, img, g, { ...ADJUSTMENTS_DEFAULT, exposure: 0.5 }, out, PROPHOTO_MID_GREY);
      const target = join(mkdtempSync(join(tmpdir(), 'spk-export-')), 'proof.tif');
      const w = await h.call('write_image', { path: target, format: 'tiff16', color_space: 'prophoto', width: out.width, height: out.height }, new Uint8Array(px.buffer));
      expect(w.header.ok, JSON.stringify(w.header.error)).toBe(true);
      expect(existsSync(target)).toBe(true);
      expect(statSync(target).size).toBeGreaterThan(out.width * out.height * 6);
      // A quarter turn: the file is taller than wide for a landscape frame.
      const res = w.header.result as { width: number; height: number };
      expect([res.width, res.height]).toEqual([out.width, out.height]);
      expect(img.width > img.height ? res.height > res.width : true).toBe(true);
      expect(readFileSync(target).subarray(0, 2).toString()).toBe('II');
    } finally {
      h.close();
    }
  }, 300_000);
});
