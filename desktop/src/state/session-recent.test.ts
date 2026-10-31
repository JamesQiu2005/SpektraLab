// Opening a folder, by the picker or whole at launch/drop, puts it in the
// recent list; opening a single file does not.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult, HostState } from '@shared/protocol';
import type * as StocksModule from '@shared/stocks';
import type * as SessionModule from './session';
import type * as SettingsModule from './settings';
import { StockCatalog } from '@shared/stocks';
import type { FileEntry } from '../platform';

const fake = vi.hoisted(() => ({
  loadCatalog: vi.fn(),
  state: vi.fn(),
  listImages: vi.fn<(dir: string) => Promise<FileEntry[]>>(),
  expandPaths: vi.fn<(paths: string[]) => Promise<FileEntry[]>>(),
  open: vi.fn(async () => ({ session: 's1', width: 6, height: 4, kind: 'raw', metadata: { orientation: 1 } })),
}));
vi.mock('@shared/stocks', async (original) => ({ ...(await original<typeof StocksModule>()), loadCatalog: fake.loadCatalog }));
vi.mock('../host/client', () => ({
  HostCallError: class extends Error {},
  host: () => ({
    open: fake.open, close: async () => {}, setParams: async () => ({}),
    render: async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'sRGB', tier: 'preview', reprinted: false, ms: 1 }),
    thumbnail: async () => { throw new Error('No fixture thumbnail'); },
    onState: () => {}, state: fake.state,
  }),
}));
vi.mock('../platform', () => ({
  platform: () => ({
    log: () => {}, sidecarLoad: async () => null, sidecarSave: async () => '',
    listImages: fake.listImages, expandPaths: fake.expandPaths, setTitle: async () => {},
    onOpenPaths: () => {}, onDrop: () => {}, takeLaunchPaths: async () => [],
  }),
  baseName: (p: string) => p.split(/[\\/]/).pop() ?? p,
  dirName: (p: string) => p.replace(/[\\/][^\\/]*$/, ''),
}));

const catalog = new StockCatalog([{ id: 'kodak_portra_400', name: 'Portra 400', stage: 'filming', use: 'still', type: 'negative', hasPreviewLUT: false }]);
const ready = { phase: 'ready', hello: {} as HelloResult } as const satisfies HostState;
const entries = (dir: string): FileEntry[] => ['a', 'b'].map((n, i) => ({ path: `${dir}/${n}.ARW`, name: `${n}.ARW`, size: i, mtime_ms: 0 }));
let session: typeof SessionModule;
let settings: typeof SettingsModule;

beforeEach(async () => {
  vi.useFakeTimers();
  vi.spyOn(performance, 'now').mockReturnValue(10_000);
  vi.clearAllMocks();
  vi.resetModules();
  vi.stubGlobal('window', { addEventListener: vi.fn() });
  fake.state.mockResolvedValue(ready);
  fake.loadCatalog.mockResolvedValue(catalog);
  fake.listImages.mockImplementation(async (dir) => entries(dir));
  fake.expandPaths.mockImplementation(async (paths) => paths.flatMap((p) => (/\.[a-z0-9]+$/i.test(p)
    ? [{ path: p, name: p.split('/').pop()!, size: 1, mtime_ms: 0 }] : entries(p))));
  settings = await import('./settings');
  session = await import('./session');
  session.sessionStore.setState({ catalog, hostState: ready });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('recent folders', () => {
  it('remembers a folder opened with the picker, newest first', async () => {
    await session.openFolder('/photos/roll 1');
    await session.openFolder('/photos/roll 2');
    await session.openFolder('/photos/roll 1');
    expect(settings.settingsStore.getState().recentFolders).toEqual(['/photos/roll 1', '/photos/roll 2']);
    expect(settings.settingsStore.getState().lastFolder).toBe('/photos/roll 1');
  });
  it('remembers a folder that came in whole, but not a single photograph', async () => {
    await session.openPaths(['/photos/roll 3']);
    expect(settings.settingsStore.getState().recentFolders).toEqual(['/photos/roll 3']);
    await session.openPaths(['/photos/roll 4/a.ARW']);
    expect(settings.settingsStore.getState().recentFolders).toEqual(['/photos/roll 3']);
    expect(session.sessionStore.getState().frames.map((f) => f.path)).toEqual(['/photos/roll 4/a.ARW']);
  });
  it('forgets the list on request', async () => {
    await session.openFolder('/photos/roll 1');
    settings.forgetRecentFolders();
    expect(settings.settingsStore.getState().recentFolders).toEqual([]);
  });
});
