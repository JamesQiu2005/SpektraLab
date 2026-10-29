import { beforeEach, describe, expect, it, vi } from 'vitest';
import { Workspace } from './workspace';
import { newSidecar, encodeSidecar } from '../src/shared/sidecar';
import { GEOMETRY_DEFAULT } from '../src/shared/geometry';
import { StockCatalog } from '../src/shared/stocks';
import { DEFAULT_RECIPES } from '../src/export/recipes';
import { newPair } from '../src/shared/pair';
import type * as PlatformModule from '../src/platform';
import type * as FsModule from 'node:fs/promises';

const fake = vi.hoisted(() => ({ call: vi.fn(), result: vi.fn(), request: vi.fn(), ensureDir: vi.fn(), pathExists: vi.fn() }));
vi.mock('./io', () => ({
  FileService: class { call = fake.call; }, NativeHost: class { result = fake.result; request = fake.request; },
  absolute: (p: string) => p, here: 'D:/agent',
}));
vi.mock('node:fs/promises', async (original) => ({
  ...await original<typeof FsModule>(), stat: vi.fn(async () => ({ size: 10, mtimeMs: 1 })),
}));
vi.mock('../src/host/client', () => ({ host: () => ({ transport: { request: fake.request } }) }));
vi.mock('../src/platform', async (original) => ({
  ...await original<typeof PlatformModule>(), platform: () => ({ ensureDir: fake.ensureDir, pathExists: fake.pathExists, log: vi.fn() }),
}));
const catalog = new StockCatalog([
  { id: 'film', name: 'Film', stage: 'filming', use: 'still', hasPreviewLUT: false },
  { id: 'paper', name: 'Paper', stage: 'printing', use: 'still', hasPreviewLUT: false },
]);
let saved = structuredClone(newSidecar()), supportsNoFilm = true;
const path = 'D:/photos/a.NEF';
function workspace() { const w = new Workspace(); w.catalog = catalog; return w; }
beforeEach(() => {
  vi.resetAllMocks(); supportsNoFilm = true;
  saved = structuredClone(newSidecar()); saved.noFilm = true;
  saved.params.filmStock = 'film'; saved.params.printStock = 'paper';
  saved.params.filmEdge.active = true; saved.params.dateBack.active = true;
  saved.geometry.crop = { x: .1, y: .1, width: .7, height: .6 }; saved.geometry.quarterTurns = 1;
  saved.adjustments.exposure = .75;
  fake.call.mockImplementation(async (method: string) => {
    if (method === 'rendering') return { recalculateEffectsAfterCrop: false, diBlueCompensation: false };
    if (method === 'sidecar_load') return encodeSidecar(saved);
    if (method === 'recipes') return DEFAULT_RECIPES;
    return undefined;
  });
  fake.result.mockImplementation(async (method: string) => {
    if (method === 'hello') return { capabilities: { backend: {} }, view_options: supportsNoFilm ? ['no_film'] : [], methods: ['render_view', 'export_frame', 'export_cineon'] };
    if (method === 'probe') return { width: 6000, height: 4000, metadata: {} };
    if (method === 'open') return { session: 'agent', width: 6000, height: 4000 };
    return {};
  });
  fake.request.mockResolvedValue({ result: { path: 'D:/out/export.tif', width: 3000, height: 2000 }, payload: new Uint8Array() });
  fake.pathExists.mockResolvedValue(false);
});

describe('agent saved display mode', () => {
  it('reads capability and carries saved bypass, post grade and photo geometry through develop and preview', async () => {
    const w = workspace(); await w.start(); expect(w.gate.noFilm).toBe(true);
    await w.call('preview_image', { path, output: 'D:/out/preview.jpg' });
    expect(w.gate.noFilm).toBe(true);
    for (const method of ['render_view', 'export_frame']) {
      expect(fake.result.mock.calls.find(([name]) => name === method)?.[1]).toMatchObject({ no_film: true,
        geometry: saved.geometry, source_geometry: GEOMETRY_DEFAULT, adjustments: { exposure: .75 } });
    }
  });

  it('exports saved bypass through the same frozen exporter contract', async () => {
    await workspace().call('export_image', { path });
    expect(fake.request.mock.calls[0]?.[0]).toBe('export_frame');
    expect(fake.request.mock.calls[0]?.[1]).toMatchObject({ no_film: true,
      geometry: saved.geometry, source_geometry: GEOMETRY_DEFAULT, adjustments: { exposure: .75 } });
  });

  it('refuses ordinary preview and export on an old host before any render or output write', async () => {
    supportsNoFilm = false;
    await expect(workspace().call('preview_image', { path, output: 'D:/out/preview.jpg' })).rejects.toThrow(/without film simulation/);
    await expect(workspace().call('export_image', { path })).rejects.toThrow(/without film simulation/);
    expect(fake.result.mock.calls.some(([method]) => method === 'render_view' || method === 'export_frame')).toBe(false);
    expect(fake.ensureDir).not.toHaveBeenCalled(); expect(fake.request).not.toHaveBeenCalled();
  });

  it('refuses DI while bypass is saved', async () => {
    supportsNoFilm = false;
    await expect(workspace().call('export_image', { path, recipe: 'Digital Intermediate' })).rejects.toThrow('Digital Intermediate');
    expect(fake.request).not.toHaveBeenCalled();
  });

  it('rejects saved bypass for a pair before trying to open it', async () => {
    const w = workspace(); await w.load(path); w.pair = newPair('D:/photos');
    await expect(w.develop()).rejects.toThrow(/half-frame/);
    expect(fake.result.mock.calls.some(([method]) => method === 'open_pair' || method === 'render_view')).toBe(false);
  });

  it('preserves saved bypass for ordinary patches and restores film when a stock is selected', async () => {
    const w = workspace(); await w.call('edit_image', { path, patch: { adjustments: { exposure: 1 } }, preview: false });
    expect(w.sidecar.noFilm).toBe(true);
    expect(fake.call.mock.calls.find(([method]) => method === 'sidecar_save')?.[1].value.noFilm).toBe(true);
    fake.call.mockClear(); supportsNoFilm = false; w.engine = null;
    await w.call('edit_image', { path, patch: { params: { filmStock: 'film' } }, preview: false });
    expect(w.sidecar.noFilm).toBe(false);
    expect(fake.call.mock.calls.find(([method]) => method === 'sidecar_save')?.[1].value).not.toHaveProperty('noFilm');
    expect(fake.result.mock.calls.filter(([method]) => method === 'render_view').at(-1)?.[1]).not.toHaveProperty('no_film');
  });
});
