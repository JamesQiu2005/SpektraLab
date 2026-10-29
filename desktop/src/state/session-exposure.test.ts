import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { newSidecar, encodeSidecar, decodeSidecar } from '@shared/sidecar';
import { ALL_FEATURES } from '@shared/params';
import type { HelloResult } from '@shared/protocol';
import type * as Session from './session';

const fake = vi.hoisted(() => ({ solve: vi.fn(), params: vi.fn(async () => ({})), save: vi.fn(async () => '') }));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => ({
  solve: fake.solve, setParams: fake.params,
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
