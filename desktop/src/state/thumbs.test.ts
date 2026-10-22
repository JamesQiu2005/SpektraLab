import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
const fake = vi.hoisted(() => ({ thumbnail: vi.fn(), url: vi.fn(), revoke: vi.fn() }));
vi.mock('../host/client', () => ({ host: () => ({ thumbnail: fake.thumbnail }) }));
vi.mock('./frames', () => ({ rgbaToURL: fake.url }));
beforeEach(() => { vi.resetModules(); vi.clearAllMocks(); vi.spyOn(URL, 'revokeObjectURL').mockImplementation(fake.revoke); });
afterEach(() => vi.restoreAllMocks());
describe('thumbnail invalidation', () => {
  it('revokes an obsolete result instead of reinstalling it after an external edit', async () => {
    let finish!: (value: object) => void;
    fake.thumbnail.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; })).mockResolvedValue({});
    fake.url.mockResolvedValueOnce('blob:old').mockResolvedValueOnce('blob:new');
    const { thumbs } = await import('./thumbs');
    expect(thumbs.get('/a')).toBeNull(); thumbs.invalidate('/a');
    finish({}); await new Promise((r) => setTimeout(r, 0));
    expect(fake.revoke).toHaveBeenCalledWith('blob:old');
    expect(thumbs.get('/a')).toBeNull(); await new Promise((r) => setTimeout(r, 0));
    expect(thumbs.get('/a')).toBe('blob:new');
  });
  it('discards a pending old-library thumbnail after reset', async () => {
    let finish!: (value: object) => void;
    fake.thumbnail.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    fake.url.mockResolvedValue('blob:old-library');
    const { thumbs } = await import('./thumbs');
    thumbs.get('/a'); thumbs.reset(); finish({}); await new Promise((r) => setTimeout(r, 0));
    expect(fake.revoke).toHaveBeenCalledWith('blob:old-library');
  });
});

describe('thumbnail scheduling', () => {
  it('pauses queued work without duplicating or replacing the two active requests', async () => {
    const finishes: (() => void)[] = [];
    fake.thumbnail.mockImplementation(() => new Promise((resolve) => finishes.push(() => resolve({}))));
    fake.url.mockResolvedValue('blob:preview');
    const { thumbs } = await import('./thumbs');
    thumbs.get('/a'); thumbs.get('/b'); thumbs.get('/c');
    expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/a', '/b']);
    thumbs.setPaused(true);
    finishes[0]!(); finishes[1]!();
    await new Promise((r) => setTimeout(r, 0));
    thumbs.get('/c');
    expect(fake.thumbnail).toHaveBeenCalledTimes(2);
    thumbs.setPaused(false); thumbs.setPaused(false);
    expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/a', '/b', '/c']);
    finishes[2]!(); await new Promise((r) => setTimeout(r, 0));
  });

  it('only queues nearby filmstrip entries and drops unseen queued work without dropping an export request', async () => {
    fake.thumbnail.mockResolvedValue({});
    fake.url.mockResolvedValue('blob:preview');
    const { thumbs } = await import('./thumbs');
    thumbs.setPaused(true);
    thumbs.setFilmstripPaths(['/a', '/b', '/c']);
    for (const path of ['/a', '/b', '/c', '/offscreen']) thumbs.get(path, 'filmstrip');
    thumbs.get('/c'); // The export page needs this entry independently of the strip.
    thumbs.setFilmstripPaths(['/b']);
    thumbs.setPaused(false);
    await new Promise((r) => setTimeout(r, 0));
    expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/b', '/c']);
    thumbs.setFilmstripPaths(['/a']); thumbs.get('/a', 'filmstrip');
    await new Promise((r) => setTimeout(r, 0));
    expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/b', '/c', '/a']);
  });

  it('keeps the caller-owned pause across cache resets', async () => {
    fake.thumbnail.mockResolvedValue({}); fake.url.mockResolvedValue('blob:preview');
    const { thumbs } = await import('./thumbs');
    thumbs.setPaused(true); thumbs.get('/old'); thumbs.reset(); thumbs.get('/new');
    expect(fake.thumbnail).not.toHaveBeenCalled();
    thumbs.setPaused(false); await new Promise((r) => setTimeout(r, 0));
    expect(fake.thumbnail.mock.calls.map(([path]) => path)).toEqual(['/new']);
  });
});
