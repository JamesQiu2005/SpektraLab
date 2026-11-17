// store.ts — the Library workspace's state, on a `LibraryClient` (README §4,
// Mac HIG §4). The library owns files: the editor shows what the Library
// hands it (Develop ↵ opens the picked frames, or the source's current
// result, as the filmstrip), and has no files tab of its own.

import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import { tz } from '../i18n';
import { platform } from '../platform';
import { LibraryError, lib, type Collection, type ImageRow, type LibraryClient, type LibraryInfo } from './client';
import { MOCK_LIBRARY_PATHS, MockLibrary } from './mock';

export type SourceKind = 'catalog' | 'session' | 'captureOneCatalog' | 'captureOneSession' | 'folder';

export interface RecentLibrary { name: string; path: string; kind: SourceKind }

export interface LibrarySource {
  handle: string;
  info: LibraryInfo;
  kind: SourceKind;
  readOnly: boolean;
}

export interface LibraryState {
  phase: 'none' | 'opening' | 'open' | 'failed';
  source: LibrarySource | null;
  collections: Collection[];
  collection: string | null;
  images: ImageRow[];
  total: number;
  /** Picked images (Ctrl/Shift+click), in pick order; `focus` is the one the Info rail shows. */
  picked: string[];
  focus: string | null;
  anchor: string | null;
  search: string;
  recent: RecentLibrary[];
  message: string | null;
  sourceMenu: boolean;
  /** The source well's progress line (*Reading · 4,210 of 9,660*). */
  progress: string | null;
  /** Folder rows whose drive is not there (`folders.list` online: false): *Offline*, in red and in words. */
  offline: string[];
}

const RECENT_KEY = 'ui2.library.recent';
const readRecent = (): RecentLibrary[] => {
  try {
    const v = JSON.parse(globalThis.localStorage?.getItem(RECENT_KEY) ?? 'null') as unknown;
    if (Array.isArray(v)) return v.filter((x): x is RecentLibrary => !!x && typeof x.path === 'string' && typeof x.name === 'string');
  } catch { /* none */ }
  return [
    { name: 'Darkroom 2026', path: MOCK_LIBRARY_PATHS.catalog, kind: 'catalog' },
    { name: 'Coast 2026', path: MOCK_LIBRARY_PATHS.session, kind: 'captureOneSession' },
    { name: 'Archive', path: MOCK_LIBRARY_PATHS.captureOne, kind: 'captureOneCatalog' },
  ];
};

export const LIBRARY_INITIAL: LibraryState = {
  phase: 'none', source: null, collections: [], collection: null, images: [], total: 0, picked: [], focus: null, anchor: null,
  search: '', recent: [], message: null, sourceMenu: false, progress: null, offline: [],
};

export const libraryStore = createStore<LibraryState>(() => ({ ...LIBRARY_INITIAL, recent: readRecent() }));
export const useLibrary = <T>(sel: (s: LibraryState) => T): T => useStore(libraryStore, sel);
const get = () => libraryStore.getState();
const set = (p: Partial<LibraryState>) => libraryStore.setState(p);

let client: LibraryClient = new MockLibrary();
/** Phase 2 binds the Tauri `library_call`; tests bind their own. */
export function setLibraryClient(c: LibraryClient) { client = c; }
export function libraryClient() { return client; }

function kindOf(info: LibraryInfo, folderSource: boolean): SourceKind {
  if (folderSource || info.origin?.kind === 'folder') return 'folder';
  if (info.origin?.kind === 'capture_one.catalog') return 'captureOneCatalog';
  if (info.origin?.kind === 'capture_one.session') return 'captureOneSession';
  return info.kind === 'session' ? 'session' : 'catalog';
}

export function kindWords(k: SourceKind): string {
  switch (k) {
    case 'catalog': return tz('Catalog', '目录');
    case 'session': return tz('Session', '会话');
    case 'captureOneCatalog': return tz('Capture One Catalog', 'Capture One 目录');
    case 'captureOneSession': return tz('Capture One Session', 'Capture One 会话');
    case 'folder': return tz('Folder', '文件夹');
  }
}

function remember(r: RecentLibrary) {
  const recent = [r, ...get().recent.filter((x) => x.path !== r.path)].slice(0, 8);
  set({ recent });
  try { globalThis.localStorage?.setItem(RECENT_KEY, JSON.stringify(recent)); } catch { /* the session only */ }
}

async function adopt(handle: string, info: LibraryInfo, folderSource = false) {
  const kind = kindOf(info, folderSource);
  const source: LibrarySource = { handle, info, kind, readOnly: kind === 'captureOneCatalog' || kind === 'captureOneSession' };
  const { collections } = await lib.collections(client, handle);
  const folders = await lib.folders(client, handle).catch(() => ({ folders: [] as { folder: string; online: boolean }[] }));
  const first = collections.find((c) => c.kind === 'all_images') ?? collections[0] ?? null;
  set({ phase: 'open', source, collections, offline: folders.folders.filter((f) => !f.online).map((f) => f.folder), collection: first?.uuid ?? null, picked: [], focus: null, anchor: null, message: null, sourceMenu: false, progress: null });
  remember({ name: info.name, path: info.path, kind });
  await refresh();
}

function fail(e: unknown) {
  const m = e instanceof LibraryError ? e.message : e instanceof Error ? e.message : String(e);
  set({ phase: get().source ? 'open' : 'failed', message: m });
}

