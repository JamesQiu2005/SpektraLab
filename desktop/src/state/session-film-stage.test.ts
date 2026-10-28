// These exercise the session doors and their wire/persistence output, not
// just the picker styling: a disabled paper row once hid scan_film=false.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult, HostState } from '@shared/protocol';
import type * as StocksModule from '@shared/stocks';
import type * as SessionModule from './session';
import { StockCatalog } from '@shared/stocks';
import { decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import type { FileEntry } from '../platform';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';

const fake = vi.hoisted(() => ({
  onState: null as ((state: HostState) => void) | null,
  loadCatalog: vi.fn(),
  state: vi.fn(),
  listImages: vi.fn<(dir: string) => Promise<FileEntry[]>>(),
  expandPaths: vi.fn<(paths: string[]) => Promise<FileEntry[]>>(),
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
    state: fake.state,
  }),
}));
vi.mock('../platform', () => ({
  platform: () => ({
    log: () => {}, sidecarLoad: fake.load, sidecarSave: fake.save,
    listImages: fake.listImages, expandPaths: fake.expandPaths, setTitle: async () => {},
    onOpenPaths: () => {}, onDrop: () => {}, takeLaunchPaths: async () => [],
  }),
  baseName: (p: string) => p.split(/[\\/]/).pop() ?? p,
  dirName: (p: string) => p.replace(/[\\/][^\\/]*$/, ''),
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
  fake.state.mockResolvedValue(ready);
  fake.load.mockResolvedValue(null);
  fake.loadCatalog.mockResolvedValue(catalog);
  session = await import('./session');
  session.sessionStore.setState({
    catalog, hostState: ready, selection: '/owned/a.ARW', picked: ['/owned/a.ARW'], engineSession: 's1',
    nativeSize: { width: 6, height: 4 }, sidecar: newSidecar(), undo: [], redo: [],
  });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('black-and-white settings through the editor and persistence doors', () => {
  const released = new StockCatalog(stockData.stocks);
  const silverPaper = 'ilford_multigrade_iv_rc';
  const stocks = ['kodak_tri_x_400', 'ilford_hp5_plus_400', 'kodak_tmax_100', 'fujifilm_neopan_acros_100_ii'];
  const invalidSilver = () => ({ ...newSidecar(), params: { ...newSidecar().params, filmStock: stocks[0]!, extendedDynamicRange: true } });
  beforeEach(() => { session.sessionStore.setState({ catalog: released }); });

  it.each(stocks)('choosing %s selects silver paper and preserves saved model preferences', async (filmStock) => {
    const initial = structuredClone(newSidecar());
    initial.params.extendedDynamicRange = true;
    initial.params.exposureCompensationEV = 1.25;
    session.sessionStore.setState({ sidecar: initial });
    session.selectFilmStock(filmStock);
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ filmStock, printStock: silverPaper,
      scanFilm: false, extendedDynamicRange: true, effects: { grainLayered: true }, exposureCompensationEV: 1.25 });
    expect(fake.setParams).toHaveBeenCalledWith('s1', expect.objectContaining({ film_stock: filmStock,
      print_stock: silverPaper, grain_sublayers_active: false, extended_dynamic_range: false, y_filter_neutral: 68 }));
    await session.flushSave();
    expect(decodeSidecar(fake.save.mock.calls.at(-1)?.[1]).params).toMatchObject({ printStock: silverPaper, extendedDynamicRange: true });
  });

  it('blocks incompatible paper actions and returns to a declared colour paper in one undo step', async () => {
    session.selectFilmStock('kodak_tri_x_400');
    await vi.advanceTimersByTimeAsync(1000);
    const silver = session.sessionStore.getState().sidecar;
    const undoCount = session.sessionStore.getState().undo.length;
    fake.setParams.mockClear();
    session.selectPrintStock('kodak_supra_endura');
    expect(session.sessionStore.getState().sidecar).toBe(silver);
    expect(session.sessionStore.getState().undo).toHaveLength(undoCount);
    expect(fake.setParams).not.toHaveBeenCalled();
    session.selectFilmStock('kodak_portra_400');
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ printStock: 'kodak_portra_endura', scanFilm: false });
    await vi.advanceTimersByTimeAsync(1000);
    expect(fake.setParams).toHaveBeenCalledWith('s1', expect.objectContaining({ grain_sublayers_active: true, grain_amount: 1 }));
    session.undo();
    expect(session.sessionStore.getState().sidecar.params).toEqual(silver.params);
    session.redo();
    expect(session.sessionStore.getState().sidecar.params.printStock).toBe('kodak_portra_endura');
  });

  it('repairs a restored silver-film/colour-paper pair before opening the engine', async () => {
    fake.load.mockResolvedValue(encodeSidecar(invalidSilver()));
    await session.select('/owned/silver.ARW');
    expect(fake.open).toHaveBeenCalledWith('/owned/silver.ARW', expect.objectContaining({ film_stock: 'kodak_tri_x_400',
      print_stock: silverPaper, y_filter_neutral: 68, extended_dynamic_range: false }), expect.anything());
    expect(session.sessionStore.getState().undo).toHaveLength(0);
    await session.flushSave();
    expect(decodeSidecar(fake.save.mock.calls.at(-1)?.[1]).params).toMatchObject({ printStock: silverPaper, extendedDynamicRange: true });
  });

  it('normalizes both active and offline clipboard targets without copying solved colour values', async () => {
    session.sessionStore.setState({ clipboard: { groups: ['filmAndPaper'], settings: invalidSilver(), sourceName: 'silver' },
      picked: ['/owned/a.ARW', '/owned/b.ARW'] });
    await session.pasteSettings();
    expect(session.sessionStore.getState().sidecar.params.printStock).toBe(silverPaper);
    const saved = fake.save.mock.calls.find(([path]) => path === '/owned/b.ARW');
    expect(decodeSidecar(saved?.[1]).params).toMatchObject({ printStock: silverPaper, extendedDynamicRange: true });
  });
});

