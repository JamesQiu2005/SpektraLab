import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { SCENE_LATITUDE_DEFAULT, ALL_FEATURES } from '@shared/params';
import { newSidecar, encodeSidecar } from '@shared/sidecar';
import { fitPlacement, type LatitudeReply } from '@shared/latitude';
import type { HelloResult } from '@shared/protocol';
import type * as SessionModule from './session';

const fake = vi.hoisted(() => ({
  latitude: vi.fn(), save: vi.fn(async () => ''), load: vi.fn(async () => null as unknown),
  setParams: vi.fn(async (_sid: string, _delta: unknown) => ({})), render: vi.fn(async () => ({ width: 6, height: 4,
    data: new Uint8Array(96), colorSpace: 'sRGB', tier: 'preview', reprinted: false, ms: 1 })),
}));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  sceneLatitude: fake.latitude, setParams: fake.setParams, render: fake.render,
  close: async () => {}, open: async () => ({ session: 's2', width: 6, height: 4, kind: 'raw' }),
  thumbnail: async () => { throw new Error('No fixture thumbnail'); },
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarLoad: fake.load,
  sidecarSave: fake.save, setTitle: async () => {} }),
  baseName: (p: string) => p.split('/').pop()!, dirName: (p: string) => p.slice(0, p.lastIndexOf('/')) }));
let session: typeof SessionModule;
const state = () => session.sessionStore.getState();
function reply(h = 0, sh = 0): LatitudeReply {
  const at = { highlightExtreme: 7, highlightBoundary: 4, shadowExtreme: -8, shadowBoundary: -5 };
  const fitted = fitPlacement(at, h, sh, SCENE_LATITUDE_DEFAULT), p = fitted.placed;
  const side = { on: false, pull_back: 0, minimum_pull_back: 3, scene_extreme_ev: 7, medium_boundary_ev: 4, landing_ev: 7, slope_at_extreme: 1 };
  return { medium: { shadow_ev: -5, highlight_ev: 4, latitude_stops: 9, y_black: .01, y_white: 1, ramp_ev: [], ramp_y: [] },
    scene: { norm: 'power', samples: 100, p0_1: -8, p1: -7, p50: 0, p99: 6, p99_9: 7,
      histogram: { lo_ev: -16, hi_ev: 16, fractions: [0.1, 0.8, 0.1] } },
    suggested: { highlight_pull_back: 4, shadow_pull_back: 0, margin_used: 1, valid: true },
    fit: { valid: !!p, issues: fitted.issue ? [fitted.issue] : [], warnings: [],
      highlight: { ...side, pull_back: h }, shadow: { ...side, pull_back: sh, scene_extreme_ev: -8, medium_boundary_ev: -5 },
      params_delta: p ? { scene_latitude_active: p.active, scene_latitude_norm: p.norm,
        scene_latitude_highlight_knee: p.highlightKnee, scene_latitude_highlight_room: p.highlightRoom,
        scene_latitude_shadow_knee: p.shadowKnee, scene_latitude_shadow_room: p.shadowRoom,
        scene_latitude_rolloff: p.rolloff, scene_latitude_max_lift: p.maxLift } : undefined } };
}
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  vi.spyOn(performance, 'now').mockReturnValue(10_000);
  fake.latitude.mockImplementation(async (_sid, req) => reply(req.highlight_pull_back, req.shadow_pull_back));
  fake.load.mockResolvedValue(null);
  session = await import('./session');
  session.sessionStore.setState({ selection: '/owned/a.ARW', picked: ['/owned/a.ARW'], engineSession: 's1',
    hostState: { phase: 'ready', hello: { methods: ['scene_latitude'] } as HelloResult },
    hello: { methods: ['scene_latitude'] } as HelloResult, gate: ALL_FEATURES,
    nativeSize: { width: 6, height: 4 }, sidecar: structuredClone(newSidecar()) });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });

describe('Scene Placement lifecycle', () => {
  it('clamps a slider with the measured window locally and sends the solved curve without another probe', async () => {
    await session.refreshLatitude();
    expect(session.placementReady()).toBe(true);
    const lo = session.currentPlacementWindow('highlight')!.span![0];
    session.placeScene('highlight', .25);
    expect(state().sidecar.params.sceneLatitude).toMatchObject({ active: true, highlightPullBack: lo });
    expect(state().latitude.refusal?.side).toBe('highlight');
    expect(fake.latitude).toHaveBeenCalledTimes(1);
    expect(fake.setParams).toHaveBeenCalledWith('s1', expect.objectContaining({ scene_latitude_active: true }));
    await session.requestPrint();
    session.resetScenePlacement();
    expect(state().sidecar.params.sceneLatitude).toEqual(SCENE_LATITUDE_DEFAULT);
  });

  it('keeps unsupported hosts disabled and invalidates measured data for a new exposure', async () => {
    await session.refreshLatitude();
    session.sessionStore.setState({ gate: { ...ALL_FEATURES, sceneLatitude: false } });
    const before = state().sidecar;
    session.placeScene('highlight', 4);
    expect(state().sidecar).toBe(before);
    session.sessionStore.setState({ gate: ALL_FEATURES });
    session.setParams((p) => ({ ...p, exposureCompensationEV: 1 }));
    expect(session.placementReady()).toBe(false);
  });

  it('rejects an old measurement after a newer probe or a switched photograph', async () => {
    let finish!: (r: LatitudeReply) => void;
    fake.latitude.mockImplementationOnce(() => new Promise<LatitudeReply>((r) => { finish = r; }));
    const old = session.refreshLatitude();
    const latest = reply(4);
    fake.latitude.mockResolvedValueOnce(latest);
    await session.refreshLatitude();
    finish(reply()); await old;
    expect(state().latitude.reply).toBe(latest);
    fake.latitude.mockImplementationOnce(() => new Promise<LatitudeReply>((r) => { finish = r; }));
    const moved = session.refreshLatitude();
    session.sessionStore.setState({ selection: '/owned/b.ARW', engineSession: 's2' });
    finish(reply()); expect(await moved).toBeNull();
    expect(session.placementReady()).toBe(false);
  });

  it('pastes intent first, fits the target and saves the fitted curve in the same undo operation', async () => {
    const source = structuredClone(newSidecar());
    source.params.sceneLatitude = { ...SCENE_LATITUDE_DEFAULT, active: true, highlightPullBack: 4,
      highlightKnee: -3, highlightRoom: 7 };
    session.sessionStore.setState({ clipboard: { groups: ['scenePlacement'], sourceName: 'source', settings: source } });
    await session.pasteSettings();
    await vi.advanceTimersByTimeAsync(10);
    expect(fake.setParams.mock.calls[0]![1]).toMatchObject({ scene_latitude_active: false, scene_latitude_highlight_room: 0 });
    expect(fake.latitude).toHaveBeenCalledWith('s1', expect.objectContaining({ highlight_pull_back: 4 }), expect.objectContaining({ params: expect.any(Object), source_geometry: expect.any(Object) }));
    expect(state().sidecar.placementNeedsFit).toBe(false);
    expect(state().sidecar.params.sceneLatitude).toMatchObject({ active: true, highlightPullBack: 4 });
    expect(state().sidecar.params.sceneLatitude.highlightKnee).not.toBe(-3);
    expect(state().undo).toHaveLength(1);
    await session.flushSave(); expect(fake.save).toHaveBeenCalled();
    session.undo(); expect(state().sidecar.params.sceneLatitude.active).toBe(false);
  });

  it('restores pending sidecars as identity and reports a refused target fit without retaining a source curve', async () => {
    const pending = structuredClone(newSidecar());
    pending.placementNeedsFit = true;
    pending.params.sceneLatitude = { ...SCENE_LATITUDE_DEFAULT, active: true, highlightPullBack: 1, highlightRoom: 7 };
    fake.load.mockResolvedValue(encodeSidecar(pending));
    await session.select('/owned/b.ARW');
    await vi.advanceTimersByTimeAsync(10);
    expect(state().sidecar.placementNeedsFit).toBe(false);
    expect(state().sidecar.params.sceneLatitude).toMatchObject({ active: false, highlightPullBack: 0, highlightRoom: 0 });
    expect(state().latitude.refusal?.code).toBe('pull_back_below_minimum');
    expect(state().undo).toHaveLength(0);
  });

  it('does not let a pending paste overwrite a reset made before its probe returns', async () => {
    const pending = structuredClone(newSidecar());
    pending.placementNeedsFit = true;
    pending.params.sceneLatitude.highlightPullBack = 4;
    session.sessionStore.setState({ sidecar: pending });
    let finish!: (r: LatitudeReply) => void;
    fake.latitude.mockImplementationOnce(() => new Promise<LatitudeReply>((r) => { finish = r; }));
    const rendering = session.requestPrint();
    await vi.advanceTimersByTimeAsync(1);
    session.resetScenePlacement();
    finish(reply(4)); await rendering;
    expect(state().sidecar.params.sceneLatitude).toEqual(SCENE_LATITUDE_DEFAULT);
    expect(state().sidecar.placementNeedsFit).toBe(false);
    expect(state().undo[0]?.placementNeedsFit).toBe(true);
  });
});
