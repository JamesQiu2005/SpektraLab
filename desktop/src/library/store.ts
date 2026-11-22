// store.ts — the Library workspace's state, on a `LibraryClient` (README §4,
// Mac HIG §4). The library owns files: the editor shows what the Library
// hands it (Develop ↵ opens the picked frames, or the source's current
// result, as the filmstrip), and has no files tab of its own.

import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import { tz } from '../i18n';
import { platform } from '../platform';
import { LibraryError, lib, type Collection, type ImageRow, type LibraryClient, type LibraryInfo, type Location } from './client';
import { MOCK_LIBRARY_PATHS, MockLibrary } from './mock';
import { TauriLibrary } from './tauriLibrary';
import { inTauri } from '../host/transport';

export type SourceKind = 'catalog' | 'session' | 'captureOneCatalog' | 'captureOneSession' | 'folder';

export type LibrarySort = 'captured' | 'imported' | 'name' | 'rating' | 'added';
export const LIBRARY_SORTS: LibrarySort[] = ['captured', 'imported', 'name', 'rating', 'added'];
export function sortWords(s: LibrarySort): string {
  switch (s) {
    case 'captured': return tz('Capture Date', '拍摄日期');
    case 'imported': return tz('Import Date', '导入日期');
    case 'name': return tz('File Name', '文件名');
    case 'rating': return tz('Rating', '评分');
    case 'added': return tz('Date Added', '添加日期');
  }
}

export interface RecentLibrary { name: string; path: string; kind: SourceKind; catalogPath?: string }

export interface LibrarySource {
  handle: string;
  info: LibraryInfo;
  kind: SourceKind;
  readOnly: boolean;
  catalogPath?: string;
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
  /** The browser's order (spklib `images.list` `sort`, `descending`): one order in every mode (`MacSharedControls`). */
  sort: LibrarySort;
  descending: boolean;
  recent: RecentLibrary[];
  message: string | null;
  sourceMenu: boolean;
  /** The source well's progress line (*Reading · 4,210 of 9,660*). */
  progress: string | null;
  /** Folder rows whose drive is not there (`folders.list` online: false): *Offline*, in red and in words. */
  offline: string[];
  locations: Location[];
  locating: boolean;
  /**
   * Each image's film, for a tile's status dot (PC-L1): read from the source's FILMS smart albums
   * (`criteria.film`), because spklib's image row carries no film of its own (PARITY.md).
   */
  filmOf: Record<string, string>;
}

const RECENT_KEY = 'ui2.library.recent';
const readRecent = (): RecentLibrary[] => {
  try {
    const v = JSON.parse(globalThis.localStorage?.getItem(RECENT_KEY) ?? 'null') as unknown;
    if (Array.isArray(v)) return v.filter((x): x is RecentLibrary => !!x && typeof x.path === 'string' && typeof x.name === 'string');
  } catch { /* none */ }
  if (inTauri()) return [];
  return [
    { name: 'Darkroom 2026', path: MOCK_LIBRARY_PATHS.catalog, kind: 'catalog' },
    { name: 'Coast 2026', path: MOCK_LIBRARY_PATHS.session, kind: 'captureOneSession' },
    { name: 'Archive', path: MOCK_LIBRARY_PATHS.captureOne, kind: 'captureOneCatalog' },
  ];
};

export const LIBRARY_INITIAL: LibraryState = {
  phase: 'none', source: null, collections: [], collection: null, images: [], total: 0, picked: [], focus: null, anchor: null,
  search: '', sort: 'captured', descending: true, recent: [], message: null, sourceMenu: false, progress: null, offline: [], locations: [], locating: false, filmOf: {},
};

export const libraryStore = createStore<LibraryState>(() => ({ ...LIBRARY_INITIAL, recent: readRecent() }));
export const useLibrary = <T>(sel: (s: LibraryState) => T): T => useStore(libraryStore, sel);
const get = () => libraryStore.getState();
const set = (p: Partial<LibraryState>) => libraryStore.setState(p);

