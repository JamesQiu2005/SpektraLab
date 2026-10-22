import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { newSidecar, encodeSidecar } from '@shared/sidecar';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import type { HelloResult } from '@shared/protocol';
import type { RgbaImage } from '../host/client';
import type * as SessionModule from './session';
import type * as FramesModule from './frames';
import type { DisplayCacheDescriptor } from './displayCache';
const fake = vi.hoisted(() => ({ key: vi.fn(), read: vi.fn(), peek: vi.fn(), forget: vi.fn(),
  write: vi.fn(async (_key: string, _image: RgbaImage, _options: { retain: boolean }) => true),
  open: vi.fn(), close: vi.fn(), render: vi.fn(), source: vi.fn(), load: vi.fn() }));
vi.mock('./displayCache', () => ({ displayCacheKey: fake.key, readDisplayCache: fake.read, writeDisplayCache: fake.write,
  forgetDisplayMemoryCache: fake.forget, peekDisplayCache: fake.peek }));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({ open: fake.open, renderView: fake.render, renderSource: fake.source,
  setParams: async () => ({}), close: fake.close, thumbnail: async () => { throw new Error('No embedded fixture'); } }) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarLoad: fake.load, sidecarSave: async () => '', setTitle: async () => {} }),
  baseName: (p: string) => p.split('/').pop()!, dirName: (p: string) => p.slice(0, p.lastIndexOf('/')) }));
let session: typeof SessionModule, frames: typeof FramesModule;
const state = () => session.sessionStore.getState();
const hello = { methods: ['render_view', 'render_source'], view_formats: ['rgba8', 'rgba16'] } as HelloResult;
const picture = (colorSpace: string): RgbaImage => ({ width: 6, height: 4, nativeSize: { width: 6000, height: 4000 }, data: new Uint8Array(96),
  processedGeometry: GEOMETRY_DEFAULT, format: 'rgba8', colorSpace });
const native = () => ({ session: 's1', width: 6000, height: 4000, kind: 'raw', metadata: { as_shot: { temperature_k: 5409, tint: 16.1 } } });
const settle = () => vi.advanceTimersByTimeAsync(1);
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  fake.key.mockImplementation(async (d: DisplayCacheDescriptor) => JSON.stringify(d));
  fake.read.mockResolvedValue(null);
  fake.peek.mockReturnValue(null);
  fake.open.mockImplementation(async () => native());
  fake.close.mockResolvedValue(undefined);
  fake.render.mockImplementation(async (_sid: string, tier: string) => ({ ...picture('native'), tier, reprinted: true, ms: 1 }));
  fake.source.mockImplementation(async () => picture('source'));
  const saved = newSidecar(); saved.params.filmEdge.seeded = true;
  fake.load.mockResolvedValue(encodeSidecar(saved));
  session = await import('./session'); frames = await import('./frames');
  session.sessionStore.setState({ hello, hostState: { phase: 'ready', hello } });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); });

