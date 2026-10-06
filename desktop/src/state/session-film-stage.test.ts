// These exercise the session doors and their wire/persistence output, not
// just the picker styling: a disabled paper row once hid scan_film=false.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult, HostState } from '@shared/protocol';
import type * as StocksModule from '@shared/stocks';
import type * as SessionModule from './session';
import { StockCatalog } from '@shared/stocks';
import { decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';

const fake = vi.hoisted(() => ({
  onState: null as ((state: HostState) => void) | null,
  loadCatalog: vi.fn(),
  load: vi.fn(),
  save: vi.fn(async (_path: string, _sidecar: unknown) => ''),
  open: vi.fn(async () => ({ session: 's1', width: 6, height: 4, kind: 'raw', metadata: { orientation: 1 } })),
  setParams: vi.fn(async () => ({})),
  render: vi.fn(async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'sRGB', tier: 'preview', reprinted: false, ms: 1 })),
}));
vi.mock('@shared/stocks', async (original) => ({ ...(await original<typeof StocksModule>()), loadCatalog: fake.loadCatalog }));
vi.mock('../host/client', () => ({
  HostCallError: class extends Error {},
  host: () => ({
    setParams: fake.setParams,
    render: fake.render,
    open: fake.open,
    close: async () => {},
    thumbnail: async () => { throw new Error('No fixture thumbnail'); },
    onState: (cb: (state: HostState) => void) => { fake.onState = cb; },
    state: async () => ({ phase: 'ready', hello: {} }),
  }),
}));
vi.mock('../platform', () => ({
  platform: () => ({
    log: () => {}, sidecarLoad: fake.load, sidecarSave: fake.save,
    onOpenPaths: () => {}, onDrop: () => {}, takeLaunchPaths: async () => [],
  }),
  baseName: (p: string) => p.split(/[\\/]/).pop() ?? p,
  dirName: (p: string) => p,
}));

const SLIDES = ['fujifilm_provia_100f', 'fujifilm_velvia_100', 'kodak_ektachrome_100', 'kodak_kodachrome_64'];
const catalog = new StockCatalog(SLIDES.map((id) => ({ id, name: id, stage: 'filming', use: 'still', type: 'positive', hasPreviewLUT: false })));
const ready = { phase: 'ready', hello: {} as HelloResult } as const;
const slideSidecar = () => ({ ...newSidecar(), params: { ...newSidecar().params, filmStock: SLIDES[0]!, scanFilm: false }, state: 'processed' as const });
let session: typeof SessionModule;

