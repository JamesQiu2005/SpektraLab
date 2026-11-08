import { describe, expect, it } from 'vitest';
import { encodeFrame, FrameDecoder, FrameError } from './framing';

describe('framing', () => {
  it('round-trips a header and a payload', () => {
    const payload = new Uint8Array([1, 2, 3, 250]);
    const bytes = encodeFrame({ id: 7, method: 'ping', params: {} }, payload);
    const frames = new FrameDecoder().push(bytes);
    expect(frames).toHaveLength(1);
    expect(frames[0]!.header).toEqual({ id: 7, method: 'ping', params: {} });
    expect(Array.from(frames[0]!.payload)).toEqual([1, 2, 3, 250]);
  });

  it('reassembles frames split at every byte boundary', () => {
    const a = encodeFrame({ id: 1, ok: true, result: { x: 'é漢' } }, new Uint8Array(1000).fill(9));
    const b = encodeFrame({ event: 'log', level: 'info', message: 'hi' });
    const all = new Uint8Array(a.length + b.length);
    all.set(a);
    all.set(b, a.length);
    for (const step of [1, 3, 7, 64, 999]) {
      const d = new FrameDecoder();
      const got = [];
      for (let i = 0; i < all.length; i += step) got.push(...d.push(all.subarray(i, i + step)));
      expect(got.map((f) => f.header)).toEqual([
        { id: 1, ok: true, result: { x: 'é漢' } },
        { event: 'log', level: 'info', message: 'hi' },
      ]);
      expect(got[0]!.payload.length).toBe(1000);
      expect(got[1]!.payload.length).toBe(0);
      expect(d.pendingBytes).toBe(0);
    }
  });

  it('refuses an absurd header length instead of allocating it', () => {
    const bad = new Uint8Array(8);
    new DataView(bad.buffer).setUint32(0, 0xffffffff, true);
    expect(() => new FrameDecoder().push(bad)).toThrow(FrameError);
  });

  it('refuses a header that is not JSON', () => {
    const json = new TextEncoder().encode('{nope');
    const out = new Uint8Array(8 + json.length);
    new DataView(out.buffer).setUint32(0, json.length, true);
    out.set(json, 8);
    expect(() => new FrameDecoder().push(out)).toThrow(/malformed JSON/);
  });
});
