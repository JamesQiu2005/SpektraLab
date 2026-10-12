import { beforeEach, describe, expect, it, vi } from 'vitest';
import { ALL_FEATURES, featureGate, fullDelta } from '@shared/params';
import { encodeSidecar, newSidecar } from '@shared/sidecar';
import { StockCatalog } from '@shared/stocks';
import { captureExportFrames, exportFrame, hostWrites, type FrameToExport } from './exporter';
import { DEFAULT_RECIPES } from './recipes';
import type * as PlatformModule from '../platform';

const fake = vi.hoisted(() => ({
  request: vi.fn(), open: vi.fn(), close: vi.fn(), probe: vi.fn(),
  sidecarLoad: vi.fn(), ensureDir: vi.fn(), pathExists: vi.fn(), log: vi.fn(),
}));
vi.mock('../host/client', () => ({ host: () => ({
  transport: { request: fake.request }, open: fake.open, close: fake.close, probe: fake.probe,
}) }));
vi.mock('../platform', async (original) => ({
  ...await original<typeof PlatformModule>(), platform: () => fake,
}));
const catalog = new StockCatalog([
  { id: 'slide', name: 'Slide', stage: 'filming', type: 'positive', use: 'still', hasPreviewLUT: true },
]);
function frame(): FrameToExport {
  const s = structuredClone(newSidecar());
  return { path: 'D:/photos/a.NEF', session: 'editor', params: s.params,
    decode: s.decode, geometry: s.geometry, adjustments: s.adjustments,
    gate: structuredClone(ALL_FEATURES), native: { width: 6000, height: 4000 } };
}
function recipe() { return structuredClone(DEFAULT_RECIPES[0]!); }
function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}
beforeEach(() => {
  vi.resetAllMocks();
  fake.ensureDir.mockResolvedValue(undefined);
  fake.pathExists.mockResolvedValue(false);
  fake.sidecarLoad.mockResolvedValue(null);
  fake.probe.mockResolvedValue({ width: 6000, height: 4000, metadata: { datetime_original: '2026-10-01T12:00:00' } });
  fake.open.mockResolvedValue({ session: 'private-di', width: 6000, height: 4000 });
  fake.close.mockResolvedValue(undefined);
  fake.request.mockResolvedValue({ result: { path: 'D:/out/image.jpg', width: 3000, height: 2000,
    bytes: 123, timings_ms: { total: 123 } }, payload: new Uint8Array() });
});

