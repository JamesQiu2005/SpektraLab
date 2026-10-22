import { beforeEach, describe, expect, it, vi } from 'vitest';
import { decodeFrame, encodeFrame } from '@shared/framing';
import type { RgbaImage } from '../host/client';
import type * as Cache from './displayCache';

const fake = vi.hoisted(() => ({ invoke: vi.fn(), native: true }));
vi.mock('@tauri-apps/api/core', () => ({ invoke: fake.invoke }));
vi.mock('../host/transport', () => ({ inTauri: () => fake.native }));
let cache: typeof Cache;
const key = (n: number) => n.toString(16).padStart(64, '0');
const image = (value = 1, format: RgbaImage['format'] = 'rgba8'): RgbaImage => ({
  width: 2, height: 2, data: new Uint8Array(format === 'rgba16' ? 32 : 16).fill(value), format, colorSpace: 'sRGB',
});
function diskImage(picture: RgbaImage): ArrayBuffer {
  const { data, ...metadata } = picture;
  return encodeFrame({ hit: true, metadata: { image: metadata } }, data).buffer as ArrayBuffer;
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => { resolve = done; });
  return { promise, resolve };
}
const settle = () => new Promise((done) => setTimeout(done, 0));

beforeEach(async () => {
  vi.resetModules(); fake.invoke.mockReset(); fake.native = true;
  fake.invoke.mockResolvedValue(true);
  cache = await import('./displayCache');
});

