import { describe, expect, it } from 'vitest';
import { MockHost } from './core';

const request = (host: MockHost, method: string, params: Record<string, unknown> = {}) =>
  host.handle({ id: 1, method, params });

describe('embedded-only thumbnail capability', () => {
  it('advertises the option and returns a RAW embedded preview', async () => {
    const host = new MockHost();
    expect((await request(host, 'hello')).header.result).toMatchObject({ thumbnail_options: ['embedded-only'] });
    const reply = await request(host, 'thumbnail', { path: '/owned/frame.ARW', long_edge: 320, embedded_only: true });
    expect(reply.header).toMatchObject({ ok: true, result: { source: 'embedded', orientation_applied: true } });
    expect(reply.payload?.byteLength).toBeGreaterThan(0);
  });

  it.each(['true', 1, null, {}])('rejects non-boolean embedded_only %j', async (embedded_only) => {
    const reply = await request(new MockHost(), 'thumbnail', { path: '/owned/frame.ARW', embedded_only });
    expect(reply.header).toMatchObject({ ok: false, error: { code: 'bad_request' } });
  });

  it.each(['frame.png', 'frame.jpg', 'frame.tif', 'frame.heic', 'frame.exr', 'pair.spektrapair'])('refuses %s instead of implicitly decoding it', async (name) => {
    const reply = await request(new MockHost(), 'thumbnail', { path: `/owned/${name}`, embedded_only: true });
    expect(reply.header).toMatchObject({ ok: false, error: { code: 'unsupported' } });
    expect(reply.payload).toBeUndefined();
  });

  it('keeps the existing raster-thumbnail route when the option is false or omitted', async () => {
    const host = new MockHost();
    const legacy = await request(host, 'thumbnail', { path: '/owned/frame.png', long_edge: 320 });
    const explicit = await request(host, 'thumbnail', { path: '/owned/frame.png', long_edge: 320, embedded_only: false });
    expect(explicit.header.ok).toBe(true);
    expect(explicit.payload).toEqual(legacy.payload);
  });
});
