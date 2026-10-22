// Folder ordering is a view preference. It can reorder only the files which
// were explicitly imported; it never loads files from an earlier library.
import type { FileEntry } from '../platform';
type StoragePort = Pick<Storage, 'getItem' | 'setItem'>;
const STORE = 'ui2.frameOrder';
const pathKey = (path: string) => path.replace(/\\/g, '/').replace(/\/$/, '');
const parent = (path: string) => pathKey(path).slice(0, pathKey(path).lastIndexOf('/'));

export function frameOrderKey(folder: string, paths: readonly string[]): string {
  const parents = new Set(paths.map(parent));
  // A recursive folder and an explicit mixed selection are distinct sets.
  return parents.size <= 1 ? `folder:${pathKey(folder)}` : `set:${JSON.stringify([...paths].map(pathKey).sort())}`;
}

/** New files keep their original predecessor, as in Mac FrameOrder. */
export function orderedFrames(listed: FileEntry[], paths: readonly string[]): FileEntry[] {
  const rank = new Map<string, number>();
  paths.forEach((p, i) => { if (!rank.has(pathKey(p))) rank.set(pathKey(p), i); });
  const out = listed.filter((f) => rank.has(pathKey(f.path))).sort((a, b) => rank.get(pathKey(a.path))! - rank.get(pathKey(b.path))!);
  listed.forEach((f, i) => {
    if (rank.has(pathKey(f.path))) return;
    const before = i ? out.findIndex((v) => v.path === listed[i - 1]!.path) : -1;
    out.splice(before + 1, 0, f);
  });
  return out;
}

export function createFrameOrderStore(storage: StoragePort | null) {
  const read = (): Record<string, string[]> => {
    try {
      const value = JSON.parse(storage?.getItem(STORE) ?? '{}');
      if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
      return Object.fromEntries(Object.entries(value).filter((entry): entry is [string, string[]] =>
        Array.isArray(entry[1]) && entry[1].every((p) => typeof p === 'string')));
    } catch { return {}; }
  };
  return {
    apply(folder: string, listed: FileEntry[]) {
      const order = read()[frameOrderKey(folder, listed.map((f) => f.path))];
      return order ? orderedFrames(listed, order) : listed;
    },
    save(folder: string, listed: FileEntry[]) {
      const previous = read(), key = frameOrderKey(folder, listed.map((f) => f.path));
      delete previous[key];
      // Bound preference growth without ever keeping pixel data or sidecars.
      const recent = Object.fromEntries(Object.entries(previous).slice(-63));
      recent[key] = listed.map((f) => f.path);
      try { storage?.setItem(STORE, JSON.stringify(recent)); } catch { /* session order still works */ }
    },
  };
}

function localStoragePort(): StoragePort | null {
  try { return typeof window === 'undefined' ? null : window.localStorage; } catch { return null; }
}
export const frameOrder = createFrameOrderStore(localStoragePort());
