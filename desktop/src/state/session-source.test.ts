import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { newSidecar } from '@shared/sidecar';
import type { HelloResult } from '@shared/protocol';
import type { RgbaImage } from '../host/client';
import type * as SessionModule from './session';
import type * as FramesModule from './frames';
const image = (colorSpace = 'sRGB'): RgbaImage => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace });
const fake = vi.hoisted(() => ({ source: vi.fn(), pick: vi.fn(), redecode: vi.fn(),
  render: vi.fn(async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'sRGB', ms: 1, tier: 'preview' })),
  save: vi.fn(async () => ''), thumbnail: vi.fn(),
}));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  renderSource: fake.source, pickNeutral: fake.pick, redecode: fake.redecode, render: fake.render,
  setParams: async () => ({}), close: async () => {}, thumbnail: fake.thumbnail,
  open: async () => ({ session: 's2', width: 6, height: 4, kind: 'raw' }),
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarLoad: async () => null,
  sidecarSave: fake.save, setTitle: async () => {} }),
  baseName: (p: string) => p.split('/').pop()!, dirName: (p: string) => p.slice(0, p.lastIndexOf('/')) }));
let session: typeof SessionModule;
let frames: typeof FramesModule;
const state = () => session.sessionStore.getState();
const hello = { methods: ['render_source', 'pick_neutral', 'redecode'] } as HelloResult;
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  vi.spyOn(performance, 'now').mockReturnValue(10_000);
  fake.source.mockImplementation(async (_sid, opts) => image(opts.display === 'display-p3' ? 'Display P3' : 'sRGB'));
  fake.pick.mockResolvedValue({ temperature_k: 6300, tint: 12 });
  fake.redecode.mockResolvedValue({ width: 6, height: 4 });
  fake.thumbnail.mockResolvedValue(image());
  session = await import('./session'); frames = await import('./frames');
  session.sessionStore.setState({ selection: '/owned/a.ARW', picked: ['/owned/a.ARW'], engineSession: 's1', hello,
    hostState: { phase: 'ready', hello }, nativeSize: { width: 6000, height: 4000 },
    frameKind: 'raw', sidecar: structuredClone(newSidecar()) });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('decoded source preview', () => {
  it('bounds source readback, refreshes P3 and 100% detail, and does not transfer again for pan', async () => {
    await session.refreshOriginal();
    expect(fake.source).toHaveBeenCalledWith('s1', expect.objectContaining({ long_edge: 2560, display: 'srgb' }));
    session.setView({ cx: .2 }); await vi.advanceTimersByTimeAsync(1);
    expect(fake.source).toHaveBeenCalledTimes(1);
    session.noteDisplaySpace('display-p3'); await vi.advanceTimersByTimeAsync(1);
    expect(frames.frameImages.original?.colorSpace).toBe('Display P3');
    session.setView({ fit: false, zoom: 1 }); await vi.advanceTimersByTimeAsync(1);
    expect(fake.source).toHaveBeenLastCalledWith('s1', expect.objectContaining({ long_edge: 0, display: 'display-p3' }));
  });

  it('coalesces changes and rejects the old decoded source after a photo switch', async () => {
    let finish!: (im: RgbaImage) => void;
    fake.source.mockImplementationOnce(() => new Promise<RgbaImage>((r) => { finish = r; }));
    const pending = session.refreshOriginal();
    await vi.advanceTimersByTimeAsync(1); // source-identity/cache-key capture precedes the native request
    session.sessionStore.setState({ selection: '/owned/b.ARW', engineSession: 's2' });
    void session.refreshOriginal(); void session.refreshOriginal();
    expect(fake.source).toHaveBeenCalledTimes(1);
    finish(image('stale')); await pending;
    expect(fake.source).toHaveBeenCalledTimes(2);
    expect(frames.frameImages.original?.colorSpace).toBe('sRGB');
  });

  it('refreshes source after WB re-decode, and a late embedded image cannot replace it', async () => {
    let finish!: (im: RgbaImage) => void;
    fake.thumbnail.mockImplementationOnce(() => new Promise<RgbaImage>((r) => { finish = r; }));
    await session.select('/owned/b.ARW');
    await vi.advanceTimersByTimeAsync(1);
    const decoded = frames.frameImages.original;
    finish(image('embedded')); await vi.advanceTimersByTimeAsync(1);
    expect(frames.frameImages.original).toBe(decoded);
    fake.source.mockClear();
    session.setDecode((d) => ({ ...d, whiteBalance: 'Custom', temperature: 6000 }));
    await vi.advanceTimersByTimeAsync(351);
    expect(fake.redecode).toHaveBeenCalledWith('s2', expect.objectContaining({ white_balance: { mode: 'custom', temperature_k: 6000, tint: 0 } }));
    expect(fake.source).toHaveBeenCalledTimes(1);
  });
});

describe('neutral RAW white balance', () => {
  it('uses normalized source coordinates, records one undo and restores the previous preview mode', async () => {
    session.startNeutralPick();
    expect(state()).toMatchObject({ tool: 'neutral', showingOriginal: true });
    await session.pickNeutralAt(.25, .75);
    expect(fake.pick).toHaveBeenCalledWith('s1', .25, .75);
    expect(state()).toMatchObject({ tool: 'select', showingOriginal: false,
      sidecar: { decode: { whiteBalance: 'Custom', temperature: 6300, tint: 12 } } });
    expect(state().undo).toHaveLength(1);
  });

  it('ignores cancelled or superseded picks and refuses non-RAW/unsupported sessions', async () => {
    let finish!: (wb: { temperature_k: number; tint: number }) => void;
    fake.pick.mockImplementationOnce(() => new Promise((r) => { finish = r; }));
    session.startNeutralPick(); const pending = session.pickNeutralAt(.5, .5);
    session.setTool('select'); finish({ temperature_k: 8000, tint: 0 }); await pending;
    expect(state().sidecar.decode.whiteBalance).toBe('As Shot');
    session.sessionStore.setState({ frameKind: 'tiff' }); session.startNeutralPick();
    expect(state().tool).toBe('select');
    session.sessionStore.setState({ frameKind: 'raw', hello: { methods: ['redecode'] } as HelloResult });
    expect(session.canPickNeutral()).toBe(false);
  });

  it('keeps a failed sample retryable without changing white balance', async () => {
    fake.pick.mockRejectedValueOnce(new Error('The sample is clipped'));
    session.startNeutralPick(); await session.pickNeutralAt(.5, .5);
    expect(state().tool).toBe('neutral');
    expect(state().lastError).toContain('clipped');
    expect(state().sidecar.decode.whiteBalance).toBe('As Shot');
    await session.pickNeutralAt(.2, .3);
    expect(state().sidecar.decode.whiteBalance).toBe('Custom');
  });
});