let client: LibraryClient = inTauri() ? new TauriLibrary() : new MockLibrary();
/** The app's is the helper through Tauri; the browser's and the tests' the in-page mock; tests bind their own. */
export function setLibraryClient(c: LibraryClient) { client = c; }
export function libraryClient() { return client; }

function kindOf(info: LibraryInfo, folderSource: boolean): SourceKind {
  if (folderSource || info.origin?.kind === 'folder') return 'folder';
  if (info.origin?.kind === 'capture_one.catalog') return 'captureOneCatalog';
  if (info.origin?.kind === 'capture_one.session') return 'captureOneSession';
  return info.kind === 'session' ? 'session' : 'catalog';
}

function isCaptureOne(kind: SourceKind | undefined): boolean {
  return kind === 'captureOneCatalog' || kind === 'captureOneSession';
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
  const recent = [r, ...get().recent.filter((x) => x.path !== r.path && x.path !== r.catalogPath)].slice(0, 8);
  set({ recent });
  try { globalThis.localStorage?.setItem(RECENT_KEY, JSON.stringify(recent)); } catch { /* the session only */ }
}

let sourceRevision = 0;
let reopening: { revision: number; handle: string; task: Promise<LibrarySource> } | null = null;

function reopenSource(source: LibrarySource, revision: number): Promise<LibrarySource> {
  const current = get().source;
  if (revision !== sourceRevision || !current || current.info.uuid !== source.info.uuid)
    return Promise.reject(new LibraryError('stale_library', 'The library selection changed'));
  if (current.handle !== source.handle) return Promise.resolve(current);
  if (reopening?.revision === revision && reopening.handle === source.handle) return reopening.task;
  const task = lib.open(client, source.catalogPath ?? source.info.path).then((opened) => {
    if (revision !== sourceRevision || get().source !== current)
      throw new LibraryError('stale_library', 'The library selection changed');
    if (opened.info.uuid !== current.info.uuid)
      throw new LibraryError('conflict', tz('A different library is now at this path.', '此路径现在指向另一个图库。'));
    const recovered = { ...current, handle: opened.library };
    set({ source: recovered });
    return recovered;
  }).finally(() => { if (reopening?.task === task) reopening = null; });
  reopening = { revision, handle: source.handle, task };
  return task;
}

async function withSource<T>(source: LibrarySource, call: (handle: string) => Promise<T>, options?: { read: true }): Promise<T> {
  const revision = sourceRevision;
  const active = get().source;
  if (!active || active.info.uuid !== source.info.uuid)
    throw new LibraryError('stale_library', 'The library selection changed');
  try {
    return await call(active.handle);
  } catch (e) {
    // A stale handle was rejected before sending. A disconnected call may
    // already have committed, so only reads can be repeated in that case.
    if (!(e instanceof LibraryError) || (e.code !== 'stale_library' && !(options?.read && e.code === 'unavailable'))) throw e;
    const recovered = await reopenSource(active, revision);
    if (revision !== sourceRevision) throw new LibraryError('stale_library', 'The library selection changed');
    return call(recovered.handle);
  }
}

function openingSource(): number {
  const revision = ++sourceRevision;
  set({ phase: 'opening', sourceMenu: false, message: null, locating: false });
  return revision;
}

function offlineCollections(collections: Collection[], folders: { path: string; online: boolean }[]) {
  // The helper assigns different IDs to folder records and their sidebar collections.
  const paths = new Set(folders.filter((folder) => !folder.online).map((folder) => folder.path));
  return collections.filter((collection) => collection.kind === 'folder' && collection.folder && paths.has(collection.folder))
    .map((collection) => collection.uuid);
}

