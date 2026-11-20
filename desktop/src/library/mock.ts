// mock.ts — an in-page spklib (API-SPEC 0.3.1) with the design's libraries:
// a SpektraLab catalog (Darkroom 2026), a Capture One catalog (Archive,
// read-only), a Capture One session (Coast 2026, read-only) and a folder
// (2026-10 Coast). It answers the methods the pages call with the shapes the
// helper returns, and refuses what the helper refuses (`read_only` on Capture
// One's rows, `not_found`, `unknown_method`), so the pages are built on the
// real contract and phase 2 is a change of binding.
//
// The pictures' paths are the browser mock host's: any path develops there.

import { LibraryError, type Collection, type ImageRow, type LibraryClient, type LibraryInfo, type LibraryState, type Location } from './client';

const FILMS = ['kodak_portra_400', 'kodak_gold_200', 'kodak_ektar_100', 'fujifilm_pro_400h', 'kodak_portra_160'];

interface MockLibraryData {
  info: LibraryInfo;
  readOnly: boolean;
  collections: Collection[];
  members: Record<string, string[]>;
  images: ImageRow[];
  offline: Set<string>;
  locations?: Location[];
}

function img(root: string, name: string, i: number, day: string, hour: number, extra: Partial<ImageRow> = {}): ImageRow {
  const uuid = `${root.replace(/\W+/g, '')}-${i}`;
  return {
    uuid, path: `${root}/${name}`, file_name: name, kind: 'raw', rating: i % 5 === 0 ? 4 : null, color_tag: null, trashed: false,
    captured_local: `${day}T${String(hour).padStart(2, '0')}:${String((i * 7) % 60).padStart(2, '0')}:00`, origin: 'spektralab',
    variants: [{ uuid: `${uuid}-v1`, position: 1, rating: null, color_tag: null, edit_revision: i % 3 === 0 ? 1 : 0, origin: 'spektralab' }],
    exists: true, camera: { make: 'Sony', model: 'α7 IV' }, exposure: { shutter: '1/250', aperture: 4, iso: 200 }, width: 4000, height: 6000,
    ...extra,
  };
}

function coll(uuid: string, kind: string, name: string, count: number | null, extra: Partial<Collection> = {}): Collection {
  return { uuid, parent: null, kind, name, title: name, position: 0, origin: 'spektralab', editable: kind === 'album', image_count: count, ...extra };
}