describe('host frame export', () => {
  it('requires the complete frame capability and never silently falls back to print-only export', async () => {
    expect(hostWrites(['write_image', 'export_image'])).toBe(false);
    expect(hostWrites(['export_frame'])).toBe(true);
    const outcome = await exportFrame(recipe(), frame(), catalog, ['write_image', 'export_image']);
    expect(outcome).toMatchObject({ kind: 'failed', message: expect.stringContaining('export_frame') });
    expect(fake.ensureDir).not.toHaveBeenCalled();
    expect(fake.request).not.toHaveBeenCalled();
  });
  it('sends only an immutable JSON snapshot with gated params, decode, grade and geometry', async () => {
    const f = frame(), r = recipe();
    f.gate = featureGate(['scene_latitude_mapping', 'overscan', 'date_imprint', 'contrast_mask']);
    f.decode = { ...f.decode, whiteBalance: 'Custom', temperature: 6200, tint: 13 };
    f.adjustments.exposure = 1.25;
    f.adjustments.curves.red.points = [[0, 0], [0.4, 0.6], [1, 1]];
    f.geometry.quarterTurns = 1;
    f.geometry.crop = { x: 0.1, y: 0.2, width: 0.6, height: 0.7 };
    r.longEdge = 3000;
    r.existing = 'overwrite';
    fake.pathExists.mockResolvedValue(true);
    const expected = structuredClone(f);
    const pending = deferred<void>();
    fake.ensureDir.mockReturnValue(pending.promise);
    const run = exportFrame(r, f, catalog, ['export_frame']);
    f.adjustments.exposure = 4;
    f.geometry.crop.width = 1;
    f.params.exposureCompensationEV = 3;
    f.decode.temperature = 2000;
    r.quality = 10;
    pending.resolve();
    expect(await run).toEqual({ kind: 'written', path: 'D:/out/image.jpg', width: 3000, height: 2000, carriesEdits: true });
    expect(fake.request).toHaveBeenCalledOnce();
    const [method, args, options] = fake.request.mock.calls[0]!;
    expect(method).toBe('export_frame');
    expect(args).toMatchObject({ session: 'editor', source_path: expected.path,
      params: fullDelta(expected.params, expected.gate), adjustments: expected.adjustments, geometry: expected.geometry,
      decode: { white_balance: { mode: 'custom', temperature_k: 6200, tint: 13 } },
      color_space: 'display-p3', format: 'jpeg', quality: 92, long_edge: 3000, overwrite: true,
      progress_id: expect.stringMatching(/^export-/) });
    expect(args.params).not.toHaveProperty('scene_latitude_active');
    expect(options).not.toHaveProperty('payload');
    expect(fake.open).not.toHaveBeenCalled();
  });
  it('uses source_path for a private job and exposes an empty session cancellation key', async () => {
    const f = frame(); delete f.session;
    const active = vi.fn();
    await exportFrame(recipe(), f, catalog, ['export_frame'], { active });
    expect(active).toHaveBeenNthCalledWith(1, { session: '', progressId: expect.any(String) });
    expect(fake.request.mock.calls[0]![1].session).toBeUndefined();
    expect(active).toHaveBeenLastCalledWith(null);
  });
  it('keeps skip policy and stops before submitting a cancelled job', async () => {
    const r = recipe(); r.existing = 'skip';
    fake.pathExists.mockResolvedValue(true);
    expect(await exportFrame(r, frame(), catalog, ['export_frame'])).toMatchObject({ kind: 'skipped' });
    expect(await exportFrame(r, frame(), catalog, ['export_frame'], { cancelled: () => true })).toEqual({ kind: 'cancelled' });
    expect(fake.request).not.toHaveBeenCalled();
  });
  it('reports a cancelled host job and clears its progress identity', async () => {
    let cancelled = false;
    fake.request.mockImplementation(async () => { cancelled = true; throw Object.assign(new Error('cancelled'), { code: 'cancelled' }); });
    const active = vi.fn();
    expect(await exportFrame(recipe(), frame(), catalog, ['export_frame'], { active, cancelled: () => cancelled })).toEqual({ kind: 'cancelled' });
    expect(active).toHaveBeenLastCalledWith(null);
  });
  it('does not send decode settings for a raster source', async () => {
    const f = frame(); f.path = 'D:/photos/photo.tif';
    await exportFrame(recipe(), f, catalog, ['export_frame']);
    expect(fake.request.mock.calls[0]![1].decode).toBeUndefined();
  });
  it('rejects a host reply containing a full image payload', async () => {
    fake.request.mockResolvedValue({ result: { path: 'x', width: 1, height: 1 }, payload: new Uint8Array(8) });
    expect(await exportFrame(recipe(), frame(), catalog, ['export_frame'])).toMatchObject({ kind: 'failed', message: expect.stringContaining('image data') });
  });
  it('runs density export in a separate fully configured session and closes it on failure', async () => {
    const r = recipe(); r.format = 'di'; r.existing = 'overwrite';
    fake.pathExists.mockResolvedValue(true);
    const f = frame(); f.params.exposureCompensationEV = 2;
    fake.request.mockRejectedValue(new Error('disk full'));
    expect(await exportFrame(r, f, catalog, ['export_di'])).toEqual({ kind: 'failed', message: 'disk full' });
    expect(fake.open).toHaveBeenCalledWith(f.path, fullDelta(f.params, f.gate), { white_balance: { mode: 'as_shot' } });
    expect(fake.request).toHaveBeenCalledWith('export_di', expect.objectContaining({ session: 'private-di', overwrite: true }), expect.anything());
    expect(fake.close).toHaveBeenCalledWith('private-di');
  });
});