async function adopt(revision: number, handle: string, info: LibraryInfo, folderPath?: string) {
  if (revision !== sourceRevision) return;
  const kind = kindOf(info, folderPath !== undefined);
  const readOnly = isCaptureOne(kind);
  const path = folderPath ?? (readOnly ? info.origin?.path : undefined) ?? info.path;
  const source: LibrarySource = {
    handle, kind, readOnly,
    info: { ...info, path, origin: folderPath === undefined ? info.origin : { kind: 'folder', path, write_back: false } },
    ...(folderPath !== undefined || path !== info.path ? { catalogPath: info.path } : {}),
  };
  const { collections } = await lib.collections(client, handle);
  const folders = await lib.folders(client, handle).catch(() => ({ folders: [] }));
  const locations = readOnly ? await lib.locations(client, handle).then((result) => result.locations).catch(() => []) : [];
  if (revision !== sourceRevision) return;
  const first = collections.find((c) => c.kind === 'all_images') ?? collections[0] ?? null;
  set({ phase: 'open', source, collections, offline: offlineCollections(collections, folders.folders),
    locations,
    collection: first?.uuid ?? null, images: [], total: 0, filmOf: {}, picked: [], focus: null, anchor: null,
    message: null, sourceMenu: false, progress: null });
  remember({ name: source.info.name, path: source.info.path, kind, catalogPath: source.catalogPath });
  await refresh();
  const opened = get().source;
  if (revision === sourceRevision && opened) await readFilms(revision, opened, collections);
}

/** Each image's film, from the FILMS smart albums' members (one `images.list` per film album). */
async function readFilms(revision: number, source: LibrarySource, collections: Collection[]) {
  const filmOf: Record<string, string> = {};
  for (const c of collections) {
    if (revision !== sourceRevision) return;
    const film = c.kind === 'smart_album' && c.criteria && typeof (c.criteria as Record<string, unknown>).film === 'string' ? (c.criteria as Record<string, string>).film : null;
    if (!film) continue;
    try {
      const page = await withSource(source, (handle) => lib.images(client, handle, { collection: c.uuid }), { read: true });
      for (const i of page.images) filmOf[i.uuid] ??= film;
    } catch { /* a dot is a nicety: a film album that will not list leaves its frames without one */ }
  }
  if (revision === sourceRevision && get().source?.info.uuid === source.info.uuid) set({ filmOf });
}

function fail(e: unknown) {
  const m = e instanceof LibraryError ? e.message : e instanceof Error ? e.message : String(e);
  set({ phase: get().source ? 'open' : 'failed', message: m });
}

export async function openLibrary(path: string, kind?: 'captureOne') {
  const recent = get().recent.find((item) => item.path === path);
  const revision = openingSource();
  try {
    if (kind !== 'captureOne' && recent?.kind === 'folder') {
      // Older recent entries record only the photo folder. Reuse their
      // existing catalogue and keep its ratings even when the folder is offline.
      const catalogPath = typeof recent.catalogPath === 'string' && recent.catalogPath
        ? recent.catalogPath : await folderCatalogPath(path, folderName(path));
      const r = await lib.open(client, catalogPath);
      await adopt(revision, r.library, r.info, path);
    } else if (kind === 'captureOne' || /\.(?:cocatalog|cosession)(?:db)?[\\/]?$/i.test(path)
        || (isCaptureOne(recent?.kind) && !/\.(?:spkcatalog|spksession)[\\/]?$/i.test(path))) {
      const probe = await lib.probe(client, path);
      if (!probe.supported)
        throw new LibraryError('unsupported', probe.reason ?? tz('This Capture One library is unsupported.', '不支持此 Capture One 图库。'));
      const r = await lib.link(client, path);
      await adopt(revision, r.library, r.info);
    } else {
      const r = await lib.open(client, path);
      await adopt(revision, r.library, r.info);
    }
  } catch (e) { if (revision === sourceRevision) fail(e); }
}

export async function openCaptureOneDialog() {
  const path = await platform().pickFolder(tz('Open a Capture One catalog', '打开 Capture One 目录'));
  if (path) await openLibrary(path, 'captureOne');
}

function locationPath(path: string): string {
  const normalized = path.replaceAll('\\', '/');
  return /^[a-z]:\/|^\/\//i.test(normalized) ? normalized.toLowerCase() : normalized;
}

