// The Library on the mock helper: the spklib methods the store calls, the
// picks, the read-only rule and what Develop ↵ hands the editor.

import { beforeEach, describe, expect, it, vi } from 'vitest';
const pickFolder = vi.hoisted(() => vi.fn<() => Promise<string | null>>());
const pathExists = vi.hoisted(() => vi.fn<(path: string) => Promise<boolean>>());
vi.mock('../platform', () => ({
  platform: () => ({ listImages: async () => [], pickFolder, pathExists, appPaths: async () => ({}), pickFiles: async () => [] }),
}));
import { MOCK_LIBRARY_PATHS, MockLibrary } from './mock';
import { LibraryError, type Opened } from './client';
import { LIBRARY_INITIAL, addFolder, closeLibrary, chooseCollection, developTargets, libraryStore, locateOriginalFolder, openCaptureOneDialog, openLibrary, pick, refresh, setLibraryClient, setRating, setSearch } from './store';

let mock: MockLibrary;
beforeEach(() => {
  pickFolder.mockReset().mockResolvedValue(null);
  pathExists.mockReset().mockResolvedValue(true);
  mock = new MockLibrary();
  setLibraryClient(mock);
  libraryStore.setState({ ...LIBRARY_INITIAL, recent: [] });
});

describe('the library store', () => {
  it('opens a catalog through library.open and lists its collections and images', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    const s = libraryStore.getState();
    expect(mock.calls.slice(0, 3)).toEqual(['library.open', 'collections.list', 'folders.list']);
    expect(s.source).toMatchObject({ kind: 'catalog', readOnly: false, info: { name: 'Darkroom 2026' } });
    expect(s.images.length).toBe(28);
    expect(s.offline).toEqual(['travel']);
    expect(s.recent[0]).toMatchObject({ name: 'Darkroom 2026', kind: 'catalog' });
  });
  it('refreshes folder availability without reopening the catalog or adding a probe to search', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    const source = libraryStore.getState().source;
    const call = mock.call.bind(mock);
    let online = false;
    const folderCalls = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      if (method !== 'folders.list') return call<T>(method, params);
      return { folders: [{ folder: 'different-helper-folder-id', path: 'F:/', online }] } as T;
    });
    await refresh({ checkFolders: true });
    expect(libraryStore.getState().offline).toEqual(['travel']);
    online = true;
    await setSearch('DSCF');
    expect(folderCalls.mock.calls.filter(([method]) => method === 'folders.list')).toHaveLength(1);
    expect(libraryStore.getState().offline).toEqual(['travel']);
    await refresh({ checkFolders: true });
    expect(libraryStore.getState().offline).toEqual([]);
    expect(libraryStore.getState().source).toBe(source);
    online = false;
    await refresh({ checkFolders: true });
    expect(libraryStore.getState().offline).toEqual(['travel']);
  });
  it('a Capture One catalog is probed and linked, and is read-only: ratings are refused without a call', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.captureOne);
    expect(mock.calls).toContain('capture_one.probe');
    expect(mock.calls).toContain('capture_one.link');
    expect(libraryStore.getState().source).toMatchObject({ kind: 'captureOneCatalog', readOnly: true });
    pick(libraryStore.getState().images[0]!.uuid);
    const before = mock.calls.length;
    await setRating(3);
    expect(mock.calls.length).toBe(before);
    expect(libraryStore.getState().message).toBe('Ratings are set in Capture One');
  });
  it('links a suffixless Windows Capture One folder and remembers the original source for reopening', async () => {
    const source = 'D:/图库/Windows Archive';
    const mirror = 'C:/v2/Libraries/Linked/document-id.spkcatalog';
    pickFolder.mockResolvedValueOnce(source);
    const backend = mock.call.bind(mock);
    const call = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      if (method === 'capture_one.probe' && params.path === source)
        return backend<T>(method, { path: MOCK_LIBRARY_PATHS.captureOne });
      if (method === 'capture_one.link' && params.source === source) {
        const linked = await backend<Opened>(method, { source: MOCK_LIBRARY_PATHS.captureOne });
        return { ...linked, info: { ...linked.info, path: mirror, origin: { ...linked.info.origin!, path: source } } } as T;
      }
      return backend<T>(method, params);
    });

    await openCaptureOneDialog();
    expect(libraryStore.getState().source).toMatchObject({ kind: 'captureOneCatalog', readOnly: true, info: { path: source }, catalogPath: mirror });
    const recent = libraryStore.getState().recent[0]!;
    expect(recent).toMatchObject({ kind: 'captureOneCatalog', path: source });
    await closeLibrary();
    await openLibrary(recent.path);
    expect(libraryStore.getState().source).toMatchObject({ kind: 'captureOneCatalog', readOnly: true, info: { path: source } });
    expect(call.mock.calls.filter(([method]) => method === 'capture_one.link')).toEqual([
      ['capture_one.link', { source }], ['capture_one.link', { source }],
    ]);
  });
  it('picks like File Explorer (alone, Ctrl, Shift) and Develop ↵ hands the picked frames over, the focused one first opened', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    const ids = libraryStore.getState().images.map((i) => i.uuid);
    pick(ids[0]!);
    pick(ids[3]!, { shift: true });
    expect(libraryStore.getState().picked).toEqual(ids.slice(0, 4));
    pick(ids[1]!, { ctrl: true });
    expect(libraryStore.getState().picked).toEqual([ids[0], ids[2], ids[3]]);
    const t = developTargets();
    expect(t.paths).toHaveLength(3);
    // The focus (the last Ctrl+click) left the pick, so the first picked frame opens.
    expect(t.open).toBe(libraryStore.getState().images[0]!.path);
    pick(ids[3]!, { ctrl: true });
    pick(ids[3]!, { ctrl: true });
    expect(developTargets().open).toBe(libraryStore.getState().images[3]!.path);
  });
  it('offline images are not handed to the editor', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    await chooseCollection('travel');
    expect(libraryStore.getState().images.every((i) => i.exists === false)).toBe(true);
    expect(developTargets().paths).toEqual([]);
  });
  it('locates a Capture One original in the mirror, keeping its UUID and selection', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.captureOne);
    const offline = libraryStore.getState().images.find((image) => image.exists === false)!;
    pick(offline.uuid);
    const replacement = 'D:\\照片\\移动后的原片';
    pickFolder.mockResolvedValueOnce(replacement);
    pathExists.mockResolvedValueOnce(false);
    await locateOriginalFolder(offline);
    expect(mock.calls).not.toContain('location.relink');
    expect(libraryStore.getState().message).toBe('That folder does not contain the original.');

    pickFolder.mockResolvedValueOnce(replacement);
    await locateOriginalFolder(offline);

    const state = libraryStore.getState();
    expect(state).toMatchObject({ focus: offline.uuid, picked: [offline.uuid], source: { readOnly: true } });
    expect(state.images.find((image) => image.uuid === offline.uuid)).toMatchObject({
      exists: true, path: `${replacement.replaceAll('\\', '/')}/${offline.file_name}`, rating: offline.rating,
    });
    expect(mock.calls.filter((method) => method === 'location.relink')).toHaveLength(1);
    expect(mock.calls).not.toContain('meta.set');
  });
  it('discards a locate dialog result after the user switches libraries', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.captureOne);
    const offline = libraryStore.getState().images.find((image) => image.exists === false)!;
    let choose!: (path: string) => void;
    pickFolder.mockImplementationOnce(() => new Promise((resolve) => { choose = resolve; }));
    const locating = locateOriginalFolder(offline);
    expect(libraryStore.getState().locating).toBe(true);
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    choose('D:/Originals');
    await locating;
    expect(libraryStore.getState()).toMatchObject({ locating: false, source: { kind: 'catalog' } });
    expect(mock.calls).not.toContain('location.relink');
  });
  it.each([
    String.raw`\\?\D:\图片\移走的原片`,
    String.raw`\\?\UNC\NAS\照片\移动后`,
  ])('keeps backslashes in the filesystem check for an extended Windows folder', async (folder) => {
    await openLibrary(MOCK_LIBRARY_PATHS.captureOne);
    const offline = libraryStore.getState().images.find((image) => image.exists === false)!;
    pickFolder.mockResolvedValueOnce(`${folder}\\`);
    pathExists.mockImplementationOnce(async (path) => path === `${folder}\\${offline.file_name}`);
    await locateOriginalFolder(offline);
    expect(pathExists).toHaveBeenCalledWith(`${folder}\\${offline.file_name}`);
    expect(mock.calls).toContain('location.relink');
  });
  it('a rating on a writable source is meta.set; a folder source is a library of its own', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    pick(libraryStore.getState().images[1]!.uuid);
    await setRating(5);
    expect(mock.calls).toContain('meta.set');
    expect(libraryStore.getState().images[1]!.rating).toBe(5);
    await closeLibrary();
    expect(libraryStore.getState().source).toBeNull();
    await addFolder('E:/Photos/2026-10 Coast');
    expect(libraryStore.getState().source).toMatchObject({ kind: 'folder', info: { name: '2026-10 Coast' } });
    expect(libraryStore.getState().images.length).toBe(10);
  });
  it('an unavailable helper is said, not swallowed', async () => {
    setLibraryClient(new MockLibrary({ helper: 'stopped' }));
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    expect(libraryStore.getState()).toMatchObject({ phase: 'failed', message: 'The library helper is not running.' });
  });

  it('reopens a recent photo folder with the same images and ratings', async () => {
    await addFolder('E:/Photos/Win-08');
    const state = libraryStore.getState();
    const first = state.images[0]!;
    const recent = state.recent[0]!;
    expect(state.source?.info.counts.images).toBe(10);
    expect(recent.catalogPath).toContain('.spkcatalog');
    pick(first.uuid);
    await setRating(4);
    await closeLibrary();
    await openLibrary(recent.path);
    expect(libraryStore.getState().images.find((image) => image.uuid === first.uuid)?.rating).toBe(4);
    expect(libraryStore.getState().source).toMatchObject({ kind: 'folder', catalogPath: recent.catalogPath });
    expect(mock.calls.filter((call) => call === 'folders.add')).toHaveLength(1);
  });

  it('keeps the latest search result when an older request completes afterwards', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    const first = libraryStore.getState().images[0]!;
    pick(first.uuid);
    const call = mock.call.bind(mock);
    let release!: () => void;
    const stalled = new Promise<void>((resolve) => { release = resolve; });
    const pause = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      if (method === 'images.list' && (params.filter as { text?: string } | undefined)?.text === first.file_name) await stalled;
      return call<T>(method, params);
    });
    try {
      const older = setSearch(first.file_name);
      await setSearch('no such photo');
      release();
      await older;
      expect(libraryStore.getState()).toMatchObject({ search: 'no such photo', images: [], focus: null, anchor: null, picked: [] });
    } finally {
      release();
      pause.mockRestore();
    }
  });

  it('does not replace a newly opened source with a slower earlier open', async () => {
    const call = mock.call.bind(mock);
    let release!: () => void;
    const stalled = new Promise<void>((resolve) => { release = resolve; });
    const pause = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      if (method === 'library.open') await stalled;
      return call<T>(method, params);
    });
    try {
      const older = openLibrary(MOCK_LIBRARY_PATHS.catalog);
      await openLibrary(MOCK_LIBRARY_PATHS.captureOne);
      release();
      await older;
      const state = libraryStore.getState();
      expect(state.source?.kind).toBe('captureOneCatalog');
      expect(state.recent.map((entry) => entry.kind)).toEqual(['captureOneCatalog']);
    } finally {
      release();
      pause.mockRestore();
    }
  });

  it('reopens the same folder once for concurrent stale reads and retains focus', async () => {
    await addFolder('E:/Photos/Win-09');
    const { source, images } = libraryStore.getState();
    pick(images[0]!.uuid);
    await mock.call('library.close', { library: source!.handle });
    const call = mock.call.bind(mock);
    const spy = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      if (params.library === source!.handle) throw new LibraryError('stale_library', 'old launch');
      return call<T>(method, params);
    });
    try {
      await Promise.all([refresh(), refresh()]);
      expect(spy.mock.calls.filter(([method]) => method === 'library.open')).toEqual([['library.open', { path: source!.catalogPath }]]);
      const recovered = libraryStore.getState();
      expect(recovered.source?.handle).not.toBe(source?.handle);
      expect(recovered.source?.info.uuid).toBe(source?.info.uuid);
      expect(recovered.focus).toBe(images[0]!.uuid);
      expect(recovered.images.map((image) => image.uuid)).toEqual(images.map((image) => image.uuid));
    } finally { spy.mockRestore(); }
  });

  it('does not retry a rating whose submission result is unknown', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    const id = libraryStore.getState().images[0]!.uuid;
    pick(id);
    const call = mock.call.bind(mock);
    const spy = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      const result = await call<T>(method, params);
      if (method === 'meta.set') throw new LibraryError('unavailable', 'connection lost after submission');
      return result;
    });
    try {
      await setRating(4);
      expect(spy.mock.calls.filter(([method]) => method === 'meta.set')).toHaveLength(1);
      expect(libraryStore.getState().images.find((row) => row.uuid === id)?.rating).toBe(4);
      expect(libraryStore.getState().message).toContain('could not be confirmed');
    } finally { spy.mockRestore(); }
  });

  it('refuses to rebind a stale write to a different catalogue at the same path', async () => {
    await openLibrary(MOCK_LIBRARY_PATHS.catalog);
    const source = libraryStore.getState().source!;
    pick(libraryStore.getState().images[0]!.uuid);
    const call = mock.call.bind(mock);
    const spy = vi.spyOn(mock, 'call').mockImplementation(async <T>(method: string, params: Record<string, unknown> = {}) => {
      if (method === 'meta.set') throw new LibraryError('stale_library', 'old launch');
      if (method === 'library.open') return { library: 'new-launch', info: { ...source.info, uuid: 'different' } } as T;
      return call<T>(method, params);
    });
    try {
      await setRating(4);
      expect(spy.mock.calls.filter(([method]) => method === 'meta.set')).toHaveLength(1);
      expect(libraryStore.getState().source).toBe(source);
      expect(libraryStore.getState().message).toContain('different library');
    } finally { spy.mockRestore(); }
  });
});