function darkroom(): MockLibraryData {
  const root = 'C:/Users/Photographer/Pictures/2026-10';
  const days: [string, number][] = [['2026-10-23', 9], ['2026-10-18', 12], ['2026-10-17', 7]];
  const images: ImageRow[] = [];
  let n = 61;
  for (const [day, count] of days) for (let k = 0; k < count; k++) images.push(img(root, `_DSC${String(n).padStart(4, '0')}.ARW`, n++, day, 16 - (k % 8)));
  const offline = new Set(images.slice(21).map((i) => i.uuid));
  for (const i of images) if (offline.has(i.uuid)) i.exists = false;
  const all = images.map((i) => i.uuid);
  const collections = [
    coll('all', 'all_images', 'All Photos', images.length, { origin: 'fixed' }),
    coll('fav', 'smart_album', 'Favourites', images.filter((i) => (i.rating ?? 0) >= 4).length, { criteria: { rating: { min: 4 } } }),
    coll('dev', 'smart_album', 'Developing', 1, { criteria: { state: 'developing' } }),
    coll('recent', 'recent_import', 'Recent Imports', 9, { origin: 'fixed' }),
    coll('table', 'light_table', 'Table', 11),
    coll('roll4', 'light_table', 'Roll 4', 12),
    coll('roll3', 'light_table', 'Roll 3', 7),
    coll('film-portra400', 'smart_album', 'Porta 400', 12, { criteria: { film: 'kodak_portra_400' } }),
    coll('film-gold200', 'smart_album', 'Gold 200', 8, { criteria: { film: 'kodak_gold_200' } }),
    coll('film-ektar100', 'smart_album', 'Ektar 100', 5, { criteria: { film: 'kodak_ektar_100' } }),
    coll('film-trix400', 'smart_album', 'Tri-X 400', 3, { criteria: { film: 'kodak_tri_x_400' } }),
    coll('autumn', 'album', 'Autumn Walk', 6),
    coll('coast', 'album', 'Coast', 5),
    coll('pictures', 'folder', 'Pictures', 21, { folder: 'C:/Users/Photographer/Pictures' }),
    coll('travel', 'folder', 'Travel SSD (F:)', 7, { folder: 'F:/' }),
  ];
  return {
    info: { uuid: 'lib-darkroom', kind: 'catalog', name: 'Darkroom 2026', path: 'C:/Users/Photographer/Pictures/SpektraLab/Darkroom 2026.spkcatalog', origin: null, counts: { images: images.length } },
    readOnly: false, collections, images, offline,
    members: { 'film-portra400': all.slice(0, 12), 'film-gold200': all.slice(12, 20), 'film-ektar100': all.slice(20, 25), 'film-trix400': all.slice(25), all, fav: images.filter((i) => (i.rating ?? 0) >= 4).map((i) => i.uuid), dev: all.slice(0, 1), recent: all.slice(0, 9), table: all.slice(0, 11), roll4: all.slice(9, 21), roll3: all.slice(21), autumn: all.slice(2, 8), coast: all.slice(12, 17), pictures: all.slice(0, 21), travel: all.slice(21) },
  };
}

function archive(): MockLibraryData {
  const images = Array.from({ length: 14 }, (_, k) => img(k < 12 ? 'E:/Archive/2024-09' : 'C:/Archive/Originals',
    k < 12 ? `_DSC${2650 + k}.NEF` : `DSC_000${k - 11}.NEF`, 2650 + k, k < 10 ? '2024-09-17' : '2025-10-03', 11, { origin: 'capture_one', rating: 4 }));
  const all = images.map((i) => i.uuid);
  const collections = [
    coll('all', 'all_images', 'All Images', images.length, { origin: 'capture_one' }),
    coll('recent', 'recent_import', 'Recent Imports', 4, { origin: 'capture_one' }),
    coll('autumn', 'album', 'Autumn', 6, { origin: 'capture_one', editable: false }),
    coll('portfolio', 'album', 'Portfolio 2026', 4, { origin: 'capture_one', editable: false }),
    coll('c', 'folder', 'Local Disk (C:)', 4, { origin: 'capture_one', folder: 'C:/' }),
    coll('e', 'folder', 'Photos (E:)', 10, { origin: 'capture_one', folder: 'E:/' }),
  ];
  return {
    info: { uuid: 'lib-archive', kind: 'catalog', name: 'Archive', path: 'C:/Users/Photographer/Pictures/Archive.cocatalog', origin: { kind: 'capture_one.catalog', path: 'C:/Users/Photographer/Pictures/Archive.cocatalog', write_back: false }, counts: { images: images.length } },
    readOnly: true, collections, images, offline: new Set(all.slice(12)),
    locations: [{ uuid: 'archive-originals', base: 'absolute', path: 'C:/Archive/Originals', volume: 'C:', relinked: false, origin: 'capture_one', image_count: 2, online: false }],
    members: { all, recent: all.slice(0, 4), autumn: all.slice(0, 6), portfolio: all.slice(6, 10), c: all.slice(10), e: all.slice(0, 10) },
  };
}