export function originalLocation(image: ImageRow, locations: Location[]): Location | undefined {
  if (image.exists !== false) return;
  const path = locationPath(image.path);
  let best: Location | undefined;
  let length = 0;
  for (const location of locations) {
    // Capture One stores managed originals in its own document. Only external
    // referenced folders can be moved independently and mapped in the mirror.
    if (location.base !== 'absolute' || !location.path) continue;
    const prefix = locationPath(location.path).replace(/\/+$/, '') + '/';
    if (prefix.length > length && path.startsWith(prefix)) {
      best = location;
      length = prefix.length;
    }
  }
  return best;
}

export async function locateOriginalFolder(image: ImageRow) {
  const s = get();
  if (!s.source?.readOnly || s.phase !== 'open' || s.locating || !s.images.includes(image)) return;
  const location = originalLocation(image, s.locations);
  if (!location) return;
  const revision = sourceRevision;
  set({ locating: true });
  try {
    const path = await platform().pickFolder(tz('Locate the folder containing the original', '定位原片所在的文件夹'));
    if (!path || revision !== sourceRevision) return;
    const prefix = location.path.replaceAll('\\', '/').replace(/\/+$/, '');
    const relative = image.path.replaceAll('\\', '/').slice(prefix.length + 1);
    const joined = `${path.replace(/[\\/]+$/, '')}/${relative}`;
    // Win32 does not translate slashes inside extended-length paths from the picker.
    const candidate = /^\\\\[?.]\\/.test(path) ? joined.replaceAll('/', '\\') : joined;
    const exists = await platform().pathExists(candidate);
    if (revision !== sourceRevision) return;
    if (!exists) {
      set({ message: tz('That folder does not contain the original.', '此文件夹不包含原片。') });
      return;
    }
    set({ message: null });
    const source = s.source;
    await withSource(source, (handle) => lib.relink(client, handle, location.uuid, path));
    if (revision !== sourceRevision) return;
    const [{ locations }] = await Promise.all([
      withSource(source, (handle) => lib.locations(client, handle), { read: true }), refresh(),
    ]);
    if (revision !== sourceRevision) return;
    set({ locations });
    if (get().images.some((row) => row.uuid === image.uuid && row.exists === false))
      set({ message: tz('The original is still offline. Choose the folder that contains it.', '原片仍处于离线状态。请选择包含原片的文件夹。') });
  } catch (e) { if (revision === sourceRevision) fail(e); }
  finally { if (revision === sourceRevision) set({ locating: false }); }
}

export async function openLibraryDialog() {
  const path = await platform().pickFolder(tz('Open a library', '打开图库'));
  if (path) await openLibrary(path);
}

export async function newLibrary(kind: 'catalog' | 'session') {
  const revision = openingSource();
  const p = await platform().appPaths().catch(() => null);
  const base = (p as { pictures?: string } | null)?.pictures ?? 'C:/Users/Photographer/Pictures/SpektraLab';
  const name = kind === 'catalog' ? tz('New Catalog', '新目录') : tz('New Session', '新会话');
  try {
    const r = await lib.create(client, `${base}/${name}.${kind === 'catalog' ? 'spkcatalog' : 'spksession'}`, kind, name);
    await adopt(revision, r.library, r.info);
  } catch (e) { if (revision === sourceRevision) fail(e); }
}

/** A folder source: the folder's pictures in a library of their own (folder sources need no catalog). */
export async function addFolder(dir?: string | null) {
  const path = dir ?? await platform().pickFolder(tz('Add a folder', '添加文件夹'));
  if (!path) return;
  const s = get().source;
  const revision = openingSource();
  try {
    if (s && !s.readOnly && s.kind !== 'folder') {
      const handle = await withSource(s, async (handle) => { await lib.addFolder(client, handle, path); return handle; });
      await adopt(revision, handle, await lib.info(client, handle));
      return;
    }
    const name = folderName(path);
    const where = await folderCatalogPath(path, name);
    const r = await lib.create(client, where, 'catalog', name).catch(async (e: unknown) => {
      if (e instanceof LibraryError && e.code === 'exists') return lib.open(client, where);
      throw e;
    });
    const files = await platform().listImages(path).catch(() => []);
    if (files.length) await lib.addImages(client, r.library, files.map((f) => f.path));
    else await lib.addFolder(client, r.library, path);
    await adopt(revision, r.library, await lib.info(client, r.library), path);
  } catch (e) { if (revision === sourceRevision) fail(e); }
}

