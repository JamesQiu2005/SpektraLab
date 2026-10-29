import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult } from '@shared/protocol';
import { encodeSidecar, newSidecar } from '@shared/sidecar';
import type { RgbaImage, RenderReply } from '../host/client';
import type { DisplayCacheDescriptor } from './displayCache';
import type * as SessionModule from './session';

const fake = vi.hoisted(() => ({
  key: vi.fn(), read: vi.fn(), write: vi.fn(async (_key: string, _image: RgbaImage) => true), thumbnail: vi.fn(),
  open: vi.fn(), close: vi.fn(async () => {}), renderView: vi.fn(), renderSource: vi.fn(), load: vi.fn(), files: vi.fn(),
  frames: { print: null as RenderReply | null, original: null as RgbaImage | null },
  pauseThumbs: vi.fn(), forget: vi.fn(),
}));
vi.mock('./displayCache', () => ({ displayCacheKey: fake.key, readDisplayCache: fake.read, writeDisplayCache: fake.write,
  forgetDisplayMemoryCache: fake.forget, peekDisplayCache: vi.fn(() => null) }));
vi.mock('./frames', () => ({ frameImages: fake.frames, makeThumbFromPrint: async () => null, THUMB_EDGE: 320 }));
vi.mock('./thumbs', () => ({ thumbs: { reset: vi.fn(), setPaused: fake.pauseThumbs, setPrint: vi.fn() } }));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  open: fake.open, close: fake.close, renderView: fake.renderView, renderSource: fake.renderSource,
  thumbnail: fake.thumbnail, setParams: async () => ({}),
}) }));
vi.mock('../platform', () => ({ platform: () => ({
  log: vi.fn(), listImages: fake.files, sidecarLoad: fake.load, sidecarSave: async () => '', setTitle: async () => {},
}), baseName: (path: string) => path.split('/').pop()!, dirName: () => '/owned' }));

let session: typeof SessionModule;
const image = (colorSpace = 'srgb'): RgbaImage => ({ width: 4, height: 3, data: new Uint8Array(48), colorSpace, format: 'rgba8' });
const file = (name: string) => ({ path: `/owned/${name}`, name, size: 1024, mtime_ms: 123 });
const hello = (enabled = true) => ({ methods: ['render_view', 'render_source'],
  ...(enabled ? { thumbnail_options: ['embedded-only'] } : {}) }) as HelloResult;
function ready(enabled = true) {
  const h = hello(enabled);
  session.sessionStore.setState({ hello: h, hostState: { phase: 'ready', hello: h } });
}
const cameraKey = (key: string) => (JSON.parse(key) as DisplayCacheDescriptor).configuration as { embeddedCameraPreview?: boolean };

beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  fake.frames.print = null; fake.frames.original = null;
  fake.key.mockImplementation(async (descriptor: DisplayCacheDescriptor) => JSON.stringify(descriptor));
  fake.read.mockResolvedValue(null);
  fake.write.mockResolvedValue(true);
  fake.thumbnail.mockResolvedValue(image());
  fake.open.mockImplementation(async (path: string) => ({ session: `sid:${path}`, width: 6000, height: 4000, kind: 'raw', metadata: {} }));
  fake.renderView.mockImplementation(async (_sid: string, tier: string) => ({ ...image(), tier, reprinted: true, ms: 1 }));
  fake.renderSource.mockResolvedValue(image());
  const sidecar = newSidecar(); sidecar.params.filmEdge.seeded = true;
  fake.load.mockResolvedValue(encodeSidecar(sidecar));
  fake.files.mockResolvedValue([file('first.jpg'), file('next.ARW'), file('other.tiff'), file('last.NEF')]);
  session = await import('./session'); ready();
});
afterEach(() => { session.importPreviews.dispose(); vi.clearAllTimers(); vi.useRealTimers(); });

