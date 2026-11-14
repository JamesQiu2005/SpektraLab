import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { newSidecar, encodeSidecar, decodeSidecar } from '@shared/sidecar';
import { ALL_FEATURES } from '@shared/params';
import type { HelloResult } from '@shared/protocol';
import type * as Session from './session';

const fake = vi.hoisted(() => ({ solve: vi.fn(), source: vi.fn(), thumbnail: vi.fn(), params: vi.fn(async () => ({})), save: vi.fn(async () => '') }));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  solve: fake.solve, setParams: fake.params,
  renderSource: fake.source, thumbnail: fake.thumbnail,
  render: async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'sRGB', tier: 'live', ms: 1 }),
}) }));
vi.mock('../platform', () => ({ platform: () => ({ log: vi.fn(), sidecarSave: fake.save }),
  baseName: (p: string) => p, dirName: () => '/owned' }));
let session: typeof Session;
beforeEach(async () => {
  vi.useFakeTimers(); vi.resetModules(); vi.clearAllMocks();
  vi.spyOn(performance, 'now').mockReturnValue(10000);
  fake.solve.mockResolvedValue({ solved_params: { exposure_compensation_ev: 1.25 } });
  session = await import('./session');
  const hello = { methods: ['solve'] } as HelloResult;
  session.sessionStore.setState({ engineSession: 'one', selection: '/owned/a.RAF', hello,
    hostState: { phase: 'ready', hello }, gate: ALL_FEATURES, nativeSize: { width: 6, height: 4 }, sidecar: newSidecar() });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); });
const state = () => session.sessionStore.getState();

function grayImage(code: number) {
  const data = new Uint8Array(32 * 32 * 4).fill(code);
  for (let i = 3; i < data.length; i += 4) data[i] = 255;
  return { width: 32, height: 32, data, colorSpace: 'sRGB' };
}
function cameraReady() {
  session.sessionStore.setState({ hello: { methods: ['solve', 'render_source'], thumbnail_options: ['embedded-only'] } as HelloResult });
  fake.source.mockResolvedValue(grayImage(69)); // ~6% linear
  fake.thumbnail.mockResolvedValue(grayImage(118)); // ~18% linear
}

