import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { newSidecar, encodeSidecar, decodeSidecar } from '@shared/sidecar';
import { newPair, newHole, pairRects, encodePair, type HalfFramePair } from '@shared/pair';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { fullDelta } from '@shared/params';
import { StockCatalog } from '@shared/stocks';
import type { HelloResult, PairInfo } from '@shared/protocol';
import type * as SessionModule from './session';
import stocks from '../../../modern_UI/Spektrafilm/Spektrafilm/Resources/StockCatalog.json';

const fake = vi.hoisted(() => ({ sidecars: new Map<string, unknown>(), pairs: new Map<string, unknown>(),
  load: vi.fn(), save: vi.fn(), pairSave: vi.fn(), create: vi.fn(), list: vi.fn(), open: vi.fn(), update: vi.fn(), render: vi.fn(), latitude: vi.fn(),
  params: vi.fn(async () => ({})), close: vi.fn(async () => {}), pick: vi.fn(),
}));
const entry = (path: string) => ({ path, name: path.split('/').pop()!, size: 1, mtime_ms: 1 });
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  openPair: fake.open, updatePair: fake.update, renderView: fake.render, setParams: fake.params, close: fake.close,
  sceneLatitude: fake.latitude, pickNeutral: fake.pick, thumbnail: async () => { throw new Error('No fixture thumbnail'); },
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarLoad: fake.load, sidecarSave: fake.save,
  pairLoad: async (path: string) => fake.pairs.get(path) ?? null, pairSave: fake.pairSave, pairCreate: fake.create,
  pairList: fake.list, pairDelete: async (path: string) => { fake.pairs.delete(path); }, setTitle: async () => {},
  expandPaths: async (paths: string[]) => paths.map((path) => ({ path, name: path.split('/').pop()!, size: 1, mtime_ms: 1 })),
}), baseName: (p: string) => p.split('/').pop()!, dirName: (p: string) => p.slice(0, p.lastIndexOf('/')) }));
let session: typeof SessionModule;
const state = () => session.sessionStore.getState();
const hello = { methods: ['render_view', 'open_pair', 'update_pair', 'scene_latitude', 'redecode', 'pick_neutral'] } as HelloResult;
const path = '/store/pair.spektrapair';
let clock = 10000;
let recipe: HalfFramePair;
const info: PairInfo = { left: { width: 6000, height: 4000, kind: 'raw', available: true, metadata: { datetime_original: '2026-10-01T00:00:00' } },
  right: { width: 4000, height: 6000, kind: 'raw', available: true, metadata: { datetime_original: '2026-10-02T00:00:00' } } };