describe('background import preview integration', () => {
  it('does not count an extracted camera preview whose cache write was rejected as prepared', async () => {
    fake.write.mockResolvedValue(false);
    await session.openFolder('/owned');
    await vi.advanceTimersByTimeAsync(2500);
    expect(session.importPreviews.getSnapshot()).toMatchObject({ total: 2, completed: 0, skipped: 2, failed: 0 });
    expect(session.sessionStore.getState().lastError).toBeNull();
  });

  it('queues only RAW camera previews with explicit host support and never opens a background RAW session', async () => {
    await session.openFolder('/owned');
    fake.thumbnail.mockClear();
    await vi.advanceTimersByTimeAsync(2500);
    expect(fake.thumbnail.mock.calls.map(([path, edge, embedded]) => [path, edge, embedded])).toEqual([
      ['/owned/next.ARW', 2048, true], ['/owned/last.NEF', 2048, true],
    ]);
    expect(fake.open.mock.calls.map(([path]) => path)).toEqual(['/owned/first.jpg']);
    expect(session.importPreviews.getSnapshot()).toMatchObject({ total: 2, completed: 2, failed: 0 });
  });

  it('does not prebuild by falling back to a legacy host RAW decode', async () => {
    ready(false);
    await session.openFolder('/owned');
    fake.thumbnail.mockClear();
    await vi.advanceTimersByTimeAsync(2500);
    expect(fake.thumbnail).not.toHaveBeenCalled();
    expect(session.importPreviews.getSnapshot().total).toBe(0);
    expect(fake.open.mock.calls.map(([path]) => path)).toEqual(['/owned/first.jpg']);
  });

  it('reuses camera previews already on disk without extracting them again', async () => {
    fake.read.mockImplementation(async (key: string) => cameraKey(key).embeddedCameraPreview ? image('cached-camera') : null);
    await session.openFolder('/owned');
    fake.thumbnail.mockClear();
    await vi.advanceTimersByTimeAsync(2500);
    expect(fake.thumbnail).not.toHaveBeenCalled();
    expect(session.importPreviews.getSnapshot()).toMatchObject({ completed: 2, failed: 0 });
  });

  it('shows a prebuilt camera preview while the selected RAW is still opening', async () => {
    let finish!: (reply: object) => void;
    fake.open.mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }));
    fake.read.mockImplementation(async (key: string) => cameraKey(key).embeddedCameraPreview ? image('cached-camera') : null);
    const opening = session.select('/owned/next.ARW');
    await vi.advanceTimersByTimeAsync(1);
    expect(session.sessionStore.getState().engineSession).toBeNull();
    expect(fake.frames.print).toBeNull();
    expect(fake.frames.original?.colorSpace).toBe('cached-camera');
    expect(fake.thumbnail).not.toHaveBeenCalled();
    expect(session.importPreviews.getSnapshot().foregroundBusy).toBe(true);
    finish({ session: 'selected', width: 6000, height: 4000, kind: 'raw', metadata: {} });
    await opening;
    expect(fake.frames.print?.colorSpace).toBe('srgb');
  });

  it('reads foreground camera pictures without retaining them behind a late full image', async () => {
    fake.read.mockImplementation(async (key: string) => cameraKey(key).embeddedCameraPreview ? image('cached-camera') : null);
    await session.select('/owned/next.ARW');
    const cameras = fake.read.mock.calls.filter(([key]) => cameraKey(key as string).embeddedCameraPreview);
    expect(cameras.length).toBeGreaterThan(0);
    expect(cameras.every(([, options]) => (options as { retain?: boolean } | undefined)?.retain === false)).toBe(true);
  });

  it('ends loading on RAW failure while retaining the camera preview, then clears the error on retry', async () => {
    fake.read.mockImplementation(async (key: string) => cameraKey(key).embeddedCameraPreview ? image('cached-camera') : null);
    fake.open.mockRejectedValueOnce(new Error('unsupported camera transform'));
    await session.select('/owned/next.ARW');
    expect(session.sessionStore.getState().developing).toBe(false);
    expect(session.sessionStore.getState().lastError).toContain('unsupported camera transform');
    expect(fake.frames.print).toBeNull();
    expect(fake.frames.original).not.toBeNull();
    await session.select('/owned/selected.jpg');
    expect(session.sessionStore.getState().lastError).toBeNull();
    expect(fake.frames.print).not.toBeNull();
  });

  it('warms neighbour full pictures before camera previews and retains only the full picture', async () => {
    const events: { operation: string; key: string; retain?: boolean }[] = [];
    fake.read.mockImplementation(async (key: string, options?: { retain?: boolean }) => {
      events.push({ operation: 'read', key, retain: options?.retain });
      const d = JSON.parse(key) as DisplayCacheDescriptor;
      if (d.sources[0] === '/owned/next.ARW' && d.kind === 'print') return image('neighbour-full');
      return cameraKey(key).embeddedCameraPreview ? image('cached-camera') : null;
    });
    fake.forget.mockImplementation((key: string) => { events.push({ operation: 'forget', key }); });
    await session.openFolder('/owned');
    events.length = 0;
    await vi.advanceTimersByTimeAsync(2500);
    const next = events.filter((event) => JSON.parse(event.key).sources[0] === '/owned/next.ARW');
    const full = next.findIndex((event) => event.operation === 'read' && JSON.parse(event.key).kind === 'print');
    const camera = next.findIndex((event) => event.operation === 'read' && cameraKey(event.key).embeddedCameraPreview);
    expect(full).toBeGreaterThanOrEqual(0);
    expect(camera).toBeGreaterThan(full);
    expect(next[camera]?.retain).toBe(false);
    expect(next.slice(0, full).some((event) => event.operation === 'forget' && cameraKey(event.key).embeddedCameraPreview)).toBe(true);
  });

  it('foreground selection aborts background publication and prevents the next queued thumbnail', async () => {
    let finish!: (reply: RgbaImage) => void;
    fake.thumbnail.mockImplementation(async (path: string) => {
      if (path === '/owned/next.ARW') return new Promise((resolve) => { finish = resolve; });
      return image();
    });
    await session.openFolder('/owned');
    await vi.advanceTimersByTimeAsync(2000);
    expect(session.importPreviews.getSnapshot().current?.path).toBe('/owned/next.ARW');
    fake.write.mockClear();
    await session.select('/owned/selected.jpg');
    expect(session.importPreviews.getSnapshot().foregroundBusy).toBe(true);
    finish(image('obsolete-background'));
    await vi.advanceTimersByTimeAsync(1);
    expect(fake.write.mock.calls.some(([, result]) => result.colorSpace === 'obsolete-background')).toBe(false);
    expect(fake.thumbnail.mock.calls.some(([path]) => path === '/owned/last.NEF')).toBe(false);
    expect(session.importPreviews.getSnapshot()).toMatchObject({ completed: 0, failed: 0, pending: 2 });
  });

  it('skips a missing embedded image and continues without an editor error or RAW fallback', async () => {
    fake.thumbnail.mockImplementation(async (path: string) => {
      if (path === '/owned/next.ARW') throw new Error('embedded preview unavailable');
      return image();
    });
    await session.openFolder('/owned');
    await vi.advanceTimersByTimeAsync(2500);
    expect(session.importPreviews.getSnapshot()).toMatchObject({ total: 2, completed: 1, failed: 1, pending: 0 });
    expect(session.sessionStore.getState().lastError).toBeNull();
    expect(fake.open.mock.calls.map(([path]) => path)).toEqual(['/owned/first.jpg']);
  });
});