function folderName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

async function folderCatalogPath(path: string, name: string): Promise<string> {
  // The browser mock has no on-disk store. Real folder catalogues are kept
  // under the helper's own store, separate from the referenced photos.
  const store = (await client.state().catch(() => null))?.store;
  if (!store && inTauri())
    throw new LibraryError('unavailable', tz('The library helper store is unavailable.', '图库助手的存储位置不可用。'));
  return store ? `${store}/Folders/${name}-${folderKey(path)}.spkcatalog` : `${path}/.spektralab/${name}.spkcatalog`;
}

/** A short stable key of a folder's path (FNV-1a), so two folders of one name keep two libraries. */
function folderKey(path: string): string {
  let h = 0x811c9dc5;
  for (const c of path.replaceAll('\\', '/').toLowerCase()) { h ^= c.charCodeAt(0); h = Math.imul(h, 0x01000193) >>> 0; }
  return h.toString(16).padStart(8, '0');
}

export async function newAlbum() {
  const s = get().source;
  if (!s || s.readOnly) return;
  const revision = sourceRevision;
  try {
    const handle = await withSource(s, async (handle) => { await lib.createCollection(client, handle, tz('New Album', '新建相簿')); return handle; });
    await adopt(revision, handle, await lib.info(client, handle), s.kind === 'folder' ? s.info.path : undefined);
  } catch (e) { if (revision === sourceRevision) fail(e); }
}

export async function closeLibrary() {
  const s = get().source;
  sourceRevision++;
  set({ ...LIBRARY_INITIAL, recent: get().recent, sort: get().sort, descending: get().descending });
  if (s) await lib.close(client, s.handle).catch(() => {});
}

let listRevision = 0;
export async function refresh({ checkFolders = false } = {}) {
  const { source, collection, search, sort, descending } = get();
  if (!source || get().phase !== 'open') return;
  const revision = ++listRevision;
  const sourceAtStart = sourceRevision;
  const current = () => revision === listRevision && sourceAtStart === sourceRevision && get().phase === 'open';
  try {
    const [page, folders] = await Promise.all([
      withSource(source, (handle) => lib.images(client, handle, { collection: collection ?? undefined,
        filter: search ? { text: search } : undefined, sort, descending, check_files: true, full: true }), { read: true }),
      checkFolders ? withSource(source, (handle) => lib.folders(client, handle), { read: true }).catch(() => null) : null,
    ]);
    if (!current()) return;
    const ids = new Set(page.images.map((image) => image.uuid));
    const { picked, focus, anchor } = get();
    set({ images: page.images, total: page.total, picked: picked.filter((id) => ids.has(id)),
      ...(folders ? { offline: offlineCollections(get().collections, folders.folders) } : {}),
      focus: focus && ids.has(focus) ? focus : null, anchor: anchor && ids.has(anchor) ? anchor : null });
  } catch (e) { if (current()) fail(e); }
}

export async function chooseCollection(uuid: string) {
  set({ collection: uuid, picked: [], focus: null, anchor: null });
  await refresh();
}

export async function setSearch(text: string) { set({ search: text }); await refresh(); }
export async function setSort(sort: LibrarySort, descending = get().descending) { set({ sort, descending }); await refresh(); }

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
  const revision = sourceRevision;
  try {
    await withSource(s.source, (handle) => lib.setRating(client, handle, s.picked, rating));
    if (revision === sourceRevision) {
      set({ message: null });
      await refresh();
    }
  } catch (e) {
    if (revision !== sourceRevision) return;
    if (e instanceof LibraryError && (e.code === 'unavailable' || e.code === 'timeout')) {
      await refresh();
      if (revision === sourceRevision) set({ message: tz(
        'The rating change could not be confirmed. Check the current rating before trying again.',
        '无法确认评分是否已保存。请核对当前评分后再试。') });
    } else fail(e);
  }
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
