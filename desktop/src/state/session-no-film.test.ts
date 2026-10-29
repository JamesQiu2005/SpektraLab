import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { ALL_FEATURES } from '@shared/params';
import type { HelloResult } from '@shared/protocol';
import { decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import { StockCatalog } from '@shared/stocks';
import type * as SessionModule from './session';
import type * as FramesModule from './frames';
import type { DisplayCacheDescriptor } from './displayCache';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';

const fake = vi.hoisted(() => ({ render: vi.fn(), load: vi.fn(), save: vi.fn(), key: vi.fn(),
  thumbnail: vi.fn(), invalidate: vi.fn(), thumb: vi.fn(), legacy: vi.fn() }));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  renderView: fake.render, render: fake.legacy, setParams: async () => ({}), close: async () => {},
  renderSource: async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'srgb' }),
  thumbnail: async () => { throw new Error('No embedded fixture'); },
  open: async () => ({ session: 's2', width: 6000, height: 4000, kind: 'raw', metadata: {} }),
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarLoad: fake.load, sidecarSave: fake.save, setTitle: async () => {} }),
  baseName: (p: string) => p.split('/').pop()!, dirName: (p: string) => p.slice(0, p.lastIndexOf('/')) }));
vi.mock('./displayCache', () => ({ displayCacheKey: fake.key, readDisplayCache: async () => null,
  writeDisplayCache: async () => true, forgetDisplayMemoryCache: vi.fn(), peekDisplayCache: () => null }));
vi.mock('./frames', () => ({ frameImages: { print: null, original: null }, THUMB_EDGE: 320, makeThumbFromPrint: fake.thumb }));
vi.mock('./thumbs', () => ({ thumbs: { invalidate: fake.invalidate, setPrint: fake.thumbnail, setPaused: vi.fn() } }));
let session: typeof SessionModule, frames: typeof FramesModule;
const state = () => session.sessionStore.getState();
const hello = { methods: ['render_view', 'render_source'], view_options: ['no_film'] } as HelloResult;
const crop = { ...GEOMETRY_DEFAULT, crop: { x: .1, y: .2, width: .6, height: .5 }, quarterTurns: 1, flipH: true };
const picture = (mode: string) => ({ width: 6, height: 4, nativeSize: { width: 6000, height: 4000 },
  data: new Uint8Array(96), colorSpace: mode, tier: 'live', ms: 1 });
const settle = () => vi.advanceTimersByTimeAsync(1);

beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.resetAllMocks();
  vi.spyOn(performance, 'now').mockReturnValue(10000);
  fake.load.mockResolvedValue(null); fake.save.mockResolvedValue('');
  fake.key.mockImplementation(async (d: DisplayCacheDescriptor) => JSON.stringify(d));
  fake.thumb.mockResolvedValue('blob:fixture-thumbnail');
  fake.render.mockImplementation(async (_sid: string, tier: string, options: { no_film?: boolean }) => ({ ...picture(options.no_film ? 'bypass' : 'film'), tier }));
  session = await import('./session'); frames = await import('./frames');
  const sc = structuredClone(newSidecar()); sc.params.filmEdge.seeded = true;
  session.sessionStore.setState({ selection: '/owned/a.ARW', engineSession: 's1', hello,
    hostState: { phase: 'ready', hello }, gate: { ...ALL_FEATURES, noFilm: true },
    nativeSize: { width: 6000, height: 4000 }, frameKind: 'raw', catalog: new StockCatalog(stockData.stocks),
    sidecar: { ...sc, geometry: crop, adjustments: { ...sc.adjustments, exposure: .75 } } });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('per-frame film bypass', () => {
  it('preserves film settings and crop, routes post adjustments, and restores through undo/redo and save', async () => {
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: true }, dateBack: { ...p.dateBack, active: true } }));
    await settle();
    const before = structuredClone(state().sidecar), history = state().undo.length;
    session.toggleNoFilm(); await settle();
    expect(state().sidecar.noFilm).toBe(true);
    expect(state().sidecar.params).toEqual(before.params);
    expect(state().sidecar.geometry).toEqual(before.geometry);
    expect(state().undo).toHaveLength(history + 1);
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({ no_film: true,
      geometry: before.geometry, source_geometry: GEOMETRY_DEFAULT, adjustments: before.adjustments }));
    session.undo(); await settle();
    expect(state().sidecar.noFilm).toBe(false);
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({
      geometry: GEOMETRY_DEFAULT, source_geometry: before.geometry }));
    session.redo(); await settle(); await session.flushSave();
    expect(decodeSidecar(fake.save.mock.calls.at(-1)![1]).noFilm).toBe(true);
  });

  it('selecting the current stock re-enables simulation in a single undo step', async () => {
    session.toggleNoFilm(); await settle();
    const count = state().undo.length;
    session.selectFilmStock(state().sidecar.params.filmStock); await settle();
    expect(state().sidecar.noFilm).toBe(false);
    expect(state().undo).toHaveLength(count + 1);
    session.undo(); await settle();
    expect(state().sidecar.noFilm).toBe(true);
  });

  it('rejects enabling bypass for pairs and unsupported hosts and never falls back to a film render', async () => {
    session.sessionStore.setState({ pair: {} as SessionModule.SessionState['pair'] });
    session.toggleNoFilm(); expect(state().sidecar.noFilm).toBe(false);
    session.sessionStore.setState({ pair: null, gate: { ...state().gate, noFilm: false } });
    session.toggleNoFilm(); expect(state().sidecar.noFilm).toBe(false);
    session.sessionStore.setState({ sidecar: { ...state().sidecar, noFilm: true }, hello: { methods: [] } as unknown as HelloResult });
    await session.requestPrint();
    expect(fake.render).not.toHaveBeenCalled(); expect(fake.legacy).not.toHaveBeenCalled();
    expect(state().lastError).toMatch(/film simulation|胶片模拟/i);
    session.toggleNoFilm(); await settle();
    expect(state().sidecar.noFilm).toBe(false);
  });

  it('drops an old film response after toggling while the new bypass render is pending', async () => {
    let releaseFilm!: (image: ReturnType<typeof picture>) => void;
    let releaseBypass!: (image: ReturnType<typeof picture>) => void;
    fake.render.mockImplementationOnce(() => new Promise((r) => { releaseFilm = r; }))
      .mockImplementationOnce(() => new Promise((r) => { releaseBypass = r; }));
    const pending = session.requestPrint(); await settle();
    session.toggleNoFilm(); await settle();
    releaseFilm(picture('stale-film')); await settle();
    expect(frames.frameImages.print).toBeNull();
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({ no_film: true }));
    releaseBypass(picture('current-bypass')); await pending;
    expect(frames.frameImages.print?.colorSpace).toBe('current-bypass');
  });

  it('separates cache identities and makes a whole-photo bypass thumbnail without a baked crop', async () => {
    await session.requestPrint();
    session.toggleNoFilm(); await settle();
    const descriptors = fake.key.mock.calls.map(([d]) => d as DisplayCacheDescriptor).filter((d) => d.kind === 'print');
    expect(descriptors.some((d) => (d.configuration as { noFilm?: boolean }).noFilm === false)).toBe(true);
    expect(descriptors.some((d) => (d.configuration as { noFilm?: boolean }).noFilm === true)).toBe(true);
    await vi.advanceTimersByTimeAsync(450);
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'full', expect.objectContaining({ no_film: true,
      geometry: GEOMETRY_DEFAULT, source_geometry: GEOMETRY_DEFAULT, long_edge: 320 }));
    expect(fake.thumbnail).toHaveBeenLastCalledWith('/owned/a.ARW', 'blob:fixture-thumbnail', false);
  });

  it('restores saved bypass on reopen and external reload', async () => {
    const saved = { ...state().sidecar, noFilm: true };
    fake.load.mockResolvedValue(encodeSidecar(saved));
    await session.select('/owned/b.ARW');
    expect(state().sidecar.noFilm).toBe(true);
    expect(fake.render).toHaveBeenLastCalledWith('s2', 'live', expect.objectContaining({ no_film: true, geometry: crop }));
    fake.load.mockResolvedValue(encodeSidecar({ ...state().sidecar, noFilm: false }));
    await session.flushSave();
    await session.select('/owned/b.ARW', { externalReload: true });
    expect(state().sidecar.noFilm).toBe(false);
    expect(frames.frameImages.print?.colorSpace).toBe('film');
  });
});