describe('As Shot camera brightness', () => {
  it('shows an explicit As Shot preset until a manual exposure edit, even when the number is unchanged', async () => {
    cameraReady();
    await session.setCameraMetering('as_shot');
    expect(session.cameraMeteringPreset()).toBe('as_shot');
    const saved = decodeSidecar(encodeSidecar(state().sidecar));
    session.sessionStore.setState({ sidecar: saved });
    expect(session.cameraMeteringPreset()).toBe('as_shot');
    const exposure = session.cameraExposureTotal()!;
    session.beginGesture(); session.setCameraExposureTotal(exposure);
    expect(session.cameraMeteringPreset()).toBe('custom');
    expect(session.cameraExposureIsAsShot()).toBe(false);
    session.undo(); expect(session.cameraMeteringPreset()).toBe('as_shot');
    session.redo(); expect(session.cameraMeteringPreset()).toBe('custom');
    session.setCameraMetering('linear'); expect(session.cameraMeteringPreset()).toBe('linear');
    session.setCameraMetering('balanced'); expect(session.cameraMeteringPreset()).toBe('balanced');
  });
  it('persists the camera reference and uses pre-scene EV without changing auto exposure or film controls elsewhere', async () => {
    cameraReady();
    await session.requestPrint();
    const before = structuredClone(state().sidecar);
    await session.applyCameraExposureAsShot();
    const p = state().sidecar.params;
    expect(p.exposureBaselineEV).toBeGreaterThan(1.5);
    expect(p.exposureBaselineEV).toBeLessThan(1.7);
    expect(p).toEqual({ ...before.params, autoExposure: false, exposureCompensationEV: 0, exposureBaselineEV: p.exposureBaselineEV });
    expect(state().sidecar.adjustments).toEqual(before.adjustments);
    expect(session.cameraExposureIsAsShot()).toBe(true);
    const saved = decodeSidecar(encodeSidecar(state().sidecar));
    session.sessionStore.setState({ sidecar: saved });
    expect(session.cameraExposureIsAsShot()).toBe(true);
    session.undo(); expect(state().sidecar.params).toEqual(before.params);
    session.redo(); expect(session.cameraExposureIsAsShot()).toBe(true);
    session.setCameraMetering('balanced');
    expect(state().sidecar.params).toMatchObject({ autoExposure: true, exposureBaselineEV: 0, exposureCompensationEV: 0 });
    expect(session.cameraExposureIsAsShot()).toBe(false);
    expect(fake.thumbnail).toHaveBeenCalledWith('/owned/a.RAF', 720, true);
    expect(fake.source).toHaveBeenCalledWith('one', { long_edge: 720, display: 'srgb', generation: 0 });
  });
  it('keeps exposure when no usable camera preview is available', async () => {
    cameraReady();
    const before = structuredClone(state().sidecar.params);
    fake.thumbnail.mockRejectedValueOnce(new Error('No embedded preview'));
    await session.applyCameraExposureAsShot();
    expect(state().sidecar.params).toEqual(before);
    fake.thumbnail.mockResolvedValueOnce(grayImage(0));
    await session.applyCameraExposureAsShot();
    expect(state().sidecar.params).toEqual(before);
    expect(state().undo).toHaveLength(0);
  });
  it('drops results after switching photographs, editing exposure, or explicitly resetting an unchanged baseline', async () => {
    cameraReady();
    let release!: (value: unknown) => void;
    fake.source.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    const pending = session.applyCameraExposureAsShot();
    await vi.advanceTimersByTimeAsync(0);
    session.sessionStore.setState({ engineSession: 'two', selection: '/owned/b.RAF' });
    release(grayImage(69)); await pending;
    expect(state().sidecar.params.autoExposure).toBe(true);
    session.resetCameraExposure();
    fake.source.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    const again = session.applyCameraExposureAsShot();
    await vi.advanceTimersByTimeAsync(0);
    session.resetCameraExposure(); // same numerical state, but newer explicit intent
    release(grayImage(69)); await again;
    expect(state().sidecar.params.exposureBaselineEV).toBe(0);
    expect(state().sidecar.cameraExposureReference).toBeUndefined();
  });
  it('leaves ordinary rendered files on their zero baseline and never infers a match from film pixels', async () => {
    session.sessionStore.setState({ frameKind: 'jpeg', selection: '/owned/a.jpg' });
    await session.applyCameraExposureAsShot();
    expect(state().sidecar.params).toMatchObject({ autoExposure: false, exposureBaselineEV: 0, exposureCompensationEV: 0 });
    expect(fake.source).not.toHaveBeenCalled();
    expect(fake.thumbnail).not.toHaveBeenCalled();
  });
});

