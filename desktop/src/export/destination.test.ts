// destination(): where an export lands, on the desktop and on Android's shared storage.
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type * as PlatformModule from '../platform';

const files = new Set<string>(); // desktop paths that exist
const shared = new Set<string>(); // "dir/name" the app saved in shared storage
const published: Array<{ path: string; dir: string; name: string; mime: string; overwrite: boolean }> = [];
let android = false;
const renamed = new Map<string, string>(); // names Android stores differently (another app's file of that name)
const copies: Array<{ image: string; dir: string; name: string; overwrite: boolean }> = [];

vi.mock('../host/client', () => ({ host: () => ({}) }));
vi.mock('../platform', async (orig) => {
  const real = await orig<typeof PlatformModule>();
  return {
    ...real,
    platform: () => ({
      ensureDir: async () => {},
      pathExists: async (p: string) => files.has(p),
      exportOriginal: async (image: string, dir: string, name: string, overwrite: boolean) => {
        copies.push({ image, dir, name, overwrite });
        return [`${dir}/${name}`, `${dir}/B.ARW`, `${dir}/${name}.spektra.json`];
      },
      shared: android
        ? {
            staging: async () => '/data/files/Exporting',
            exists: async (dir: string, name: string) => shared.has(`${dir}/${name}`),
            publish: async (path: string, dir: string, name: string, mime: string, overwrite: boolean) => {
              published.push({ path, dir, name, mime, overwrite });
              return `${dir}/${renamed.get(name) ?? name}`;
            },
          }
        : undefined,
    }),
  };
});

import { FILM_PARAMS_DEFAULT } from '@shared/params';
import { ADJUSTMENTS_DEFAULT } from '@shared/adjustments';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { destination, exportFrame, rgba16, SHARED_PICTURES } from './exporter';
import { DEFAULT_RECIPES, extensionOf } from './recipes';

beforeEach(() => {
  files.clear();
  shared.clear();
  published.length = 0;
  copies.length = 0;
  renamed.clear();
  android = false;
});

describe('export destination', () => {
  it('desktop: the target itself, numbered when it exists', async () => {
    files.add('/photos/a.jpg');
    const d = await destination('/photos', 'a', 'jpg', 'addSuffix', SHARED_PICTURES);
    if ('skipped' in d) throw new Error('skipped');
    expect(d.write).toBe('/photos/a-2.jpg');
    expect(await d.finish(d.write)).toBe('/photos/a-2.jpg');
    expect(await destination('/photos', 'a', 'jpg', 'skip', SHARED_PICTURES)).toEqual({ skipped: '/photos/a.jpg' });
  });

  it('android: written in app storage, then published to Pictures/Develop under its own name', async () => {
    android = true;
    shared.add('Pictures/Develop/a.jpg');
    const d = await destination('/ignored', 'a', 'jpg', 'addSuffix', SHARED_PICTURES);
    if ('skipped' in d) throw new Error('skipped');
    expect(d.write).toMatch(/^\/data\/files\/Exporting\/[^/]+\/a-2\.jpg$/); // a folder of its own
    expect(await d.finish(d.write)).toBe('Pictures/Develop/a-2.jpg');
    expect(published[0]).toEqual({ path: d.write, dir: 'Pictures/Develop', name: 'a-2.jpg', mime: 'image/jpeg', overwrite: false });
  });

  it('android: overwrite replaces the saved file, skip leaves it', async () => {
    android = true;
    shared.add('Pictures/Develop/Trip/a.tif');
    const d = await destination('', 'a', 'tif', 'overwrite', 'Pictures/Develop/Trip');
    if ('skipped' in d) throw new Error('skipped');
    await d.finish(d.write);
    expect(published[0]).toMatchObject({ name: 'a.tif', mime: 'image/tiff', overwrite: true });
    expect(await destination('', 'a', 'tif', 'skip', 'Pictures/Develop/Trip')).toEqual({ skipped: 'Pictures/Develop/Trip/a.tif' });
  });
});

describe('Original + edits', () => {
  const original = DEFAULT_RECIPES.find((r) => r.format === 'original')!;
  const frame = { path: '/photos/A.ARW', session: '', params: FILM_PARAMS_DEFAULT, adjustments: ADJUSTMENTS_DEFAULT, geometry: GEOMETRY_DEFAULT, native: { width: 0, height: 0 } };
  const catalog = { stock: () => undefined } as never;

  it("keeps the photograph's own extension and name", () => {
    expect(extensionOf(original, '/photos/A.ARW')).toBe('ARW');
    expect(extensionOf(original, '/photos/x.dng')).toBe('dng');
    expect(original.naming.tokens).toEqual(['originalName']);
  });

  it('desktop: copies into the subfolder beside the original', async () => {
    const o = await exportFrame(original, frame, catalog, []);
    expect(o).toEqual({ kind: 'written', path: '/photos/Develop/A.ARW', width: 0, height: 0, carriesEdits: true });
    expect(copies).toEqual([{ image: '/photos/A.ARW', dir: '/photos/Develop', name: 'A.ARW', overwrite: false }]);
    expect(published).toEqual([]);
  });

  it('android: all three files to Download/Develop, the edits named after the copy as stored', async () => {
    android = true;
    renamed.set('A.ARW', 'A (1).ARW');
    const o = await exportFrame(original, frame, catalog, []);
    expect(o).toMatchObject({ kind: 'written', path: 'Download/Develop/Develop/A (1).ARW' });
    expect(published.map((p) => [p.dir, p.name, p.mime])).toEqual([
      ['Download/Develop/Develop', 'A.ARW', 'application/octet-stream'],
      ['Download/Develop/Develop', 'B.ARW', 'application/octet-stream'],
      ['Download/Develop/Develop', 'A (1).ARW.spektra.json', 'application/json'],
    ]);
  });
});

describe('rgba16', () => {
  it('reads the pixels in place at an even offset and copies them at an odd one', () => {
    const buf = new Uint8Array(1 + 16 + 1);
    for (let i = 0; i < buf.length; i++) buf[i] = i;
    const even = rgba16(buf.subarray(2, 10), 1, 1);
    expect(even.buffer).toBe(buf.buffer);
    expect(even[0]).toBe(2 | (3 << 8));
    const odd = rgba16(buf.subarray(1, 9), 1, 1);
    expect(odd.buffer).not.toBe(buf.buffer);
    expect(Array.from(odd)).toEqual([1 | (2 << 8), 3 | (4 << 8), 5 | (6 << 8), 7 | (8 << 8)]);
  });
});