const opened = () => ({ session: 'pair-session', width: 3700, height: 2400, kind: 'pair', metadata: info.left!.metadata, pair_info: info });
const settle = () => vi.advanceTimersByTimeAsync(1);
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks(); fake.sidecars.clear(); fake.pairs.clear();
  clock = 10000; vi.spyOn(performance, 'now').mockImplementation(() => clock);
  recipe = { ...newPair('/roll'), left: newHole('/roll/a.ARW'), right: newHole('/roll/b.ARW') };
  fake.pairs.set(path, encodePair(recipe));
  fake.load.mockImplementation(async (p: string) => fake.sidecars.get(p) ?? null);
  fake.save.mockImplementation(async (p: string, v: unknown) => { fake.sidecars.set(p, v); return p; });
  fake.pairSave.mockImplementation(async (p: string, v: unknown) => { fake.pairs.set(p, v); });
  fake.list.mockImplementation(async () => [...fake.pairs.keys()].filter((p) => p.startsWith('/store/')).map(entry));
  fake.create.mockImplementation(async (_folder: string, v: unknown) => { fake.pairs.set('/store/imported.spektrapair', v); return entry('/store/imported.spektrapair'); });
  fake.open.mockImplementation(async () => opened()); fake.update.mockImplementation(async () => opened());
  fake.pick.mockResolvedValue({ temperature_k: 6200, tint: 5 });
  fake.render.mockImplementation(async () => ({ width: 370, height: 240, nativeSize: { width: 3700, height: 2400 }, data: new Uint8Array(0), colorSpace: 'sRGB', tier: 'preview', ms: 1,
    pairInfo: { ...info, gates: [{ x: .1, y: .2, width: .3, height: .6 }, { x: .6, y: .2, width: .3, height: .6 }] } }));
  fake.latitude.mockImplementation(async () => ({ medium: { shadow_ev: -5, highlight_ev: 4 }, scene: { histogram: { fractions: [.1, .8, .1] } },
    fit: { highlight: { scene_extreme_ev: 7, medium_boundary_ev: 4 }, shadow: { scene_extreme_ev: -8, medium_boundary_ev: -5 } } }));
  session = await import('./session');
  session.sessionStore.setState({ hello, hostState: { phase: 'ready', hello }, folder: '/roll',
    frames: [entry('/roll/a.ARW'), entry('/roll/b.ARW'), entry(path)], catalog: new StockCatalog(stocks.stocks) });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('half-frame pair editing lifecycle', () => {
  it('undoes a slow canvas placement gesture in one step and keeps the next gesture separate', async () => {
    await session.select(path); await settle();
    const before = state().pair!.right!.placement;
    session.beginGesture();
    clock += 700;
    session.setPairPlacement('right', (p) => ({ ...p, x: .1 }), true, true);
    clock += 700;
    session.setPairPlacement('right', (p) => ({ ...p, x: .2 }), true, true);
    session.commitPairPlacement();
    const first = state().pair!.right!.placement;
    session.beginGesture();
    session.setPairPlacement('right', (p) => ({ ...p, y: .1 }), true, true);
    session.commitPairPlacement();
    session.undo();
    expect(state().pair!.right!.placement).toEqual(first);
    session.undo();
    expect(state().pair!.right!.placement).toEqual(before);
  });
  it('persists native meter readings without an undo/rerender edit and sends them unchanged after moving and reopening', async () => {
    const metered = { ...info, left: { ...info.left!, metered_ev: 1.25, metered_for: 'native-left-v1' },
      right: { ...info.right!, metered_ev: -.75, metered_for: 'native-right-v1' } };
    fake.open.mockImplementation(async () => ({ ...opened(), pair_info: metered }));
    fake.update.mockImplementation(async () => ({ ...opened(), pair_info: metered }));
    await session.select(path); await settle();
    expect(state().pair?.left).toMatchObject({ meteredEV: 1.25, meteredFor: 'native-left-v1' });
    expect(state().undo).toHaveLength(0);
    await session.flushSave();
    const stored = fake.pairs.get(path) as HalfFramePair;
    expect(stored.left).toMatchObject({ meteredEV: 1.25, meteredFor: 'native-left-v1' });
    fake.update.mockClear(); await session.requestPrint();
    expect(fake.update).not.toHaveBeenCalled();
    session.setPairPlacement('left', (p) => ({ ...p, scale: 2, x: .8 }), false); await settle(); await session.flushSave();
    expect(state().pair?.left).toMatchObject({ placement: { scale: 2, x: .8 }, meteredEV: 1.25 });
    const other = '/store/other.spektrapair'; fake.pairs.set(other, encodePair(recipe));
    await session.select(other); await session.select(path);
    expect(fake.open.mock.calls.at(-1)?.[2]).toMatchObject({ left: { placement: { scale: 2, x: .8 }, meteredEV: 1.25, meteredFor: 'native-left-v1' },
      right: { meteredEV: -.75, meteredFor: 'native-right-v1' } });
  });
  it('preserves placement changed while opening and sends it with the original stable meter reading', async () => {
    const look = newSidecar(); look.params.filmEdge = { ...look.params.filmEdge, seeded: true };
    fake.sidecars.set(path, encodeSidecar(look));
    let finish!: (value: ReturnType<typeof opened>) => void;
    fake.open.mockImplementationOnce(() => new Promise((r) => { finish = r; }));
    const pending = session.select(path); await settle();
    session.setPairPlacement('left', (p) => ({ ...p, scale: 2, x: .5 }), false);
    finish({ ...opened(), pair_info: { ...info, left: { ...info.left!, metered_ev: 1, metered_for: 'initial-source' } } });
    await pending; await settle();
    expect(state().pair?.left).toMatchObject({ placement: { scale: 2, x: .5 }, meteredEV: 1, meteredFor: 'initial-source' });
    expect(fake.update.mock.calls.at(-1)?.[1]).toMatchObject({ left: { placement: { scale: 2, x: .5 }, meteredEV: 1, meteredFor: 'initial-source' } });
  });
  it('does not apply a late measurement after the same hole changes its decode', async () => {
    await session.select(path);
    let finish!: (value: ReturnType<typeof opened>) => void;
    fake.update.mockImplementationOnce(() => new Promise((r) => { finish = r; }));
    session.setPairPlacement('left', (p) => ({ ...p, scale: 2 }), false); await settle();
    session.setPairLayer('left');
    session.setDecode((d) => ({ ...d, whiteBalance: 'Custom', temperature: 6900 }));
    finish({ ...opened(), pair_info: { ...info, left: { ...info.left!, metered_ev: 1, metered_for: 'old-decode' } } });
    await settle();
    expect(state().pair?.left?.decode.temperature).toBe(6900);
    expect(state().pair?.left?.meteredFor).toBeUndefined();
  });
  it('opens native sources with independent saved decode/crop, migrates physical scale and sends identity output geometry', async () => {
    const own = newSidecar(); own.decode = { ...own.decode, whiteBalance: 'Custom', temperature: 6500, lensCorrection: true };
    own.geometry = { ...GEOMETRY_DEFAULT, crop: { x: .2, y: .1, width: .5, height: .8 } };
    fake.sidecars.set('/roll/a.ARW', encodeSidecar(own));
    const look = newSidecar(); look.params.dateBack.active = true; fake.sidecars.set(path, encodeSidecar(look));
    await session.select(path);
    expect(fake.open).toHaveBeenCalledWith(path, expect.objectContaining({ auto_exposure: false }), expect.objectContaining({ printEffects: true,
      left: expect.objectContaining({ decode: own.decode, geometry: own.geometry }) }));
    expect(state().sidecar.params).toMatchObject({ filmFrame: 'Custom', filmSide: 'long', sideLengthMM: 24, filmFormatMM: 37,
      dateBack: { text: "'26 10 1", textB: "'26 10 2" } });
    expect(fake.render).toHaveBeenCalledWith('pair-session', 'live', expect.objectContaining({ geometry: GEOMETRY_DEFAULT, source_geometry: GEOMETRY_DEFAULT }));
    expect(session.pairComplete()).toBe(true);
    await session.flushSave();
    expect(fake.pairSave).toHaveBeenCalledWith(path, expect.objectContaining({ left: expect.objectContaining({ path: '/roll/a.ARW' }) }));
    expect(fake.pairs.get(path)).not.toHaveProperty('printEffects');
  });
  it('switches scene UI layers without rerendering or moving the physical A/B curves and measures only that hole', async () => {
    await session.select(path);
    const p = state().sidecar.params;
    session.sessionStore.setState({ sidecar: { ...state().sidecar, params: { ...p,
      sceneLatitude: { ...p.sceneLatitude, active: true, highlightKnee: 2, highlightRoom: 3 },
      sceneLatitudeOther: { ...p.sceneLatitudeOther, active: true, shadowKnee: -4, shadowRoom: 2 } } } });
    const before = fullDelta(state().sidecar.params, state().gate, state().catalog);
    fake.render.mockClear(); session.setPairLayer('right');
    expect(fullDelta(state().sidecar.params, state().gate, state().catalog)).toEqual(before);
    expect(fake.render).not.toHaveBeenCalled();
    await session.refreshLatitude();
    const r = pairRects(state().pair!).right;
    expect(fake.latitude).toHaveBeenLastCalledWith('pair-session', expect.objectContaining({ region: [r.x, r.y, r.x + r.width, r.y + r.height] }), expect.anything());
  });
  it('keeps per-hole grades and print scopes independent, with native switch bypass and layer-aware reset/undo', async () => {
    await session.select(path); session.setPairLayer('left'); clock += 1000;
    session.setAdjustments((a) => ({ ...a, exposure: 1 })); await settle();
    expect(state().pair!.left!.adjustments!.exposure).toBe(1);
    expect(state().sidecar.adjustments.exposure).toBe(0);
    clock += 1000; session.setEnlarger((p) => ({ ...p, printBrightnessStops: 1 })); await settle();
    expect(state().pair!.left!.print!.brightnessStops).toBe(1);
    expect(state().pair!.right!.print!.brightnessStops).toBe(0);
    expect(state().sidecar.params.printBrightnessStops).toBe(1);
    clock += 1000; session.resetEnlarger(); await settle();
    expect(state().pair!.left!.print!.brightnessStops).toBe(0);
    expect(state().sidecar.params.printBrightnessStops).toBe(1);
    session.undo(); await settle(); expect(state().pair!.left!.print!.brightnessStops).toBe(1);
    session.setPairLayer('film'); clock += 1000; session.resetEnlarger(); await settle();
    expect(state().pair!.left!.print).toBeUndefined(); expect(state().pair!.right!.print).toBeUndefined();
    expect(state().sidecar.params.printBrightnessStops).toBe(0);
    session.setParams((p) => ({ ...p, printEffects: false })); await settle();
    expect(fake.update.mock.calls.at(-1)![1]).toMatchObject({ printEffects: false });
  });
  it('coalesces placement changes and never lets a late replacement overwrite a newer one', async () => {
    await session.select(path); fake.update.mockClear();
    session.setPairPlacement('left', (p) => ({ ...p, scale: 1.1 }));
    session.setPairPlacement('left', (p) => ({ ...p, scale: 1.2 }));
    expect(fake.update).not.toHaveBeenCalled(); await vi.advanceTimersByTimeAsync(281);
    expect(fake.update).toHaveBeenCalledTimes(1); expect(fake.update.mock.calls[0]![1].left.placement.scale).toBe(1.2);
    let release!: (v: unknown) => void;
    fake.load.mockImplementation(async (p: string) => p === '/roll/slow.ARW' ? await new Promise((r) => { release = r; }) : null);
    const old = session.setPairHole('left', '/roll/slow.ARW');
    await session.setPairHole('left', '/roll/new.ARW'); release(null); await old;
    expect(state().pair!.left!.path).toBe('/roll/new.ARW');
    await session.setPairHole('right', null); expect(session.pairComplete()).toBe(false);
    session.setPages({ exportOpen: true }); expect(state().exportOpen).toBe(false);
  });
  it('takes dynamic edge gates from the latest render and restores source-space gates with the edge off', async () => {
    await session.select(path);
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: true } })); await settle();
    expect(session.pairCanvasRects()!.left).toEqual({ x: .1, y: .2, width: .3, height: .6 });
    expect(state().pair!.onStrip).toBe(true);
    session.setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, active: false } })); await settle();
    expect(session.pairCanvasRects()).toEqual(pairRects(state().pair!));
  });
  it('imports an external recipe into the owned store with its look and leaves the shared source recipe unchanged', async () => {
    const external = '/shared/Album.spektrapair', look = newSidecar(); look.adjustments.exposure = .7;
    fake.pairs.set(external, encodePair(recipe)); fake.sidecars.set(external, encodeSidecar(look));
    const before = structuredClone(fake.pairs.get(external));
    await session.openPaths([external]);
    expect(fake.create).toHaveBeenCalledTimes(1);
    expect(state().selection).toBe('/store/imported.spektrapair');
    expect(state().frames).toHaveLength(1);
    expect(decodeSidecar(fake.sidecars.get(state().selection!)).adjustments.exposure).toBe(.7);
    expect(fake.pairs.get(external)).toEqual(before);
    expect(state().status).toContain('editable copy');
  });
  it('persists independent camera edits in order and restores that source white balance on undo', async () => {
    await session.select(path); session.setPairLayer('left');
    clock += 1000;
    session.setDecode((d) => ({ ...d, whiteBalance: 'Custom', temperature: 6000 }));
    session.setDecode((d) => ({ ...d, temperature: 7000, lensCorrection: true }));
    expect(state().pair!.left!.decode.temperature).toBe(7000);
    expect(state().pair!.right!.decode.temperature).not.toBe(7000);
    await settle();
    expect(decodeSidecar(fake.sidecars.get('/roll/a.ARW')).decode).toMatchObject({ temperature: 7000, lensCorrection: true });
    session.undo(); await settle();
    expect(decodeSidecar(fake.sidecars.get('/roll/a.ARW')).decode).toEqual(newSidecar().decode);
    expect(state().pair!.left!.decode).toEqual(newSidecar().decode);
  });
  it('samples only the selected RAW hole in whole-source coordinates and rejects an obsolete pick', async () => {
    await session.select(path); session.setPairLayer('right');
    expect(session.canPickNeutral()).toBe(true);
    session.startNeutralPick(); await session.pickNeutralAt(.2, .5);
    expect(fake.pick).not.toHaveBeenCalled();
    await session.pickNeutralAt(.8, .5); await settle();
    expect(fake.pick).toHaveBeenCalledWith('pair-session', .8, .5, 'right');
    expect(state().pair!.right!.decode).toMatchObject({ whiteBalance: 'Custom', temperature: 6200, tint: 5 });
    expect(state().pair!.left!.decode.whiteBalance).toBe('As Shot');
    await vi.advanceTimersByTimeAsync(281);
    let finish!: (v: { temperature_k: number; tint: number }) => void;
    fake.pick.mockImplementationOnce(() => new Promise((r) => { finish = r; }));
    session.startNeutralPick(); const pending = session.pickNeutralAt(.8, .5);
    session.setPairLayer('left'); finish({ temperature_k: 9000, tint: 30 }); await pending;
    expect(state().pair!.left!.decode.whiteBalance).toBe('As Shot');
    expect(state().pair!.right!.decode.temperature).toBe(6200);
  });
  it('keeps a hole white-balance edit bound to the source sidecar revision originally opened', async () => {
    const token = { key: '/store/a.json', base: 'a'.repeat(64) };
    fake.sidecars.set('/roll/a.ARW', { ...encodeSidecar(newSidecar()), _spkRevision: token });
    await session.select(path); await session.flushSave();
    session.setPairLayer('left');
    fake.sidecars.set('/roll/a.ARW', { ...encodeSidecar(newSidecar()), _spkRevision: { ...token, base: 'b'.repeat(64) } });
    fake.save.mockClear(); fake.save.mockRejectedValueOnce(new Error('EXTERNAL_EDIT_CONFLICT: source changed'));
    session.setDecode((d) => ({ ...d, whiteBalance: 'Custom', temperature: 7100 })); await settle();
    expect(fake.save.mock.calls[0]).toEqual(['/roll/a.ARW', expect.objectContaining({ _spkRevision: token })]);
    expect(state().pair?.left?.decode.temperature).toBe(7100);
    expect(state().externalEditConflict).toBe(true);
    await session.flushSave(); expect(fake.save).toHaveBeenCalledOnce();
  });
});