function session(): MockLibraryData {
  const images = Array.from({ length: 12 }, (_, k) => img('E:/Coast 2026/Capture', `Coast_${String(401 + k).padStart(4, '0')}.CR3`, 401 + k, '2025-10-03', 9, { origin: 'capture_one' }));
  const all = images.map((i) => i.uuid);
  return {
    info: { uuid: 'lib-coast', kind: 'session', name: 'Coast 2026', path: 'E:/Coast 2026/Coast 2026.cosessiondb', origin: { kind: 'capture_one.session', path: 'E:/Coast 2026', write_back: false }, counts: { images: images.length } },
    readOnly: true, images, offline: new Set(),
    collections: [coll('capture', 'session_folder', 'Capture', 10, { origin: 'capture_one' }), coll('selects', 'session_folder', 'Selects', 2, { origin: 'capture_one' }), coll('output', 'session_folder', 'Output', 0, { origin: 'capture_one' }), coll('trash', 'session_folder', 'Trash', 0, { origin: 'capture_one' })],
    members: { capture: all.slice(0, 10), selects: all.slice(10), output: [], trash: [] },
  };
}

function folder(path = 'E:/Photos/2026-10 Coast'): MockLibraryData {
  const images = Array.from({ length: 10 }, (_, k) => img(path, `DSCF${4021 + k}.RAF`, 4021 + k, k < 4 ? '2026-10-23' : '2026-10-18', 10, { camera: { make: 'Fujifilm', model: 'X-T5' } }));
  const all = images.map((i) => i.uuid);
  const name = path.split(/[\\/]/).pop() ?? path;
  return {
    info: { uuid: `lib-folder-${name}`, kind: 'catalog', name, path, origin: { kind: 'folder', path, write_back: false }, counts: { images: images.length } },
    readOnly: false, images, offline: new Set(),
    collections: [coll('root', 'folder', name, images.length, { folder: path }), coll('day1', 'folder', 'Day 1', 4, { parent: 'root' }), coll('day2', 'folder', 'Day 2', 6, { parent: 'root' })],
    members: { root: all, day1: all.slice(0, 4), day2: all.slice(4) },
  };
}

export const MOCK_LIBRARY_PATHS = {
  catalog: 'C:/Users/Photographer/Pictures/SpektraLab/Darkroom 2026.spkcatalog',
  captureOne: 'C:/Users/Photographer/Pictures/Archive.cocatalog',
  session: 'E:/Coast 2026',
  folder: 'E:/Photos/2026-10 Coast',
};

export class MockLibrary implements LibraryClient {
  private open = new Map<string, MockLibraryData>();
  private catalogues = new Map<string, MockLibraryData>();
  private next = 1;
  calls: string[] = [];
  /** A helper that is not there: folder sources only (README §8.2 (4)). */
  constructor(private opts: { helper?: 'running' | 'absent' | 'stopped' } = {}) {}

  async state(): Promise<LibraryState> {
    const running = (this.opts.helper ?? 'running') === 'running';
    return { running, version: '0.4.0', launches: running ? 1 : 0, store: null, executable: null, origin: 'in-page mock',
      ...(running ? {} : { reason: 'The library helper is not running.' }) };
  }

