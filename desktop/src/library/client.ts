// client.ts — the Library's one door (PRD-W0 §5.3): the spklib helper's
// method table (`SpektraLab_library/API-SPEC.md`, 0.3.1, abi 1) behind
// `call(method, params)`, plus the helper's state.
//
// Under Tauri it is `TauriLibrary` (tauriLibrary.ts): the commands
// `library_call` / `library_state` over `spk_library::LibraryHost`
// (desktop/crates/spk-library/README.md); in the browser and the tests, the
// in-page `MockLibrary` (mock.ts).
// The typed wrappers below are the only place a method name is written.

export type LibraryErrorCode =
  | 'not_found' | 'invalid_params' | 'read_only' | 'conflict' | 'source_busy' | 'unsupported' | 'exists'
  | 'in_use' | 'ambiguous' | 'cross_volume' | 'io' | 'internal' | 'unknown_method' | 'last_variant'
  // spk-library's own (desktop/crates/spk-library/README.md, Errors): the helper could not start or stopped; no reply in time.
  | 'unavailable' | 'timeout' | 'stale_library';

export class LibraryError extends Error {
  constructor(readonly code: LibraryErrorCode, message: string, readonly data: unknown = null) { super(message); }
}

/** `library_state()`: the README's `{running, version, launches, store, executable}`; `origin` says how
 * the helper was found (`SPKLIB_HOST`, beside the engine host …), `reason` why there is none. */
export interface LibraryState {
  running: boolean;
  version: string | null;
  /** Helpers started so far: when it changes, every handle died with the old one (reopen by path). */
  launches: number;
  /** Where linked Capture One mirrors and the app's own folder libraries live; null in the page's mock. */
  store: string | null;
  executable: string | null;
  origin?: string;
  reason?: string;
}

export interface LibraryClient {
  call<T = unknown>(method: string, params?: Record<string, unknown>): Promise<T>;
  state(): Promise<LibraryState>;
}

// ------------------------------------------------------- the results we read

export type LibraryKind = 'catalog' | 'session' | 'capture_one.catalog' | 'capture_one.session' | 'folder';

export interface LibraryInfo {
  uuid: string;
  kind: 'catalog' | 'session';
  name: string;
  path: string;
  origin: { kind: string; path: string; write_back: boolean } | null;
  counts: { images: number; variants?: number; collections?: number };
}

export interface Opened { library: string; info: LibraryInfo }

export interface Collection {
  uuid: string;
  parent: string | null;
  kind: string;
  name: string;
  title: string;
  position: number;
  origin: string;
  editable: boolean;
  image_count: number | null;
  folder?: string | null;
  /** A smart album's filter (`images.list` filter keys); the app's film rows use `film`. */
  criteria?: Record<string, unknown> | null;
}

export interface ImageRow {
  uuid: string;
  path: string;
  file_name: string;
  kind: string;
  rating: number | null;
  color_tag: number | null;
  trashed: boolean;
  captured_local: string | null;
  origin: string;
  variants: { uuid: string; position: number; rating: number | null; color_tag: number | null; edit_revision: number; origin: string }[];
  exists?: boolean;
  camera?: { make?: string; model?: string; lens?: string };
  exposure?: { shutter?: string; aperture?: number; iso?: number };
  width?: number;
  height?: number;
}

export interface ImagesPage { total: number; offset: number; images: ImageRow[] }

export interface Location { uuid: string; base: string; path: string; volume: string; relinked: boolean; origin: string; image_count: number; online: boolean }

export interface Probe { document: 'catalog' | 'session'; document_uuid: string; format: string; counts: Record<string, number>; supported: boolean; reason: string | null }

// --------------------------------------------------------- typed wrappers

export const lib = {
  version: (c: LibraryClient) => c.call<{ version: string; abi: number; schema: number; capture_one: { write_back: boolean; previews: boolean } }>('sdk.version'),
  open: (c: LibraryClient, path: string) => c.call<Opened>('library.open', { path }),
  create: (c: LibraryClient, path: string, kind: 'catalog' | 'session', name?: string) => c.call<Opened>('library.create', { path, kind, name }),
  close: (c: LibraryClient, library: string) => c.call<{ closed: boolean }>('library.close', { library }),
  info: (c: LibraryClient, library: string) => c.call<LibraryInfo>('library.info', { library }),
  probe: (c: LibraryClient, path: string) => c.call<Probe>('capture_one.probe', { path }),
  link: (c: LibraryClient, source: string) => c.call<Opened>('capture_one.link', { source }),
  collections: (c: LibraryClient, library: string) => c.call<{ collections: Collection[] }>('collections.list', { library }),
  images: (c: LibraryClient, library: string, q: { collection?: string; filter?: Record<string, unknown>; sort?: string; descending?: boolean; limit?: number; offset?: number; check_files?: boolean; full?: boolean } = {}) =>
    c.call<ImagesPage>('images.list', { library, sort: 'captured', descending: true, ...q }),
  image: (c: LibraryClient, library: string, image: string) => c.call<ImageRow & { albums: string[] }>('image.get', { library, image }),
  setRating: (c: LibraryClient, library: string, images: string[], rating: number | null) => c.call<{ updated: number }>('meta.set', { library, images, rating }),
  setColour: (c: LibraryClient, library: string, images: string[], color_tag: number | null) => c.call<{ updated: number }>('meta.set', { library, images, color_tag }),
  addFolder: (c: LibraryClient, library: string, path: string) => c.call<{ folder: string; collection: string; path: string }>('folders.add', { library, path }),
  folders: (c: LibraryClient, library: string) => c.call<{ folders: { folder: string; path: string; online: boolean; image_count: number }[] }>('folders.list', { library }),
  syncFolders: (c: LibraryClient, library: string) => c.call<{ added: number; removed: number }>('folders.sync', { library }),
  locations: (c: LibraryClient, library: string) => c.call<{ locations: Location[] }>('locations.list', { library }),
  relink: (c: LibraryClient, library: string, location: string, path: string | null) => c.call<{ path: string; online: boolean; relinked: string[] }>('location.relink', { library, location, path }),
  addImages: (c: LibraryClient, library: string, items: string[], mode: 'reference' | 'copy' = 'reference') => c.call<{ added: number }>('images.add', { library, items, mode }),
  createCollection: (c: LibraryClient, library: string, name: string, kind: 'album' | 'group' | 'project' | 'smart_album' = 'album') => c.call<{ collection: string }>('collection.create', { library, kind, name }),
  editGet: (c: LibraryClient, library: string, variant: string) => c.call<{ revision: number; edit: unknown | null }>('edit.get', { library, variant }),
  editPut: (c: LibraryClient, library: string, variant: string, edit: unknown, base_revision: number) => c.call<{ revision: number }>('edit.put', { library, variant, edit, base_revision }),
};