beforeEach(async () => {
  vi.useFakeTimers();
  vi.spyOn(performance, 'now').mockReturnValue(10_000);
  vi.clearAllMocks();
  vi.resetModules();
  vi.stubGlobal('window', { addEventListener: vi.fn() });
  fake.onState = null;
  fake.load.mockResolvedValue(null);
  fake.loadCatalog.mockResolvedValue(catalog);
  session = await import('./session');
  session.sessionStore.setState({
    catalog, hostState: ready, selection: '/owned/a.ARW', picked: ['/owned/a.ARW'], engineSession: 's1',
    nativeSize: { width: 6, height: 4 }, sidecar: newSidecar(), undo: [], redo: [],
  });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('positive film uses direct scanning at every session door', () => {
  it.each(SLIDES)('selecting %s retains the paper and sends scan_film=true', async (filmStock) => {
    const printStock = session.sessionStore.getState().sidecar.params.printStock;
    // The film picker's real callback enters here.
    session.setParams((p) => ({ ...p, filmStock }));
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ filmStock, printStock, scanFilm: true });
    expect(fake.setParams).toHaveBeenCalledWith('s1', expect.objectContaining({ film_stock: filmStock, scan_film: true }));
    await session.flushSave();
    expect(decodeSidecar(fake.save.mock.calls.at(-1)?.[1]).params).toMatchObject({ filmStock, printStock, scanFilm: true });
  });

  it('selecting a slide and enabling direct scanning form one undo step', () => {
    const original = session.sessionStore.getState().sidecar.params;
    session.setParams((p) => ({ ...p, filmStock: SLIDES[0]! }));
    expect(session.sessionStore.getState().undo).toHaveLength(1);
    session.undo();
    expect(session.sessionStore.getState().sidecar.params).toEqual(original);
    session.redo();
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ filmStock: SLIDES[0], scanFilm: true, printStock: original.printStock });
  });

  it('normalizes a restored legacy undo entry too', () => {
    session.sessionStore.setState({ undo: [slideSidecar()] });
    session.undo();
    expect(session.sessionStore.getState().sidecar.params.scanFilm).toBe(true);
  });

  it('preserves intentional direct scanning for negatives, including after leaving a slide', () => {
    session.setParams((p) => ({ ...p, scanFilm: true }));
    session.setParams((p) => ({ ...p, filmStock: SLIDES[0]! }));
    session.setParams((p) => ({ ...p, filmStock: 'kodak_portra_400' }));
    session.setParams((p) => ({ ...p, exposureCompensationEV: 1 }));
    expect(session.sessionStore.getState().sidecar.params.scanFilm).toBe(true);
    session.setParams((p) => ({ ...p, scanFilm: false }));
    expect(session.sessionStore.getState().sidecar.params.scanFilm).toBe(false);
  });

  it('repairs a saved slide before its first open and persists the repair', async () => {
    fake.load.mockResolvedValue(encodeSidecar(slideSidecar()));
    await session.select('/owned/old-slide.ARW');
    expect(fake.open).toHaveBeenCalledWith('/owned/old-slide.ARW', expect.objectContaining({ scan_film: true }), expect.anything());
    expect(session.sessionStore.getState().undo).toHaveLength(0);
    await session.flushSave();
    expect(decodeSidecar(fake.save.mock.calls.at(-1)?.[1]).params.scanFilm).toBe(true);
  });

  it('repairs pasted film settings for the active frame and offline frames', async () => {
    session.sessionStore.setState({
      clipboard: { groups: ['filmAndPaper'], settings: slideSidecar(), sourceName: 'legacy' },
      picked: ['/owned/a.ARW', '/owned/b.ARW'],
    });
    await session.pasteSettings();
    expect(session.sessionStore.getState().sidecar.params.scanFilm).toBe(true);
    const offline = fake.save.mock.calls.find(([path]) => path === '/owned/b.ARW');
    expect(decodeSidecar(offline?.[1]).params.scanFilm).toBe(true);
  });

  it('repairs invalid offline settings on sync even if the clip itself is unchanged', async () => {
    const sc = slideSidecar();
    session.sessionStore.setState({ sidecar: sc, picked: ['/owned/a.ARW', '/owned/b.ARW'] });
    fake.load.mockResolvedValue(encodeSidecar(sc));
    await session.syncSettings();
    expect(fake.save).toHaveBeenCalledWith('/owned/b.ARW', expect.objectContaining({ params: expect.objectContaining({ scanFilm: true }) }));
  });

  it('waits for the catalog before opening restored settings on startup', async () => {
    let resolveCatalog!: (value: StockCatalog) => void;
    fake.loadCatalog.mockReturnValue(new Promise<StockCatalog>((resolve) => { resolveCatalog = resolve; }));
    session.sessionStore.setState({ catalog: new StockCatalog([]), hostState: { phase: 'starting' }, engineSession: null, sidecar: slideSidecar() });
    const boot = session.boot();
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.open).not.toHaveBeenCalled();
    resolveCatalog(catalog);
    await boot;
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.open).toHaveBeenCalledWith('/owned/a.ARW', expect.objectContaining({ scan_film: true }), expect.anything());
  });

  it('normalizes restored settings before reopening after a host restart', async () => {
    await session.boot();
    await vi.advanceTimersByTimeAsync(0);
    fake.open.mockClear();
    session.sessionStore.setState({ sidecar: slideSidecar() });
    fake.onState?.({ phase: 'restarting', reason: 'test restart', attempt: 1 });
    fake.onState?.({ phase: 'ready', hello: {} as HelloResult });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.open).toHaveBeenCalledWith('/owned/a.ARW', expect.objectContaining({ scan_film: true }), expect.anything());
  });
});