describe('bounded recent display pictures', () => {
  it('makes a completed render available synchronously before disk writing finishes', async () => {
    const disk = deferred<void>(); fake.invoke.mockReturnValue(disk.promise);
    const picture = image();
    const writing = cache.writeDisplayCache(key(1), picture);
    expect(cache.peekDisplayCache(key(1))?.data).toBe(picture.data);
    expect(await cache.readDisplayCache(key(1))).toEqual(picture);
    expect(fake.invoke).toHaveBeenCalledTimes(1);
    disk.resolve(); await writing;
  });

  it('evicts by least recent use and accounts for rgba16 and retained backing buffers', async () => {
    fake.native = false; cache.configureDisplayMemoryCache(64);
    await cache.writeDisplayCache(key(1), image(1));
    await cache.writeDisplayCache(key(2), image(2, 'rgba16'));
    expect(cache.peekDisplayCache(key(1))).not.toBeNull();
    await cache.writeDisplayCache(key(3), { ...image(3), data: new Uint8Array(32).subarray(0, 16) });
    expect(cache.peekDisplayCache(key(2))).toBeNull();
    expect(cache.peekDisplayCache(key(1))?.data[0]).toBe(1);
    expect(cache.displayMemoryCacheStatus()).toEqual({ cap_bytes: 64, bytes: 48, entries: 2 });
    cache.configureDisplayMemoryCache(16);
    expect(cache.displayMemoryCacheStatus()).toEqual({ cap_bytes: 16, bytes: 16, entries: 1 });
    await cache.writeDisplayCache(key(4), { ...image(4), data: new Uint8Array(100).subarray(0, 16) });
    expect(cache.peekDisplayCache(key(4))).toBeNull();
    expect(cache.peekDisplayCache(key(1))).not.toBeNull();
  });

  it('deduplicates disk reads and retains the valid result in memory', async () => {
    const disk = deferred<ArrayBuffer>(); fake.invoke.mockReturnValue(disk.promise);
    const a = cache.readDisplayCache(key(1)), b = cache.readDisplayCache(key(1));
    expect(fake.invoke).toHaveBeenCalledTimes(1);
    disk.resolve(diskImage(image()));
    expect(await a).toEqual(await b);
    expect(await cache.readDisplayCache(key(1))).toEqual(await a);
    expect(fake.invoke).toHaveBeenCalledTimes(1);
  });

  it('forgets only the requested RAM picture and leaves its disk copy available', async () => {
    await cache.writeDisplayCache(key(1), image(1));
    await cache.writeDisplayCache(key(2), image(2));
    fake.invoke.mockClear();
    cache.forgetDisplayMemoryCache(key(1));
    cache.forgetDisplayMemoryCache(null);
    cache.forgetDisplayMemoryCache(key(99));
    expect(cache.peekDisplayCache(key(1))).toBeNull();
    expect(cache.peekDisplayCache(key(2))?.data[0]).toBe(2);
    expect(cache.displayMemoryCacheStatus()).toMatchObject({ entries: 1, bytes: 16 });
    expect(fake.invoke).not.toHaveBeenCalled();
    fake.invoke.mockResolvedValue(diskImage(image(1)));
    expect((await cache.readDisplayCache(key(1), { retain: false }))?.data[0]).toBe(1);
    expect(fake.invoke).toHaveBeenCalledWith('frame_cache_read', { key: key(1) });
    expect(cache.peekDisplayCache(key(1))).toBeNull();
  });

  it('does not restore an in-flight disk result after memory invalidation', async () => {
    const old = deferred<ArrayBuffer>(); fake.invoke.mockReturnValueOnce(old.promise).mockResolvedValue(diskImage(image(2)));
    const reading = cache.readDisplayCache(key(1));
    cache.clearDisplayMemoryCache();
    expect((await cache.readDisplayCache(key(1)))?.data[0]).toBe(2);
    old.resolve(diskImage(image(1)));
    expect(await reading).toBeNull();
    expect(cache.peekDisplayCache(key(1))?.data[0]).toBe(2);
  });

  it('does not replace newer rendered pixels with a late disk read', async () => {
    const old = deferred<ArrayBuffer>();
    fake.invoke.mockImplementation((method: string) => method === 'frame_cache_read' ? old.promise : Promise.resolve());
    const reading = cache.readDisplayCache(key(1));
    await cache.writeDisplayCache(key(1), image(2));
    old.resolve(diskImage(image(1)));
    expect((await reading)?.data[0]).toBe(2);
    expect(cache.peekDisplayCache(key(1))?.data[0]).toBe(2);
  });

  it('keeps background-folder reads and writes out of the recent-picture budget', async () => {
    cache.configureDisplayMemoryCache(16);
    await cache.writeDisplayCache(key(1), image(1));
    await cache.writeDisplayCache(key(2), image(2), { retain: false });
    fake.invoke.mockResolvedValue(diskImage(image(3)));
    expect((await cache.readDisplayCache(key(3), { retain: false }))?.data[0]).toBe(3);
    expect(cache.peekDisplayCache(key(2))).toBeNull();
    expect(cache.peekDisplayCache(key(3))).toBeNull();
    expect(cache.peekDisplayCache(key(1))?.data[0]).toBe(1);
  });

  it('rejects malformed entries and retries failed reads instead of caching failures', async () => {
    const invalid = [
      { ...image(), width: 0 }, { ...image(), height: 1.5 }, { ...image(), width: NaN },
      { ...image(), colorSpace: 'ProPhoto RGB' }, { ...image(), data: new Uint8Array(15) },
    ];
    for (const [i, picture] of invalid.entries()) await cache.writeDisplayCache(key(i), picture);
    expect(cache.displayMemoryCacheStatus().entries).toBe(0);
    expect(fake.invoke).not.toHaveBeenCalled();
    fake.invoke.mockRejectedValueOnce(new Error('unreadable')).mockResolvedValueOnce(diskImage(invalid[1]!)).mockResolvedValueOnce(diskImage(image()));
    expect(await cache.readDisplayCache(key(1))).toBeNull();
    expect(await cache.readDisplayCache(key(1))).toBeNull();
    expect(await cache.readDisplayCache(key(1))).not.toBeNull();
    expect(fake.invoke).toHaveBeenCalledTimes(3);
  });
});

