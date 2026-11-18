// The Library on the mock helper: the spklib methods the store calls, the
// picks, the read-only rule and what Develop ↵ hands the editor.

import { beforeEach, describe, expect, it, vi } from 'vitest';
vi.mock('../platform', () => ({
  platform: () => ({ listImages: async () => [], pickFolder: async () => null, appPaths: async () => ({}), pickFiles: async () => [] }),
}));
import { MOCK_LIBRARY_PATHS, MockLibrary } from './mock';
import { LIBRARY_INITIAL, addFolder, closeLibrary, chooseCollection, developTargets, libraryStore, openLibrary, pick, setLibraryClient, setRating } from './store';

let mock: MockLibrary;
beforeEach(() => {
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
});
