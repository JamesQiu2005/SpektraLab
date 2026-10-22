import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult } from '@shared/protocol';
import type { RenderReply } from '../host/client';
import type * as SessionModule from './session';
import { newSidecar } from '@shared/sidecar';

const fake = vi.hoisted(() => ({
  setParams: vi.fn(async () => ({})), renderView: vi.fn(), render: vi.fn(),
  open: vi.fn(), close: vi.fn(async () => {}), thumbnail: vi.fn(), logs: [] as string[],
  frames: { print: null as RenderReply | null, original: null },
}));
vi.mock('../host/client', () => ({ HostCallError: class extends Error {}, host: () => fake }));
vi.mock('./frames', () => ({ frameImages: fake.frames, makeThumbFromPrint: async () => null, THUMB_EDGE: 320 }));
vi.mock('../platform', () => ({
  platform: () => ({ log: (_level: string, message: string) => fake.logs.push(message), sidecarSave: async () => '', sidecarLoad: async () => null }),
  baseName: (path: string) => path.split('/').pop(), dirName: () => '/owned',
}));

const frame = (red: number): RenderReply => ({ width: 1, height: 1, data: new Uint8Array([red, 80, 60, 255]),
  colorSpace: 'sRGB', tier: 'live', reprinted: true, ms: 1 });
let session: typeof SessionModule;

beforeEach(async () => {
  vi.useFakeTimers();
  vi.resetModules();
  vi.clearAllMocks();
  vi.stubGlobal('window', { addEventListener: vi.fn() });
  fake.frames.print = null;
  fake.logs.length = 0;
  fake.renderView.mockReset().mockResolvedValue(frame(200));
  session = await import('./session');
  session.sessionStore.setState({ selection: '/owned/frame.ARW', picked: ['/owned/frame.ARW'], engineSession: 's1',
    hello: { methods: ['render_view'] } as HelloResult, sidecar: newSidecar(), nativeSize: { width: 1, height: 1 },
    imageVersion: 0, displaySpace: 'srgb' });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.unstubAllGlobals(); });

