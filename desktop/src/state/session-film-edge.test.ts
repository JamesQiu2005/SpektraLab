import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult } from '@shared/protocol';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { newSidecar, decodeSidecar, encodeSidecar } from '@shared/sidecar';
import { StockCatalog } from '@shared/stocks';
import { FILM_FRAME_CUSTOM } from '@shared/params';
import type * as SessionModule from './session';
import stockData from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';
const fake = vi.hoisted(() => ({ load: vi.fn(), save: vi.fn(async (_path: string, _sidecar: unknown) => ''), params: vi.fn(async () => ({})),
  render: vi.fn(async () => ({ width: 600, height: 420, nativeSize: { width: 6100, height: 4200 }, data: new Uint8Array(0), colorSpace: 'sRGB', ms: 1, tier: 'preview' })),
  source: vi.fn(async () => ({ width: 600, height: 400, data: new Uint8Array(0), colorSpace: 'sRGB' })),
}));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  renderView: fake.render, renderSource: fake.source, setParams: fake.params, close: async () => {},
  thumbnail: async () => { throw new Error('No fixture thumbnail'); },
  open: async () => ({ session: 's2', width: 6000, height: 4000, kind: 'raw', metadata: { datetime_original: '2026-10-01T00:00:00', aperture: 2.8 } }),
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarLoad: fake.load, sidecarSave: fake.save, setTitle: async () => {} }),
  baseName: (p: string) => p.split('/').pop()!, dirName: (p: string) => p.slice(0, p.lastIndexOf('/')) }));
let session: typeof SessionModule;
const state = () => session.sessionStore.getState();
const crop = { ...GEOMETRY_DEFAULT, crop: { x: .2, y: .1, width: .5, height: .7 }, angle: 4 };
const hello = { methods: ['render_view', 'render_source', 'pick_neutral', 'redecode'] } as HelloResult;
let clock = 10000;
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  clock = 10000; vi.spyOn(performance, 'now').mockImplementation(() => clock);
  fake.load.mockResolvedValue(null);
  session = await import('./session');
  session.sessionStore.setState({ selection: '/owned/a.ARW', picked: ['/owned/a.ARW'], engineSession: 's1', hello,
    hostState: { phase: 'ready', hello }, nativeSize: { width: 6000, height: 4000 }, frameKind: 'raw',
    catalog: new StockCatalog(stockData.stocks), sidecar: { ...structuredClone(newSidecar()), geometry: crop },
    metadata: { datetime_original: '2026-10-01T00:00:00', aperture: 2.8 } });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });
const settle = () => vi.advanceTimersByTimeAsync(1);

