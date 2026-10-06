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
import { existsSync, mkdtempSync, readFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { FrameDecoder, encodeFrame } from '@shared/framing';
import { ADJUSTMENTS_DEFAULT, PROPHOTO_MID_GREY } from '@shared/adjustments';
import { GEOMETRY_DEFAULT, outputSize } from '@shared/geometry';
import { filePixels } from './exporter';

const dir = process.env.SPEKTRALAB_HOST_DIR;
const raw = process.env.SPEKTRALAB_TEST_RAW;
const executable = process.platform === 'win32' ? 'spektralab-host.exe' : 'spektralab-host';
// An explicitly requested integration run must fail on a broken staging path,
// not quietly report a skip (the old extensionless check did that on Windows).
const enabled = !!dir && !!raw;

function hostConn(d: string) {
  const p = spawn(join(d, executable), ['--resources', join(d, 'engine')], { stdio: ['pipe', 'pipe', 'inherit'] });
  const dec = new FrameDecoder();
  const waiting = new Map<number, (r: { header: Record<string, unknown>; payload: Uint8Array }) => void>();
  p.stdout!.on('data', (c: Buffer) => {
    for (const f of dec.push(new Uint8Array(c))) {
      const h = f.header as Record<string, unknown>;
      if (typeof h.id === 'number') waiting.get(h.id)?.({ header: h, payload: f.payload });
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
  it('writes the canvas frame (crop + turn + grade) through write_image', async () => {
    expect(existsSync(join(dir!, executable)), `Host executable missing: ${join(dir!, executable)}`).toBe(true);
    expect(existsSync(raw!), `RAW fixture missing: ${raw}`).toBe(true);
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