describe('positive film uses direct scanning at every session door', () => {
  it('reorders filmstrip entries without moving the open frame or editing its parameters', () => {
    const names = ['/owned/a.ARW', '/owned/b.ARW', '/owned/c.ARW'];
    const frames = names.map((path) => ({ path, name: path, size: 1, mtime_ms: 1 }));
    session.sessionStore.setState({ frames, picked: names.slice(0, 2) });
    const before = session.sessionStore.getState();
    session.moveFrame(names[0]!, names[2]!);
    expect(session.sessionStore.getState().frames.map((f) => f.path)).toEqual([names[1], names[2], names[0]]);
    expect(session.sessionStore.getState()).toMatchObject({ selection: before.selection, picked: before.picked, engineSession: 's1' });
    expect(session.sessionStore.getState().sidecar).toBe(before.sidecar);
    session.sessionStore.setState({ batchExporting: true });
    session.moveFrame(names[0]!, names[1]!);
    expect(session.sessionStore.getState().frames.at(-1)?.path).toBe(names[0]);
  });
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

  it.each(SLIDES)('returning from %s to Ektar follows its declared paper, with the earlier pairing restored by undo', async (filmStock) => {
    const released = new StockCatalog(stockData.stocks);
    const before = session.sessionStore.getState().sidecar;
    session.sessionStore.setState({ catalog: released, sidecar: { ...before, params: { ...before.params, printStock: 'kodak_supra_endura' } } });
    const printStock = released.stock('kodak_ektar_100')!.targetPrint;
    expect(printStock).toBe('kodak_portra_endura');
    session.selectFilmStock(filmStock);
    expect(session.sessionStore.getState().sidecar.params.printStock).toBe('kodak_supra_endura');
    await vi.advanceTimersByTimeAsync(1000);
    fake.setParams.mockClear();
    session.selectFilmStock('kodak_ektar_100');
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ filmStock: 'kodak_ektar_100', scanFilm: false, printStock });
    await vi.advanceTimersByTimeAsync(1000);
    expect(fake.setParams).toHaveBeenCalledWith('s1', expect.objectContaining({ film_stock: 'kodak_ektar_100', scan_film: false }));
    await session.flushSave();
    expect(decodeSidecar(fake.save.mock.calls.at(-1)?.[1]).params.scanFilm).toBe(false);
    session.undo();
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ filmStock, scanFilm: true, printStock: 'kodak_supra_endura' });
    session.redo();
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ scanFilm: false, printStock });
  });

  it('reselecting a saved negative restores printing without resetting other edits', () => {
    session.sessionStore.setState({ sidecar: { ...newSidecar(), params: { ...newSidecar().params, filmStock: 'kodak_ektar_100', scanFilm: true, exposureCompensationEV: 1.5 } } });
    session.selectFilmStock('kodak_ektar_100');
    expect(session.sessionStore.getState().sidecar.params).toMatchObject({ scanFilm: false, exposureCompensationEV: 1.5 });
    session.setParams((p) => ({ ...p, scanFilm: true }));
    session.setParams((p) => ({ ...p, exposureCompensationEV: 2 }));
    expect(session.sessionStore.getState().sidecar.params.scanFilm).toBe(true);
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


describe('startup state ordering', () => {
  it('does not let an older starting snapshot overwrite the ready event', async () => {
    let resolveState!: (state: HostState) => void;
    fake.state.mockReturnValue(new Promise<HostState>((resolve) => { resolveState = resolve; }));
    session.sessionStore.setState({ hostState: { phase: 'starting' }, engineSession: null });
    const pending = session.boot();
    await vi.advanceTimersByTimeAsync(0);
    fake.onState?.(ready);
    resolveState({ phase: 'starting' });
    await pending;
    expect(session.sessionStore.getState().hostState.phase).toBe('ready');
  });

  it('shows a startup IPC failure instead of waiting forever', async () => {
    fake.state.mockRejectedValue(new Error('IPC unavailable'));
    session.sessionStore.setState({ hostState: { phase: 'starting' }, engineSession: null });
    await session.boot();
    expect(session.sessionStore.getState().hostState).toMatchObject({ phase: 'failed', reason: expect.stringContaining('IPC unavailable') });
  });
});


describe('feedback: reset the full capture setup', () => {
  it('resets stocks, effects and camera decode together, preserves crop/grade and undoes once', () => {
    const before = newSidecar();
    before.params = { ...before.params, filmStock: 'kodak_ektar_100', printStock: 'kodak_supra_endura', grainActive: false, exposureCompensationEV: 2, printBrightnessStops: 1 };
    before.decode = { ...before.decode, whiteBalance: 'Custom', temperature: 3200 };
    before.adjustments = { ...before.adjustments, exposure: 0.5 };
    before.geometry = { ...before.geometry, quarterTurns: 1 };
    session.sessionStore.setState({ sidecar: before });
    session.resetParams();
    const after = session.sessionStore.getState();
    expect(after.sidecar.params).toEqual(newSidecar().params);
    expect(after.sidecar.decode).toEqual(newSidecar().decode);
    expect(after.sidecar.adjustments).toEqual(before.adjustments);
    expect(after.sidecar.geometry).toEqual(before.geometry);
    expect(after.undo).toHaveLength(1);
    session.undo();
    expect(session.sessionStore.getState().sidecar.params).toEqual(before.params);
    expect(session.sessionStore.getState().sidecar.decode).toEqual(before.decode);
  });
});

describe('explicit import scope', () => {
  const entry = (path: string): FileEntry => ({ path, name: path.split('/').pop()!, size: 1, mtime_ms: 0 });
  const one = entry('/owned/new.ARW');
  const old = [entry('/owned/old-roll/a.NEF'), entry('/owned/old-roll/b.NEF')];

  beforeEach(() => {
    session.sessionStore.setState({ selection: null, engineSession: null, frames: [], picked: [] });
    fake.listImages.mockResolvedValue([one, ...old]);
    fake.expandPaths.mockImplementation(async (paths) => paths.map(entry));
  });

  it('stays empty after restart, then opens only the requested file despite a saved folder', async () => {
    const { settingsStore } = await import('./settings');
    settingsStore.getState().set('lastFolder', '/owned/old-roll');
    await session.boot();
    expect(session.sessionStore.getState().frames).toEqual([]);
    await session.openPaths([one.path]);
    expect(session.sessionStore.getState().frames).toEqual([one]);
    expect(session.sessionStore.getState().selection).toBe(one.path);
    expect(fake.listImages).not.toHaveBeenCalled();
  });

  it('replaces an existing roll with explicitly selected files, even if they were already in it', async () => {
    session.sessionStore.setState({ frames: [one, ...old] });
    await session.openPaths([one.path, old[0]!.path]);
    expect(session.sessionStore.getState().frames).toEqual([one, old[0]]);
    expect(fake.listImages).not.toHaveBeenCalled();
  });

  it('still imports folder contents through both folder and dropped-path doors', async () => {
    fake.listImages.mockResolvedValue(old);
    await session.openFolder('/owned/old-roll');
    expect(session.sessionStore.getState().frames).toEqual(old);
    fake.expandPaths.mockResolvedValue([one, ...old]);
    await session.openPaths(['/owned']);
    expect(session.sessionStore.getState().frames).toEqual([one, ...old]);
  });

  it('does not change the library during batch export or for empty/unsupported input', async () => {
    session.sessionStore.setState({ frames: old, batchExporting: true });
    await session.openPaths([one.path]);
    expect(fake.expandPaths).not.toHaveBeenCalled();
    session.sessionStore.setState({ batchExporting: false });
    await session.openPaths([]);
    fake.expandPaths.mockResolvedValue([]);
    await session.openPaths(['/owned/readme.txt']);
    expect(session.sessionStore.getState().frames).toEqual(old);
  });
});