describe('batch snapshots', () => {
  it('freezes selected unsaved edits before loading other sidecars, without loading the selected sidecar', async () => {
    const sidecar = structuredClone(newSidecar()); sidecar.adjustments.exposure = 1;
    const saved = structuredClone(newSidecar()); saved.params.filmStock = 'slide'; saved.params.scanFilm = false;
    saved.geometry.crop = { x: 0.1, y: 0, width: 0.8, height: 1 };
    saved.adjustments.saturation = 23;
    const pending = deferred<unknown>(); fake.sidecarLoad.mockReturnValue(pending.promise);
    const gate = structuredClone(ALL_FEATURES);
    const job = captureExportFrames(['other.NEF', 'current.NEF'], {
      path: 'current.NEF', sidecar, session: 'editor', native: { width: 6000, height: 4000 },
      dateTaken: '2020-01-02',
    }, catalog, gate, false);
    sidecar.adjustments.exposure = 4; sidecar.params.filmStock = 'changed'; gate.overscan = false;
    pending.resolve(encodeSidecar(saved));
    const frames = await job;
    expect(fake.sidecarLoad).toHaveBeenCalledExactlyOnceWith('other.NEF');
    expect(fake.probe).toHaveBeenCalledExactlyOnceWith('other.NEF');
    expect(frames[0]).toMatchObject({ path: 'other.NEF', frame: { session: undefined,
      params: { filmStock: 'slide', scanFilm: true }, adjustments: { saturation: 23 }, geometry: saved.geometry,
      dateTaken: '2026-10-01T12:00:00', gate: { overscan: true } } });
    expect(frames[1]).toMatchObject({ path: 'current.NEF', frame: { session: 'editor',
      adjustments: { exposure: 1 }, params: { filmStock: newSidecar().params.filmStock }, dateTaken: '2020-01-02' } });
    expect(saved.params.scanFilm).toBe(false);
    expect(fake.open).not.toHaveBeenCalled(); expect(fake.request).not.toHaveBeenCalled();
  });
  it('preserves a failed sidecar read instead of exporting defaults', async () => {
    fake.sidecarLoad.mockRejectedValueOnce(new Error('sidecar unavailable')).mockResolvedValueOnce(null);
    const frames = await captureExportFrames(['bad.NEF', 'new.NEF'], null, catalog, ALL_FEATURES, false);
    expect(frames[0]).toEqual({ path: 'bad.NEF', error: 'sidecar unavailable' });
    expect(frames[1]).toMatchObject({ path: 'new.NEF', frame: { params: { filmFormatMM: 36 } } });
    expect(fake.probe).toHaveBeenCalledOnce();
  });
  it('derives grain format from the same crop preference as the editor without mutating the sidecar', async () => {
    const sidecar = structuredClone(newSidecar());
    sidecar.geometry.crop = { x: 0, y: 0, width: 0.5, height: 0.5 };
    const current = { path: 'a.NEF', sidecar, native: { width: 6000, height: 4000 } };
    const frames = await captureExportFrames(['a.NEF'], current, catalog, ALL_FEATURES, true);
    expect(frames[0]).toMatchObject({ frame: { params: { filmFormatMM: 72 } } });
    expect(sidecar.params.filmFormatMM).toBe(36);
  });
  it('stops snapshot preparation without opening or exporting any frame', async () => {
    expect(await captureExportFrames(['a.NEF'], null, catalog, ALL_FEATURES, false, () => true)).toEqual([]);
    expect(fake.sidecarLoad).not.toHaveBeenCalled(); expect(fake.open).not.toHaveBeenCalled();
  });
});