describe('processed preview scheduling', () => {
  it('a grade edit requests a cached view without resending film parameters', async () => {
    await session.requestPrint();
    fake.setParams.mockClear();
    fake.renderView.mockClear();
    session.setAdjustments((a) => ({ ...a, exposure: 1.25 }));
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.setParams).not.toHaveBeenCalled();
    expect(fake.render).not.toHaveBeenCalled();
    expect(fake.renderView).toHaveBeenCalledWith('s1', 'live', expect.objectContaining({
      adjustments: expect.objectContaining({ exposure: 1.25 }), display: 'srgb', generation: expect.any(Number),
    }));
  });

  it('coalesces rapid edits and never publishes an older generation', async () => {
    let release!: (reply: RenderReply) => void;
    fake.renderView.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    const pending = session.requestPrint();
    await vi.advanceTimersByTimeAsync(0);
    const firstGen = fake.renderView.mock.calls[0]![2].generation as number;
    session.setAdjustments((a) => ({ ...a, exposure: 1 }));
    session.setAdjustments((a) => ({ ...a, exposure: 2 }));
    release(frame(10));
    await pending;
    expect(fake.renderView).toHaveBeenCalledTimes(2);
    expect(fake.renderView.mock.calls[1]![2]).toMatchObject({ adjustments: { exposure: 2 } });
    expect(fake.renderView.mock.calls[1]![2].generation).toBeGreaterThan(firstGen);
    expect(session.sessionStore.getState().imageVersion).toBe(1);
    expect(fake.frames.print?.data[0]).toBe(200);
  });

  it('changing display gamut preserves edits and does not re-develop the film', async () => {
    await session.requestPrint();
    const saved = structuredClone(session.sessionStore.getState().sidecar);
    fake.setParams.mockClear();
    fake.renderView.mockClear();
    session.noteDisplaySpace('display-p3');
    await vi.advanceTimersByTimeAsync(0);
    expect(session.sessionStore.getState().sidecar).toEqual(saved);
    expect(fake.setParams).not.toHaveBeenCalled();
    expect(fake.renderView).toHaveBeenCalledWith('s1', 'live', expect.objectContaining({ display: 'display-p3' }));
  });

  it('drops an old session result after selection changes', async () => {
    let release!: (reply: RenderReply) => void;
    fake.renderView.mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    const pending = session.requestPrint();
    await vi.advanceTimersByTimeAsync(0);
    session.sessionStore.setState({ engineSession: 's2', selection: '/owned/next.ARW' });
    release(frame(10));
    await pending;
    expect(fake.frames.print).toBeNull();
    expect(session.sessionStore.getState().imageVersion).toBe(0);
  });

  it('renders the full source after idle but returns only Fit display pixels and an uncropped thumbnail', async () => {
    const sidecar = newSidecar();
    sidecar.geometry = { ...sidecar.geometry, crop: { x: 0.2, y: 0.1, width: 0.7, height: 0.8 }, quarterTurns: 1 };
    session.sessionStore.setState({ nativeSize: { width: 7028, height: 4688 }, maxTextureSize: 8192,
      canvasPx: { width: 1600, height: 1000 }, sidecar });
    fake.renderView.mockImplementation(async (_sid: string, tier: string) => ({ ...frame(200), tier }));
    await session.requestPrint();
    await vi.advanceTimersByTimeAsync(400);
    const calls = fake.renderView.mock.calls;
    expect(calls).toHaveLength(3);
    expect(calls[0]).toEqual(['s1', 'live', expect.objectContaining({ long_edge: 2560, geometry: sidecar.geometry })]);
    expect(calls[1]).toEqual(['s1', 'full', expect.objectContaining({ long_edge: 2560, geometry: sidecar.geometry })]);
    expect(calls[2]).toEqual(['s1', 'full', expect.objectContaining({ long_edge: 320,
      geometry: expect.objectContaining({ crop: { x: 0, y: 0, width: 1, height: 1 }, quarterTurns: 0 }) })]);
    expect(session.sessionStore.getState().badge).toBe('full');
  });

  it('requests native output at 100 percent and never re-renders merely to pan', async () => {
    session.sessionStore.setState({ nativeSize: { width: 7028, height: 4688 }, maxTextureSize: 8192 });
    await session.requestPrint();
    fake.renderView.mockClear();
    fake.setParams.mockClear();
    session.setView({ fit: false, zoom: 1 });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.renderView).toHaveBeenCalledOnce();
    expect(fake.renderView.mock.calls[0]![2]).toMatchObject({ long_edge: 0 });
    expect(fake.setParams).not.toHaveBeenCalled();
    session.setView({ cx: 0.6, cy: 0.4 });
    session.noteCanvasPx(1000, 700);
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.renderView).toHaveBeenCalledOnce();
  });

  it('bounds high-DPI Fit and native zoom to the actual texture limit', () => {
    session.sessionStore.setState({ nativeSize: { width: 10000, height: 7000 }, maxTextureSize: 4096,
      canvasPx: { width: 5500, height: 3600 } });
    expect(session.viewLongEdge(session.sessionStore.getState())).toBe(4096);
    session.sessionStore.setState({ view: { fit: false, zoom: 1, cx: 0.5, cy: 0.5 } });
    expect(session.viewLongEdge(session.sessionStore.getState())).toBe(4096);
    session.sessionStore.setState({ maxTextureSize: 16384 });
    expect(session.viewLongEdge(session.sessionStore.getState())).toBe(0);
    session.sessionStore.setState({ view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 } });
    expect(session.viewLongEdge(session.sessionStore.getState())).toBe(5500);
  });

  it('retries the latest edit after an obsolete render fails without exposing that error', async () => {
    let reject!: (reason: Error) => void;
    fake.renderView.mockImplementationOnce(() => new Promise((_resolve, no) => { reject = no; }));
    const pending = session.requestPrint();
    await vi.advanceTimersByTimeAsync(0);
    session.setAdjustments((a) => ({ ...a, exposure: 2 }));
    reject(new Error('obsolete request failed'));
    await pending;
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.renderView).toHaveBeenCalledTimes(2);
    expect(fake.frames.print?.data[0]).toBe(200);
    expect(session.sessionStore.getState().lastError).toBeNull();
  });

  it('discards the idle full-quality reply when a new grade arrives during it', async () => {
    let release!: (reply: RenderReply) => void;
    session.sessionStore.setState({ nativeSize: { width: 7028, height: 4688 } });
    fake.renderView.mockResolvedValueOnce(frame(100))
      .mockImplementationOnce(() => new Promise((resolve) => { release = resolve; }));
    await session.requestPrint();
    await vi.advanceTimersByTimeAsync(400);
    expect(fake.renderView.mock.calls[1]![1]).toBe('full');
    session.setAdjustments((a) => ({ ...a, contrast: 30 }));
    release({ ...frame(10), tier: 'full' });
    await vi.advanceTimersByTimeAsync(0);
    expect(fake.renderView).toHaveBeenCalledTimes(3);
    expect(fake.renderView.mock.calls[2]![2]).toMatchObject({ adjustments: { contrast: 30 } });
    expect(fake.frames.print?.data[0]).toBe(200);
    expect(session.sessionStore.getState().imageVersion).toBe(2);
  });

  it('records decode phases and the first actual preview commit/draw, not merely open completion', async () => {
    fake.thumbnail.mockResolvedValue(frame(50));
    const raw = { open: 1, unpack: 2, process: 3, convert: 4, total: 10, openmp_enabled: true, workers: 8 };
    fake.open.mockResolvedValue({ session: 'new', width: 1, height: 1, kind: 'raw', metadata: {}, params: {},
      timings_ms: { decode: 12, open: 5, raw } });
    session.sessionStore.setState({ selection: null, engineSession: null,
      hostState: { phase: 'ready', hello: { methods: ['render_view'] } as HelloResult } });
    await session.select('/owned/new.ARW');
    await vi.advanceTimersByTimeAsync(0);
    const open = fake.logs.find((message) => message.startsWith('session: open '));
    expect(open).toContain('"raw":{"open":1,"unpack":2,"process":3,"convert":4,"total":10,"openmp_enabled":true,"workers":8}');
    const engineEvents = () => fake.logs.filter((message) => message.startsWith('session: first_view '));
    expect(engineEvents().filter((message) => message.includes('"event":"committed"'))).toHaveLength(1);
    expect(fake.logs.some((message) => message.includes('"event":"draw_submitted"'))).toBe(false);
    session.notePreviewDrawn();
    session.notePreviewDrawn();
    expect(engineEvents().filter((message) => message.includes('"event":"draw_submitted"'))).toHaveLength(1);
    expect(fake.logs.filter((message) => message.startsWith('session: preview_visible ') && message.includes('"event":"draw_submitted"'))).toHaveLength(1);
  });
});
