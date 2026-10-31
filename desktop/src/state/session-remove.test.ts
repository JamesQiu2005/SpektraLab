// Removing frames from the roll: the files stay, the roll forgets them, and
// an open frame that goes hands the canvas to its nearest neighbour.
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import type { HelloResult, HostState } from '@shared/protocol';
import type * as StocksModule from '@shared/stocks';
import type * as SessionModule from './session';
import { StockCatalog } from '@shared/stocks';
import { newSidecar } from '@shared/sidecar';
import type { FileEntry } from '../platform';

const fake = vi.hoisted(() => ({
  loadCatalog: vi.fn(),
  state: vi.fn(),
  load: vi.fn(),
  save: vi.fn(async (_path: string, _sidecar: unknown) => ''),
  open: vi.fn(async () => ({ session: 's2', width: 6, height: 4, kind: 'raw', metadata: { orientation: 1 } })),
  close: vi.fn(async () => {}),
  setParams: vi.fn(async () => ({})),
  render: vi.fn(async () => ({ width: 6, height: 4, data: new Uint8Array(96), colorSpace: 'sRGB', tier: 'preview', reprinted: false, ms: 1 })),
}));
vi.mock('@shared/stocks', async (original) => ({ ...(await original<typeof StocksModule>()), loadCatalog: fake.loadCatalog }));
vi.mock('../host/client', () => ({
  HostCallError: class extends Error {},
  host: () => ({
    setParams: fake.setParams, render: fake.render, open: fake.open, close: fake.close,
    thumbnail: async () => { throw new Error('No fixture thumbnail'); },
    onState: () => {}, state: fake.state,
  }),
}));
vi.mock('../platform', () => ({
  platform: () => ({
    log: () => {}, sidecarLoad: fake.load, sidecarSave: fake.save,
    listImages: async () => [], expandPaths: async () => [], setTitle: async () => {},
    onOpenPaths: () => {}, onDrop: () => {}, takeLaunchPaths: async () => [],
  }),
  baseName: (p: string) => p.split(/[\\/]/).pop() ?? p,
  dirName: (p: string) => p.replace(/[\\/][^\\/]*$/, ''),
}));

const catalog = new StockCatalog([{ id: 'kodak_portra_400', name: 'Portra 400', stage: 'filming', use: 'still', type: 'negative', hasPreviewLUT: false }]);
const ready = { phase: 'ready', hello: {} as HelloResult } as const satisfies HostState;
const roll = (): FileEntry[] => ['a', 'b', 'c', 'd'].map((n, i) => ({ path: `/owned/${n}.ARW`, name: `${n}.ARW`, size: i, mtime_ms: 0 }));
let session: typeof SessionModule;
const paths = () => session.sessionStore.getState().frames.map((f) => f.path);

beforeEach(async () => {
  vi.useFakeTimers();
  vi.spyOn(performance, 'now').mockReturnValue(10_000);
  vi.clearAllMocks();
  vi.resetModules();
  vi.stubGlobal('window', { addEventListener: vi.fn() });
  fake.state.mockResolvedValue(ready);
  fake.load.mockResolvedValue(null);
  fake.loadCatalog.mockResolvedValue(catalog);
  session = await import('./session');
  session.sessionStore.setState({
    catalog, hostState: ready, folder: '/owned', frames: roll(), selection: '/owned/b.ARW', picked: ['/owned/b.ARW'],
    engineSession: 's1', nativeSize: { width: 6, height: 4 }, sidecar: newSidecar(), undo: [], redo: [], batchExporting: false,
  });
});
afterEach(() => { vi.clearAllTimers(); vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); });

describe('removeFrames', () => {
  it('drops a frame that is not open and keeps the canvas where it is', async () => {
    await session.removeFrames(['/owned/d.ARW']);
    expect(paths()).toEqual(['/owned/a.ARW', '/owned/b.ARW', '/owned/c.ARW']);
    expect(session.sessionStore.getState().selection).toBe('/owned/b.ARW');
    expect(session.sessionStore.getState().engineSession).toBe('s1');
    expect(fake.close).not.toHaveBeenCalled();
  });
  it('hands the canvas to the next frame when the open one goes, and to the previous one at the end', async () => {
    await session.removeFrames(['/owned/b.ARW']);
    expect(paths()).toEqual(['/owned/a.ARW', '/owned/c.ARW', '/owned/d.ARW']);
    expect(fake.close).toHaveBeenCalledOnce();
    expect(fake.open).toHaveBeenCalledOnce();
    expect((fake.open.mock.calls[0] as unknown[])[0]).toBe('/owned/c.ARW');
    expect(session.sessionStore.getState().selection).toBe('/owned/c.ARW');
    await session.removeFrames(['/owned/c.ARW', '/owned/d.ARW']);
    expect(paths()).toEqual(['/owned/a.ARW']);
    expect(session.sessionStore.getState().selection).toBe('/owned/a.ARW');
  });
  it('leaves an empty roll with no selection', async () => {
    await session.removeFrames(roll().map((f) => f.path));
    expect(paths()).toEqual([]);
    expect(session.sessionStore.getState().selection).toBeNull();
    expect(session.sessionStore.getState().picked).toEqual([]);
    expect(fake.open).not.toHaveBeenCalled();
  });
  it('takes the picked set from a menu command, else the open frame', async () => {
    session.sessionStore.setState({ picked: ['/owned/a.ARW', '/owned/d.ARW'] });
    await session.removeSelectedFrames();
    expect(paths()).toEqual(['/owned/b.ARW', '/owned/c.ARW']);
    expect(session.sessionStore.getState().picked).toEqual([]);
    expect(session.sessionStore.getState().selection).toBe('/owned/b.ARW');
    await session.removeSelectedFrames();
    expect(paths()).toEqual(['/owned/c.ARW']);
    expect(session.sessionStore.getState().selection).toBe('/owned/c.ARW');
  });
  it('does nothing during a batch export or for unknown paths', async () => {
    session.sessionStore.setState({ batchExporting: true });
    await session.removeFrames(['/owned/a.ARW']);
    expect(paths()).toHaveLength(4);
    session.sessionStore.setState({ batchExporting: false });
    await session.removeFrames(['/elsewhere/z.ARW']);
    expect(paths()).toHaveLength(4);
    expect(fake.close).not.toHaveBeenCalled();
  });
});