  async call<T>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    this.calls.push(method);
    if ((this.opts.helper ?? 'running') !== 'running') throw new LibraryError('unavailable', 'The library helper is not running.');
    return this.dispatch(method, params) as T;
  }

  private lib(params: Record<string, unknown>): MockLibraryData {
    const l = this.open.get(String(params.library));
    if (!l) throw new LibraryError('not_found', `no library ${String(params.library)}`);
    return l;
  }

  private openData(path: string, make: () => MockLibraryData) {
    for (const [h, l] of this.open) if (l.info.path === path) return { library: h, info: l.info };
    const h = `L${this.next++}`;
    const d = this.catalogues.get(path) ?? make();
    this.catalogues.set(path, d);
    this.open.set(h, d);
    return { library: h, info: { ...d.info, counts: { ...d.info.counts, images: d.images.length } } };
  }

  private dispatch(method: string, p: Record<string, unknown>): unknown {
    switch (method) {
      case 'sdk.version': return { version: '0.3.1', abi: 1, schema: 3, capture_one: { write_back: false, previews: false } };
      case 'library.open': {
        const path = String(p.path ?? '');
        const saved = this.catalogues.get(path);
        if (saved) return this.openData(path, () => saved);
        if (path === MOCK_LIBRARY_PATHS.catalog || /Darkroom/.test(path)) return this.openData(MOCK_LIBRARY_PATHS.catalog, darkroom);
        if (/\.cocatalog/.test(path)) return this.openData(MOCK_LIBRARY_PATHS.captureOne, archive);
        if (/cosession|Coast 2026/.test(path)) return this.openData(MOCK_LIBRARY_PATHS.session, session);
        throw new LibraryError('not_found', `${path}: no library there`);
      }
      case 'capture_one.probe': {
        const path = String(p.path ?? '');
        const isSession = /cosession|Coast 2026/.test(path);
        if (!/\.cocatalog|cosession|Coast 2026/.test(path)) throw new LibraryError('not_found', `${path}: not a Capture One catalog or session`);
        return { document: isSession ? 'session' : 'catalog', document_uuid: 'C1-DOC', format: '16', counts: { images: isSession ? 12 : 14 }, supported: true, reason: null };
      }
      case 'capture_one.link': {
        const path = String(p.source ?? '');
        return /cosession|Coast 2026/.test(path) ? this.openData(MOCK_LIBRARY_PATHS.session, session) : this.openData(MOCK_LIBRARY_PATHS.captureOne, archive);
      }
      case 'library.create': {
        const path = String(p.path ?? '');
        if (this.catalogues.has(path)) throw new LibraryError('exists', `${path}: library already exists`);
        const name = String(p.name ?? path.split(/[\\/]/).pop()?.replace(/\.spk\w+$/, '') ?? 'Untitled');
        return this.openData(path, () => ({ info: { uuid: `lib-${name}`, kind: (p.kind as 'catalog' | 'session') ?? 'catalog', name, path, origin: null, counts: { images: 0 } },
          readOnly: false, images: [], offline: new Set(), collections: [coll('all', 'all_images', 'All Photos', 0, { origin: 'fixed' })], members: { all: [] } }));
      }
      case 'library.close': { this.open.delete(String(p.library)); return { closed: true }; }
      case 'library.info': {
        const l = this.lib(p);
        return { ...l.info, counts: { ...l.info.counts, images: l.images.length } };
      }
      case 'collections.list': return { collections: this.lib(p).collections };
      case 'images.list': {
        const l = this.lib(p);
        const ids = p.collection ? l.members[String(p.collection)] ?? [] : l.images.map((i) => i.uuid);
        let rows = l.images.filter((i) => ids.includes(i.uuid) && (p.include_trashed || !i.trashed));
        const f = (p.filter ?? {}) as { text?: string; rating_min?: number };
        if (f.text) rows = rows.filter((i) => i.file_name.toLowerCase().includes(String(f.text).toLowerCase()));
        if (f.rating_min) rows = rows.filter((i) => (i.rating ?? 0) >= Number(f.rating_min));
        const key = (i: (typeof rows)[number]): string | number => {
          switch (p.sort) {
            case 'name': return i.file_name.toLowerCase();
            case 'rating': return i.rating ?? 0;
            case 'imported': case 'added': return String((i as { imported_at?: string }).imported_at ?? i.captured_local ?? '');
            default: return i.captured_local ?? '';
          }
        };
        rows.sort((a, b) => {
          const x = key(a), y = key(b);
          return (typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y))) * (p.descending ? -1 : 1);
        });
        const offset = Number(p.offset ?? 0), limit = Number(p.limit ?? 1000);
        return { total: rows.length, offset, images: rows.slice(offset, offset + limit).map((i) => ({ ...i, exists: !l.offline.has(i.uuid) })) };
      }
      case 'image.get': {
        const l = this.lib(p);
        const i = l.images.find((x) => x.uuid === p.image);
        if (!i) throw new LibraryError('not_found', `no image ${String(p.image)}`);
        return { ...i, exists: !l.offline.has(i.uuid), albums: Object.entries(l.members).filter(([, m]) => m.includes(i.uuid)).map(([k]) => k) };
      }
      case 'meta.set': {
        const l = this.lib(p);
        if (l.readOnly) throw new LibraryError('read_only', 'Ratings are set in Capture One');
        const ids = (p.images ?? []) as string[];
        for (const i of l.images) if (ids.includes(i.uuid)) {
          if ('rating' in p) i.rating = p.rating as number | null;
          if ('color_tag' in p) i.color_tag = p.color_tag as number | null;
        }
        return { updated: ids.length };
      }
      case 'folders.add': {
        const l = this.lib(p);
        if (l.readOnly) throw new LibraryError('read_only', "Capture One's library is read-only");
        const path = String(p.path ?? '');
        const f = folder(path);
        l.images.push(...f.images);
        const id = `folder-${l.collections.length}`;
        l.collections.push(coll(id, 'folder', f.info.name, f.images.length, { folder: path }));
        l.members[id] = f.images.map((i) => i.uuid);
        l.members.all = [...(l.members.all ?? []), ...l.members[id]!];
        return { folder: id, collection: id, path, sync: { added: f.images.length } };
      }
      case 'folders.list': {
        const l = this.lib(p);
        return { folders: l.collections.filter((c) => c.kind === 'folder').map((c) => ({ folder: c.uuid, path: c.folder ?? '', online: !(c.uuid === 'travel' || c.uuid === 'c'), image_count: c.image_count ?? 0 })) };
      }
      case 'folders.sync': return { added: 0, moved: 0, removed: 0, restored: 0, folders: [] };
      case 'locations.list': {
        const l = this.lib(p);
        return { locations: l.locations ?? [] };
      }
      case 'location.relink': {
        const l = this.lib(p);
        const location = l.locations?.find((loc) => loc.uuid === p.location);
        if (!location || typeof p.path !== 'string') throw new LibraryError('not_found', 'No such location');
        const path = p.path.replaceAll('\\', '/').replace(/\/+$/, '');
        for (const row of l.images) if (row.path.startsWith(`${location.path}/`)) {
          row.path = path + row.path.slice(location.path.length);
          l.offline.delete(row.uuid);
        }
        Object.assign(location, { path, online: true, relinked: true });
        return { path, online: true, relinked: [location.uuid] };
      }
      case 'images.add': {
        const l = this.lib(p);
        if (l.readOnly) throw new LibraryError('read_only', "Capture One's library is read-only");
        const items = (p.items ?? []) as string[];
        const rows = items.map((path, k) => img(path.replace(/[\\/][^\\/]+$/, ''), path.split(/[\\/]/).pop()!, 9000 + l.images.length + k, '2026-10-23', 12));
        l.images.push(...rows);
        l.members.all = [...(l.members.all ?? []), ...rows.map((r) => r.uuid)];
        return { added: rows.length, results: rows.map((r) => ({ path: r.path, image: r.uuid, variant: r.variants[0]!.uuid, existing: false })) };
      }
      case 'collection.create': {
        const l = this.lib(p);
        if (l.readOnly) throw new LibraryError('read_only', "Capture One's albums are read-only");
        const uuid = `album-${l.collections.length}`;
        l.collections.push(coll(uuid, String(p.kind ?? 'album'), String(p.name ?? 'Untitled'), 0));
        l.members[uuid] = [];
        return { collection: uuid };
      }
      case 'edit.get': return { revision: 0, edit: null, modified_at: null };
      case 'edit.put': {
        if (this.lib(p).readOnly) throw new LibraryError('read_only', 'Adjustments stay in Capture One');
        return { revision: Number(p.base_revision ?? 0) + 1, modified_at: new Date().toISOString() };
      }
      default: throw new LibraryError('unknown_method', `unknown method ${method}`);
    }
  }
}

export { FILMS as MOCK_FILMS };