describe('persistent display warmup', () => {
  it('shows the new cached photo before the old engine close completes', async () => {
    await session.select('/owned/a.ARW');
    let release!: () => void;
    fake.close.mockImplementationOnce(() => new Promise<void>((r) => { release = r; }));
    fake.read.mockImplementation(async () => picture('new-cached-photo'));
    const next = session.select('/owned/b.ARW'); await settle();
    expect(state().selection).toBe('/owned/b.ARW');
    expect(frames.frameImages.print?.colorSpace).toBe('new-cached-photo');
    expect(fake.open).toHaveBeenCalledTimes(1);
    release(); await next;
  });
  it('coalesces quick clicks and closes a superseded open before opening the last photo', async () => {
    let release!: (v: ReturnType<typeof native>) => void;
    fake.open.mockImplementationOnce(() => new Promise((r) => { release = r; }));
    const first = session.select('/owned/a.ARW'); await settle();
    session.click('/owned/b.ARW'); await settle();
    session.click('/owned/c.ARW'); await vi.advanceTimersByTimeAsync(200);
    expect(fake.open).toHaveBeenCalledTimes(1);
    release(native()); await first; await vi.advanceTimersByTimeAsync(200);
    expect(fake.close).toHaveBeenCalledWith('s1');
    expect(fake.open.mock.calls.map(([path]) => path)).toEqual(['/owned/a.ARW', '/owned/c.ARW']);
    expect(state().selection).toBe('/owned/c.ARW');
  });
  it('shows a cached picture while opening but always decodes and renders current engine pixels', async () => {
    let finish!: (v: ReturnType<typeof native>) => void;
    fake.open.mockImplementationOnce(() => new Promise((r) => { finish = r; }));
    fake.read.mockImplementation(async (key: string) => picture(JSON.parse(key).kind === 'print' ? 'cached-print' : 'cached-original'));
    const pending = session.select('/owned/a.ARW'); await settle();
    expect(fake.open).toHaveBeenCalledTimes(1);
    expect(state().engineSession).toBeNull();
    expect(frames.frameImages.print?.colorSpace).toBe('cached-print');
    expect(frames.frameImages.original?.colorSpace).toBe('cached-original');
    expect(state().nativeSize).toEqual({ width: 6000, height: 4000 });
    finish(native()); await pending; await settle();
    expect(frames.frameImages.print?.colorSpace).toBe('native');
    expect(frames.frameImages.original?.colorSpace).toBe('source');
    expect(fake.render).toHaveBeenCalled();
  });
  it('never lets a late cache read overwrite current native pixels or a changed photograph', async () => {
    const releases: ((v: RgbaImage) => void)[] = [];
    fake.read.mockImplementation(() => new Promise((r) => releases.push(r)));
    await session.select('/owned/a.ARW'); await settle();
    const current = frames.frameImages.print;
    for (const r of releases.splice(0)) r(picture('old-cache')); await settle();
    expect(frames.frameImages.print).toBe(current);
    const oldRead = fake.read.mock.calls.length;
    await session.select('/owned/b.ARW'); await settle();
    expect(fake.read.mock.calls.length).toBeGreaterThan(oldRead);
    session.sessionStore.setState({ selection: '/owned/c.ARW' });
    for (const r of releases) r(picture('wrong-photo')); await settle();
    expect(frames.frameImages.print?.colorSpace).toBe('native');
  });
  it('uses canonical As Shot values and complete immutable source, geometry, display and precision descriptors', async () => {
    await session.select('/owned/a.ARW'); await settle();
    const descriptors = fake.key.mock.calls.map(([d]) => d as DisplayCacheDescriptor);
    const before = descriptors.find((d) => d.kind === 'original')!;
    const after = descriptors.filter((d) => d.kind === 'original').at(-1)!;
    expect(before).toEqual(after);
    expect(before.configuration).toMatchObject({ decode: { whiteBalance: 'As Shot', temperature: 0, tint: 0 }, display: 'srgb', longEdge: 2560 });
    expect(descriptors.find((d) => d.kind === 'print')).toMatchObject({ sources: ['/owned/a.ARW'], configuration: { format: 'rgba16', tier: 'full',
      adjustments: expect.any(Object), params: expect.any(Object), sourceGeometry: GEOMETRY_DEFAULT, geometry: GEOMETRY_DEFAULT } });
  });
  it('writes only a completed full fit view under the key acquired before its native request', async () => {
    await session.select('/owned/a.ARW'); await settle(); fake.write.mockClear();
    const events: string[] = [];
    fake.key.mockImplementation(async (d: DisplayCacheDescriptor) => { events.push(`key:${d.kind}`); return `snapshot:${d.kind}`; });
    fake.render.mockImplementation(async (_sid: string, tier: string) => { events.push(`render:${tier}`); return { ...picture('full'), tier, ms: 1 }; });
    await vi.advanceTimersByTimeAsync(450);
    expect(events.indexOf('key:print')).toBeLessThan(events.indexOf('render:full'));
    expect(fake.write).toHaveBeenCalledWith('snapshot:print', expect.objectContaining({ colorSpace: 'full' }), { retain: true });
    fake.write.mockClear(); session.setView({ fit: false, zoom: 1 }); await vi.advanceTimersByTimeAsync(450);
    expect(fake.write).not.toHaveBeenCalled();
  });

  it('retains live pixels only when the exact full snapshot is absent from RAM', async () => {
    await session.select('/owned/a.ARW'); await vi.advanceTimersByTimeAsync(450);
    const fullKey = fake.write.mock.calls.find(([key]) => {
      const d = JSON.parse(key) as DisplayCacheDescriptor;
      return d.kind === 'print' && (d.configuration as { tier?: string }).tier === 'full';
    })![0];
    fake.peek.mockImplementation((key: string) => key === fullKey ? picture('resident-full') : null);
    fake.write.mockClear(); await session.requestPrint();
    expect(fake.write.mock.calls.find(([, image]) => 'tier' in image && image.tier === 'live')?.[2]).toEqual({ retain: false });

    // The screen may still show a full image, but an exposure edit needs its
    // own exact-key live preview until that new full snapshot exists.
    session.sessionStore.setState({ sidecar: { ...state().sidecar,
      adjustments: { ...state().sidecar.adjustments, exposure: 0.75 } } });
    fake.write.mockClear(); await session.requestPrint();
    expect(fake.write.mock.calls.find(([, image]) => 'tier' in image && image.tier === 'live')?.[2]).toEqual({ retain: true });
  });

  it('drops live and same-source camera RAM before retaining the full picture', async () => {
    await session.select('/owned/a.ARW'); await settle();
    const liveKey = fake.write.mock.calls.find(([key]) => {
      const d = JSON.parse(key) as DisplayCacheDescriptor;
      return d.kind === 'print' && (d.configuration as { tier?: string }).tier === 'live';
    })![0];
    const events: { type: string; key: string }[] = [];
    fake.forget.mockImplementation((key: string) => { events.push({ type: 'forget', key }); });
    fake.write.mockImplementation(async (key: string) => { events.push({ type: 'write', key }); return true; });
    await vi.advanceTimersByTimeAsync(450);
    const full = events.findIndex((e) => e.type === 'write' && (JSON.parse(e.key).configuration as { tier?: string }).tier === 'full');
    expect(full).toBeGreaterThan(0);
    expect(events.slice(0, full)).toContainEqual({ type: 'forget', key: liveKey });
    expect(events.slice(0, full).some((e) => e.type === 'forget' && JSON.parse(e.key).sources[0] === '/owned/a.ARW'
      && JSON.parse(e.key).configuration.embeddedCameraPreview === true)).toBe(true);
  });
});
