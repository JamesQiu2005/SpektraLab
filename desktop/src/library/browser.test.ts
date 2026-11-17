// The browser's rows and selection in every mode (PRD-W5 §2, R3) and the mode row's "why not".

import { beforeEach, describe, expect, it, vi } from 'vitest';
import { createStore } from 'zustand/vanilla';

const fake = vi.hoisted(() => ({
  click: vi.fn(), openPaths: vi.fn(async (_paths: string[]) => {}), select: vi.fn(async (_path: string) => {}),
}));
vi.mock('../state/session', async () => {
  const sessionStore = createStore(() => ({ frames: [] as { path: string; name: string }[], selection: null as string | null, picked: [] as string[] }));
  fake.openPaths.mockImplementation(async (paths: string[]) => { sessionStore.setState({ frames: paths.map((p) => ({ path: p, name: p.split('/').pop()! })), selection: paths[0] ?? null }); });
  fake.select.mockImplementation(async (path: string) => { sessionStore.setState({ selection: path }); });
  fake.click.mockImplementation((path: string, additive = false) => {
    const s = sessionStore.getState();
    if (additive) sessionStore.setState({ picked: s.picked.includes(path) ? s.picked.filter((p) => p !== path) : [...s.picked, path] });
    else sessionStore.setState({ picked: [path], selection: path });
  });
  return { sessionStore, click: fake.click, openPaths: fake.openPaths, select: fake.select };
});

import { sessionStore } from '../state/session';
import { libraryStore, LIBRARY_INITIAL } from './store';
import { browserRows, browserSource, exportPaths, modePicture, pressRow, stepRow } from './browser';
import { chooseMode, modeUnavailable } from '../app/modes';
import { uiStore, UI_INITIAL } from '../app/ui';
import type { ImageRow } from './client';

const img = (n: number, exists = true): ImageRow => ({ uuid: `u${n}`, path: `/lib/p${n}.ARW`, file_name: `p${n}.ARW`, exists, variants: [] } as unknown as ImageRow);
const roll = (...paths: string[]) => sessionStore.setState({ frames: paths.map((p) => ({ path: p, name: p.split('/').pop()!, size: 0, mtime_ms: 0 })) });

beforeEach(() => {
  vi.clearAllMocks();
  uiStore.setState(UI_INITIAL);
  libraryStore.setState({ ...LIBRARY_INITIAL });
  sessionStore.setState({ frames: [], selection: null, picked: [] });
});

const openLibrary = (images: ImageRow[]) => libraryStore.setState({
  source: { handle: 'h', kind: 'catalog', readOnly: false, info: { name: 'L', path: '/lib' } } as never, images, total: images.length,
});

describe('the browser’s rows', () => {
  it('are the folder’s frames with no library open, and the library’s rows with one', () => {
    roll('/f/a.NEF', '/f/b.NEF');
    expect(browserSource()).toBe('folder');
    expect(browserRows().map((r) => r.path)).toEqual(['/f/a.NEF', '/f/b.NEF']);
    openLibrary([img(1), img(2)]);
    expect(browserSource()).toBe('library');
    expect(browserRows().map((r) => r.id)).toEqual(['u1', 'u2']);
  });

  it('a row pressed in Develop opens that picture through the editing session; in the Library it only chooses', async () => {
    openLibrary([img(1), img(2), img(3)]);
    uiStore.setState({ workspace: 'library' });
    await pressRow(browserRows()[1]!);
    expect(libraryStore.getState()).toMatchObject({ picked: ['u2'], focus: 'u2' });
    expect(fake.openPaths).not.toHaveBeenCalled();
    uiStore.setState({ workspace: 'develop' });
    await pressRow(browserRows()[2]!);
    // The roll was not the library's rows: they come in (Develop ↵'s path), and this one opens.
    expect(fake.openPaths).toHaveBeenCalledWith(['/lib/p1.ARW', '/lib/p2.ARW', '/lib/p3.ARW']);
    expect(sessionStore.getState().selection).toBe('/lib/p3.ARW');
    // Now they are the roll: the next press is a plain switch of the open frame.
    fake.openPaths.mockClear();
    await pressRow(browserRows()[0]!);
    expect(fake.openPaths).not.toHaveBeenCalled();
    expect(fake.click).toHaveBeenLastCalledWith('/lib/p1.ARW');
    expect(libraryStore.getState().focus).toBe('u1');
  });

  it('the selection is one in every mode: Ctrl chooses without opening, and Export takes the chosen rows', async () => {
    openLibrary([img(1), img(2), img(3)]);
    uiStore.setState({ workspace: 'edit' });
    roll('/lib/p1.ARW', '/lib/p2.ARW', '/lib/p3.ARW');
    await pressRow(browserRows()[0]!);
    await pressRow(browserRows()[2]!, { ctrl: true });
    expect(libraryStore.getState().picked).toEqual(['u1', 'u3']);
    expect(fake.click).toHaveBeenCalledTimes(1);
    uiStore.setState({ workspace: 'library' });
    expect(libraryStore.getState().picked).toEqual(['u1', 'u3']);
    expect(exportPaths('/lib/p1.ARW')).toEqual(['/lib/p1.ARW', '/lib/p3.ARW']);
    // One chosen is no batch: the open picture alone.
    libraryStore.setState({ picked: ['u2'] });
    expect(exportPaths('/lib/p1.ARW')).toEqual(['/lib/p1.ARW']);
  });

  it('← → walk the rows and stop at the ends', async () => {
    roll('/f/a.NEF', '/f/b.NEF', '/f/c.NEF');
    sessionStore.setState({ selection: '/f/b.NEF' });
    await stepRow(1);
    expect(sessionStore.getState().selection).toBe('/f/c.NEF');
    fake.click.mockClear();
    await stepRow(1);
    expect(fake.click).not.toHaveBeenCalled();
    await stepRow(-2);
    expect(sessionStore.getState().selection).toBe('/f/a.NEF');
  });
});

describe('the mode row', () => {
  it('Develop and Edit stand down with nothing to open, and say why in place', async () => {
    uiStore.setState({ workspace: 'library' });
    expect(modeUnavailable('library')).toBeNull();
    expect(modeUnavailable('develop')).toMatch(/Open a picture first/);
    await chooseMode('edit');
    expect(uiStore.getState()).toMatchObject({ workspace: 'library', modeNote: expect.stringMatching(/Open a picture first/) });
  });

  it('pressed in the Library, Develop opens the browser’s focus (else the open picture, else the first row)', async () => {
    openLibrary([img(1), img(2, false), img(3)]);
    uiStore.setState({ workspace: 'library' });
    expect(modePicture()?.id).toBe('u1');
    libraryStore.setState({ focus: 'u3' });
    expect(modeUnavailable('develop')).toBeNull();
    await chooseMode('develop');
    expect(uiStore.getState().workspace).toBe('develop');
    expect(sessionStore.getState().selection).toBe('/lib/p3.ARW');
    // Back in the Library with no focus, the open picture stays the one.
    uiStore.setState({ workspace: 'library' });
    libraryStore.setState({ focus: null });
    expect(modePicture()?.path).toBe('/lib/p3.ARW');
  });
});