export async function openLibrary(path: string) {
  set({ phase: 'opening', sourceMenu: false, message: null });
  try {
    if (/\.cocatalog|cosession/i.test(path) || /Coast 2026$/.test(path)) {
      await lib.probe(client, path);
      const r = await lib.link(client, path);
      await adopt(r.library, r.info);
    } else {
      const r = await lib.open(client, path);
      await adopt(r.library, r.info);
    }
  } catch (e) { fail(e); }
}

export async function openCaptureOneDialog() {
  const path = await platform().pickFolder(tz('Open a Capture One catalog', '打开 Capture One 目录'));
  if (path) await openLibrary(path);
}
export async function openLibraryDialog() {
  const path = await platform().pickFolder(tz('Open a library', '打开图库'));
  if (path) await openLibrary(path);
}

export async function newLibrary(kind: 'catalog' | 'session') {
  const p = await platform().appPaths().catch(() => null);
  const base = (p as { pictures?: string } | null)?.pictures ?? 'C:/Users/Photographer/Pictures/SpektraLab';
  const name = kind === 'catalog' ? tz('New Catalog', '新目录') : tz('New Session', '新会话');
  try {
    const r = await lib.create(client, `${base}/${name}.${kind === 'catalog' ? 'spkcatalog' : 'spksession'}`, kind, name);
    await adopt(r.library, r.info);
  } catch (e) { fail(e); }
}

/** A folder source: the folder's pictures in a library of their own (folder sources need no catalog). */
export async function addFolder(dir?: string | null) {
  const path = dir ?? await platform().pickFolder(tz('Add a folder', '添加文件夹'));
  if (!path) return;
  const s = get().source;
  try {
    if (s && !s.readOnly && s.kind !== 'folder') {
      await lib.addFolder(client, s.handle, path);
      await adopt(s.handle, s.info);
      return;
    }
    const name = path.split(/[\\/]/).filter(Boolean).pop() ?? path;
    const r = await lib.create(client, `${path}/.spektralab/${name}.spkcatalog`, 'catalog', name);
    const files = await platform().listImages(path).catch(() => []);
    if (files.length) await lib.addImages(client, r.library, files.map((f) => f.path));
    else await lib.addFolder(client, r.library, path);
    await adopt(r.library, { ...r.info, path, origin: { kind: 'folder', path, write_back: false } }, true);
  } catch (e) { fail(e); }
}

export async function newAlbum() {
  const s = get().source;
  if (!s || s.readOnly) return;
  try {
    await lib.createCollection(client, s.handle, tz('New Album', '新建相簿'));
    await adopt(s.handle, s.info, s.kind === 'folder');
  } catch (e) { fail(e); }
}

export async function closeLibrary() {
  const s = get().source;
  if (s) await lib.close(client, s.handle).catch(() => {});
  set({ ...LIBRARY_INITIAL, recent: get().recent });
}

export async function refresh() {
  const s = get().source;
  if (!s) return;
  try {
    const page = await lib.images(client, s.handle, { collection: get().collection ?? undefined, filter: get().search ? { text: get().search } : undefined, check_files: true, full: true });
    set({ images: page.images, total: page.total, picked: get().picked.filter((id) => page.images.some((i) => i.uuid === id)) });
  } catch (e) { fail(e); }
}

export async function chooseCollection(uuid: string) {
  set({ collection: uuid, picked: [], focus: null, anchor: null });
  await refresh();
}

export async function setSearch(text: string) { set({ search: text }); await refresh(); }

/** A click on a tile: alone, Ctrl (toggle) or Shift (range), as File Explorer picks. */
export function pick(uuid: string, mods: { ctrl?: boolean; shift?: boolean } = {}) {
  const s = get();
  if (mods.shift && s.anchor) {
    const ids = s.images.map((i) => i.uuid);
    const a = ids.indexOf(s.anchor), b = ids.indexOf(uuid);
    set({ picked: ids.slice(Math.min(a, b), Math.max(a, b) + 1), focus: uuid });
  } else if (mods.ctrl) {
    const picked = s.picked.includes(uuid) ? s.picked.filter((x) => x !== uuid) : [...s.picked, uuid];
    set({ picked, focus: uuid, anchor: uuid });
  } else set({ picked: [uuid], focus: uuid, anchor: uuid });
}
export function pickAll() { set({ picked: get().images.map((i) => i.uuid) }); }
export function pickNone() { set({ picked: [], focus: null }); }

export async function setRating(rating: number | null) {
  const s = get();
  if (!s.source || !s.picked.length) return;
  if (s.source.readOnly) { set({ message: tz('Ratings are set in Capture One', '评分在 Capture One 中设置') }); return; }
  try {
    await lib.setRating(client, s.source.handle, s.picked, rating);
    await refresh();
  } catch (e) { fail(e); }
}
export async function toggleFavourite() {
  const s = get();
  const f = s.images.find((i) => i.uuid === s.focus);
  await setRating(f && (f.rating ?? 0) >= 4 ? null : 4);
}

/** The frames Develop ↵ hands the editor: the picked ones, else the current result, the focused one first opened. */
export function developTargets(): { paths: string[]; open: string | null } {
  const s = get();
  const rows = s.picked.length > 1 ? s.images.filter((i) => s.picked.includes(i.uuid)) : s.images;
  const usable = rows.filter((i) => i.exists !== false);
  const focus = usable.find((i) => i.uuid === s.focus) ?? usable[0] ?? null;
  return { paths: usable.map((i) => i.path), open: focus?.path ?? null };
}

export function setLibrary(p: Partial<LibraryState>) { set(p); }
