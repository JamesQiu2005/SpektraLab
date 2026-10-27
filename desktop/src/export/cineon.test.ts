import { beforeEach, expect, it, vi } from 'vitest';
import { ADJUSTMENTS_DEFAULT } from '@shared/adjustments';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { FILM_PARAMS_DEFAULT } from '@shared/params';
import { StockCatalog } from '@shared/stocks';
import { DEFAULT_RECIPES } from './recipes';
import { exportFrame } from './exporter';

const calls = vi.hoisted(() => ({
  cineon: vi.fn(async (_session: string, path: string) => ({ path, width: 2000, height: 1500 })),
  density: vi.fn(() => { throw new Error('legacy normalised density is not a Cineon file'); }),
}));
vi.mock('../host/client', () => ({ host: () => ({ exportCineon: calls.cineon, exportDi: calls.density }) }));
vi.mock('../platform', () => ({
  baseName: (p: string) => p.split('/').pop()!, dirName: () => '/pictures', joinPath: (...p: string[]) => p.join('/'),
  platform: () => ({ ensureDir: async () => {}, pathExists: async () => false }),
}));

beforeEach(() => vi.clearAllMocks());
const recipe = DEFAULT_RECIPES.find((r) => r.format === 'di')!;
const frame = {
  path: '/pictures/photo.ARW', session: 'actual-session', params: FILM_PARAMS_DEFAULT,
  adjustments: { ...ADJUSTMENTS_DEFAULT, exposure: 1 },
  geometry: { ...GEOMETRY_DEFAULT, crop: { x: 0.1, y: 0.2, width: 0.5, height: 0.6 }, quarterTurns: 1 },
  native: { width: 6000, height: 4000 },
};

it('a DI recipe uses raw Cineon with upstream geometry and excludes the finished grade', async () => {
  const result = await exportFrame(recipe, frame, new StockCatalog([]), ['export_cineon']);
  expect(result.kind).toBe('written');
  expect(calls.density).not.toHaveBeenCalled();
  expect(calls.cineon).toHaveBeenCalledWith('actual-session', expect.stringMatching(/_DI\.tif$/),
    expect.objectContaining({ geometry_crop_x: 0.1, geometry_crop_y: 0.2, geometry_crop_w: 0.5,
      geometry_crop_h: 0.6, geometry_quarter_turns: 1 }), false);
  expect(result).toMatchObject({ width: 2000, height: 1500, carriesEdits: false });
});

it('an older host fails clearly instead of substituting normalised density', async () => {
  const result = await exportFrame(recipe, frame, new StockCatalog([]), ['export_di']);
  expect(result).toMatchObject({ kind: 'failed', message: expect.stringMatching(/Cineon/) });
  expect(calls.density).not.toHaveBeenCalled();
  expect(calls.cineon).not.toHaveBeenCalled();
});
it('an incomplete pair refuses export before writing or encoding any file',async()=>{
  const result=await exportFrame(recipe,{...frame,pairComplete:false},new StockCatalog([]),['export_cineon']);
  expect(result).toMatchObject({kind:'failed',message:expect.stringMatching(/Both half-frame holes/)});
  expect(calls.cineon).not.toHaveBeenCalled();
});