describe('film edge and date back session', () => {
  it('retains the user film format while the edge owns it, including rejected edits and undo', async () => {
    session.setFilmFrame(FILM_FRAME_CUSTOM.id);
    session.setFilmSide('long');
    session.setSideLengthMM(52);
    await settle();
    const original = structuredClone(state().sidecar.params);
    clock += 1000;
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: true, format: '135_half' } }));
    await settle();
    const history = state().undo.length;
    fake.params.mockClear();
    session.setFilmFrame('135');
    session.setFilmSide('short');
    session.setSideLengthMM(90);
    await settle();
    for (const key of ['filmFrame', 'filmSide', 'sideLengthMM', 'filmFormatMM'] as const)
      expect(state().sidecar.params[key]).toEqual(original[key]);
    expect(state().undo).toHaveLength(history);
    expect(fake.params).not.toHaveBeenCalled();
    clock += 1000;
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: false } }));
    await settle();
    expect(state().sidecar.params).toMatchObject({ filmFrame: FILM_FRAME_CUSTOM.id, filmSide: 'long', sideLengthMM: 52 });
    session.undo(); await settle();
    expect(state().sidecar.params.filmEdge.active).toBe(true);
    session.redo(); await settle();
    expect(state().sidecar.params).toMatchObject({ filmFrame: FILM_FRAME_CUSTOM.id, filmSide: 'long', sideLengthMM: 52 });
  });
  it('only edits a custom side length, and an unsupported edge does not lock the format', async () => {
    session.setFilmFrame('135'); await settle();
    const before = structuredClone(state().sidecar.params);
    const history = state().undo.length;
    session.setSideLengthMM(90); await settle();
    expect(state().sidecar.params).toEqual(before);
    expect(state().undo).toHaveLength(history);
    session.sessionStore.setState({ gate: { ...state().gate, overscan: false } });
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: true } })); await settle();
    session.setFilmFrame(FILM_FRAME_CUSTOM.id);
    session.setSideLengthMM(60); await settle();
    expect(state().sidecar.params).toMatchObject({ filmFrame: FILM_FRAME_CUSTOM.id, sideLengthMM: 60 });
  });
  it('takes and restores the held crop, with one undo entry and a native source cut', async () => {
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: true, format: '135_half' } }));
    await settle();
    const held = state().sidecar;
    expect(held.heldCrop).toEqual(crop);
    expect(held.geometry.lockedRatio).toBe(4 / 3);
    expect(state().undo).toHaveLength(1);
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({ geometry: GEOMETRY_DEFAULT, source_geometry: held.geometry }));
    expect(fake.params).toHaveBeenCalledWith('s1', expect.objectContaining({ overscan_active: true, overscan_f_number: 2.8 }));
    clock += 1000;
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: false } })); await settle();
    expect(state().sidecar).toMatchObject({ geometry: crop, heldCrop: null });
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({ geometry: crop, source_geometry: GEOMETRY_DEFAULT }));
    session.undo(); await settle();
    expect(state().sidecar).toMatchObject({ geometry: held.geometry, heldCrop: crop });
    session.redo(); await settle();
    expect(state().sidecar).toMatchObject({ geometry: crop, heldCrop: null });
  });
  it('frames on the original without repeatedly developing film, then commits one source cut', async () => {
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: true } })); await settle();
    fake.render.mockClear();
    session.setTool('crop'); await settle();
    session.setGeometry((g) => ({ ...g, crop: { ...g.crop, x: g.crop.x + .01 } }), { coalesce: true });
    session.setGeometry((g) => ({ ...g, crop: { ...g.crop, x: g.crop.x + .01 } }), { coalesce: true });
    await settle();
    expect(fake.render).not.toHaveBeenCalled();
    expect(fake.source).toHaveBeenCalled();
    session.setTool('select'); await settle();
    expect(fake.render).toHaveBeenCalledTimes(1);
    expect(fake.render).toHaveBeenCalledWith('s1', 'live', expect.objectContaining({ source_geometry: state().sidecar.geometry, geometry: GEOMETRY_DEFAULT }));
    session.setOriginal(true); session.toggleCompare(); session.startNeutralPick();
    expect(state()).toMatchObject({ tool: 'select', showingOriginal: false, comparing: false });
  });
  it('seeds each newly opened frame once, persists it, repairs restored framing and resolves ISO dates', async () => {
    const saved = { ...newSidecar(), geometry: crop, params: { ...newSidecar().params,
      filmEdge: { ...newSidecar().params.filmEdge, active: true }, dateBack: { ...newSidecar().params.dateBack, active: true } } };
    fake.load.mockResolvedValue(encodeSidecar(saved));
    await session.select('/owned/b.ARW');
    expect(state().sidecar.params.filmEdge).toMatchObject({ seeded: true, frameSeed: expect.any(Number), cameraSeed: expect.any(Number) });
    expect(state().sidecar.params.filmEdge.frameSeed).not.toBe(1);
    expect(state().sidecar.heldCrop).toEqual(crop);
    expect(state().undo).toHaveLength(0);
    expect(fake.params).toHaveBeenCalledWith('s2', expect.objectContaining({ date_imprint_text: "'26 10 1" }));
    await session.flushSave();
    const encoded = fake.save.mock.calls.at(-1)![1];
    const first = decodeSidecar(encoded);
    fake.load.mockResolvedValue(encoded);
    await session.select('/owned/c.ARW'); // saved seed belongs to edit even after a path move
    expect(state().sidecar.params.filmEdge.frameSeed).toBe(first.params.filmEdge.frameSeed);
    expect(state().sidecar.params.filmEdge.cameraSeed).toBe(first.params.filmEdge.cameraSeed);
  });
  it('date alone cuts nonidentity geometry, while an unsupported backend retains the user crop', async () => {
    session.setParams((p) => ({ ...p, filmFormatMM: 36, dateBack: { ...p.dateBack, active: true } })); await settle();
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({ source_geometry: crop, geometry: GEOMETRY_DEFAULT }));
    session.sessionStore.setState({ gate: { ...state().gate, dateImprint: false, overscan: false } });
    await session.requestPrint();
    expect(fake.render).toHaveBeenLastCalledWith('s1', 'live', expect.objectContaining({ source_geometry: GEOMETRY_DEFAULT, geometry: crop }));
    expect(state().sidecar.geometry).toEqual(crop);
  });
});