describe('exposure handoff', () => {
  it('uses the same pre-scene exposure after As Shot and manual re-entry', async () => {
    await session.requestPrint();
    const metered = session.cameraExposureTotal()!;
    session.resetCameraExposure();
    session.setCameraExposureTotal(metered);
    expect(state().sidecar.params).toMatchObject({ autoExposure: false, exposureBaselineEV: metered, exposureCompensationEV: 0 });
    session.setCameraExposureTotal(metered + .5);
    expect(state().sidecar.params.exposureBaselineEV).toBe(metered + .5);
    expect(state().sidecar.params.exposureCompensationEV).toBe(0);
  });
  it('shows meter plus existing compensation and freezes only the exposure state', async () => {
    session.sessionStore.setState({ sidecar: { ...state().sidecar, params: { ...state().sidecar.params, exposureCompensationEV: .4 } } });
    await session.requestPrint();
    expect(session.cameraExposureTotal()).toBe(1.65);
    const before = structuredClone(state().sidecar);
    session.setCameraMetering('custom');
    expect(state().sidecar.params).toEqual({ ...before.params, autoExposure: false, exposureBaselineEV: 1.25 });
    expect(state().sidecar.decode).toEqual(before.decode);
    expect(state().sidecar.adjustments).toEqual(before.adjustments);
    expect(session.cameraExposureTotal()).toBe(1.65);
    const saved = decodeSidecar(encodeSidecar(state().sidecar));
    expect(saved.params.exposureBaselineEV).toBe(1.25);
    expect(saved.params.exposureCompensationEV).toBe(.4);
    session.setCameraExposureTotal(2.15);
    expect(state().sidecar.params.exposureCompensationEV).toBe(.4);
    expect(state().sidecar.params.exposureBaselineEV).toBe(1.75);
    expect(fake.solve).toHaveBeenCalledTimes(1);
  });
  it('manual editing owns one undo step, then As Shot clears both exposure terms', async () => {
    await session.requestPrint();
    const before = structuredClone(state().sidecar);
    session.beginGesture(); session.setCameraExposureTotal(2);
    expect(session.cameraExposureTotal()).toBe(2);
    expect(state().sidecar.params).toEqual({ ...before.params, autoExposure: false, exposureBaselineEV: 2 });
    session.undo();
    expect(state().sidecar.params).toEqual(before.params);
    expect(session.cameraExposureTotal()).toBe(1.25);
    session.setCameraMetering('custom'); session.resetCameraExposure();
    expect(session.cameraExposureTotal()).toBe(0);
    expect(state().sidecar.params.autoExposure).toBe(false);
    expect(state().sidecar.params.exposureBaselineEV).toBe(0);
  });
  it('rejects an old method reading while a new meter is pending', async () => {
    let release!: (r: unknown) => void;
    fake.solve.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    const pending = session.requestPrint();
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.solve).toHaveBeenCalledTimes(1);
    session.setCameraMetering('center');
    expect(session.cameraExposureTotal()).toBeNull();
    session.setCameraMetering('custom');
    expect(state().sidecar.params.autoExposure).toBe(true);
    fake.solve.mockResolvedValue({ solved_params: { exposure_compensation_ev: -.5 } });
    release({ solved_params: { exposure_compensation_ev: 7 } }); await pending;
    expect(session.cameraExposureTotal()).toBe(-.5);
    expect(state().exposureReadings.some((r) => r.ev === 7)).toBe(false);
  });
  it('large readings are retained exactly rather than clamped to the slider’s old bounds', async () => {
    fake.solve.mockResolvedValue({ solved_params: { exposure_compensation_ev: 12 } });
    await session.requestPrint(); session.setCameraMetering('custom');
    expect(session.cameraExposureTotal()).toBe(12);
    session.setCameraExposureTotal(12.5);
    expect(state().sidecar.params.exposureCompensationEV).toBe(0);
    expect(state().sidecar.params.exposureBaselineEV).toBe(12.5);
    session.setCameraMetering('balanced');
    expect(state().sidecar.params).toMatchObject({ autoExposure: true, exposureBaselineEV: 0, exposureCompensationEV: 0 });
  });
  it('does not adopt a late reading after switching photographs', async () => {
    let release!: (r: unknown) => void;
    fake.solve.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    const pending = session.requestPrint(); await vi.advanceTimersByTimeAsync(0);
    session.sessionStore.setState({ selection: '/owned/next.RAF', engineSession: null });
    release({ solved_params: { exposure_compensation_ev: 3 } }); await pending;
    expect(session.cameraExposureTotal()).toBeNull();
    expect(state().exposureReadings).toEqual([]);
    session.setCameraExposureTotal(2);
    expect(state().sidecar.params.autoExposure).toBe(true);
  });
});