describe('bounded display writeback', () => {
  it('reports disabled or unwritable disk caching only when the picture remains in RAM', async () => {
    fake.invoke.mockResolvedValue(false); // Native cache disabled or too small.
    expect(await cache.writeDisplayCache(key(1), image(), { retain: false })).toBe(false);
    expect(cache.peekDisplayCache(key(1))).toBeNull();
    expect(await cache.writeDisplayCache(key(2), image())).toBe(true);
    fake.invoke.mockRejectedValue(new Error('disk full'));
    expect(await cache.writeDisplayCache(key(3), image(), { retain: false })).toBe(false);
    expect(await cache.writeDisplayCache(key(4), image())).toBe(true);
  });

  it('counts an unretained picture only after native storage confirms success', async () => {
    fake.invoke.mockResolvedValue(true);
    expect(await cache.writeDisplayCache(key(1), image(), { retain: false })).toBe(true);
    expect(cache.peekDisplayCache(key(1))).toBeNull();
    fake.invoke.mockResolvedValue(undefined);
    expect(await cache.writeDisplayCache(key(2), image(), { retain: false })).toBe(false);
  });

  it('reports a displaced pending picture as unavailable after its RAM copy was evicted', async () => {
    cache.configureDisplayMemoryCache(16);
    const first = deferred<boolean>(); fake.invoke.mockReturnValueOnce(first.promise).mockResolvedValue(true);
    const a = cache.writeDisplayCache(key(1), image(1), { retain: false });
    const b = cache.writeDisplayCache(key(2), image(2));
    const c = cache.writeDisplayCache(key(3), image(3));
    expect(cache.peekDisplayCache(key(2))).toBeNull();
    expect(await b).toBe(false);
    first.resolve(true);
    expect(await a).toBe(true);
    expect(await c).toBe(true);
  });

  it('checks RAM at active completion rather than remembering that it was initially retained', async () => {
    cache.configureDisplayMemoryCache(16);
    const first = deferred<boolean>(); fake.invoke.mockReturnValueOnce(first.promise).mockResolvedValue(true);
    const a = cache.writeDisplayCache(key(1), image(1));
    const b = cache.writeDisplayCache(key(2), image(2));
    first.resolve(false);
    expect(await a).toBe(false);
    expect(await b).toBe(true);
  });

  it('returns false for pending and active writes invalidated by a cache clear', async () => {
    const first = deferred<boolean>(); fake.invoke.mockReturnValueOnce(first.promise).mockResolvedValue(true);
    const a = cache.writeDisplayCache(key(1), image(1));
    const b = cache.writeDisplayCache(key(2), image(2));
    const clearing = cache.clearDisplayCache();
    expect(await b).toBe(false);
    first.resolve(true); // The soon-to-be-deleted native file is not a ready preview.
    expect(await a).toBe(false);
    await clearing;
    expect(cache.displayMemoryCacheStatus().entries).toBe(0);
  });

  it('serializes writes and retains only the newest pending picture', async () => {
    const first = deferred<void>(); fake.invoke.mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
    const a = cache.writeDisplayCache(key(1), image(1));
    const b = cache.writeDisplayCache(key(2), image(2));
    const c = cache.writeDisplayCache(key(3), image(3));
    await b; // A displaced pending item does not leave an unresolved caller.
    expect(fake.invoke).toHaveBeenCalledTimes(1);
    expect(cache.peekDisplayCache(key(3))?.data[0]).toBe(3);
    first.resolve(); await Promise.all([a, c]);
    expect(fake.invoke).toHaveBeenCalledTimes(2);
    const headers = fake.invoke.mock.calls.map(([, bytes]) => decodeFrame(bytes as Uint8Array).header as { key: string });
    expect(headers.map((header) => header.key)).toEqual([key(1), key(3)]);
  });

  it('clears memory and queued work immediately, then clears disk after the active write', async () => {
    const first = deferred<void>(); fake.invoke.mockReturnValueOnce(first.promise).mockResolvedValue(undefined);
    const a = cache.writeDisplayCache(key(1), image(1));
    const b = cache.writeDisplayCache(key(2), image(2));
    const clearing = cache.clearDisplayCache();
    expect(cache.peekDisplayCache(key(1))).toBeNull();
    await b; await settle();
    expect(fake.invoke).toHaveBeenCalledTimes(1);
    first.resolve(); await Promise.all([a, clearing]);
    expect(fake.invoke.mock.calls.map(([method]) => method)).toEqual(['frame_cache_write', 'frame_cache_clear']);
    expect(cache.displayMemoryCacheStatus().entries).toBe(0);
  });

  it('continues with the latest pending picture after an unwritable disk error', async () => {
    const first = deferred<void>();
    fake.invoke.mockReturnValueOnce(first.promise.then(() => { throw new Error('disk full'); })).mockResolvedValue(undefined);
    const a = cache.writeDisplayCache(key(1), image(1)), b = cache.writeDisplayCache(key(2), image(2));
    first.resolve(); await Promise.all([a, b]);
    expect(fake.invoke).toHaveBeenCalledTimes(2);
    expect(cache.peekDisplayCache(key(2))?.data[0]).toBe(2);
  });
});
