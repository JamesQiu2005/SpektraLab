import { useCallback, useSyncExternalStore } from 'react';
import { isRawPath } from '@shared/whiteBalance';
import { imageReply } from '../host/replies';
import { runJob } from '../scheduler';
import { displayCacheKey, readDisplayCache, writeDisplayCache } from '../state/displayCache';
import { rgbaToURL } from '../state/frames';
import { PreviewQueue } from '../state/previewQueue';
import { useSession } from '../state/session';

const EDGE = 512;
type Entry = { key: string; listeners: Map<() => void, boolean>; url: string | null; settled: boolean };

// Keep object URLs for mounted pictures. The shared display cache owns the
// bounded RAM and disk retention for pictures which have left the viewport.
const entries = new Map<string, Entry>();
let generation = 0;
const queue = new PreviewQueue(async ({ path, key }, signal) => {
  const entry = entries.get(path);
  if (!entry || entry.key !== key) return 'skipped';
  const current = () => !signal.aborted && entries.get(path) === entry;
  try {
    const raw = isRawPath(path);
    const cacheKey = await displayCacheKey({ kind: 'original', sources: [path],
      configuration: { libraryPreview: 1, longEdge: EDGE, embeddedOnly: raw } });
    if (!current()) return;
    let pixels = await readDisplayCache(cacheKey);
    if (!current()) return;
    if (!pixels) {
      const result = await runJob({ kind: 'thumbnail', frameId: path, slot: 'library', what: path,
        tier: 'preview', canvas: { width: EDGE, height: EDGE },
        request: { method: 'thumbnail', params: { path, long_edge: EDGE, ...(raw ? { embedded_only: true } : {}) } } });
      if (!current()) return;
      pixels = imageReply(result.result, result.payload);
      void writeDisplayCache(cacheKey, pixels);
    }
    const url = await rgbaToURL(pixels, EDGE);
    if (!url) return 'skipped';
    if (!current()) { URL.revokeObjectURL(url); return; }
    entry.url = url;
    for (const listener of entry.listeners.keys()) listener();
  } finally {
    if (current()) entry.settled = true;
  }
});

function updateQueue() {
  const jobs = [];
  let focus: string | null = null;
  for (const [path, entry] of entries) {
    if (entry.settled) continue;
    jobs.push({ path, key: entry.key });
    if ([...entry.listeners.values()].includes(true)) focus = path;
  }
  queue.replace(jobs, focus);
}

function watch(path: string, focus: boolean, listener: () => void) {
  let entry = entries.get(path);
  if (!entry) {
    entry = { key: String(++generation), listeners: new Map(), url: null, settled: false };
    entries.set(path, entry);
  }
  entry.listeners.set(listener, focus);
  updateQueue();
  return () => {
    entry.listeners.delete(listener);
    if (entry.listeners.size === 0) {
      entries.delete(path);
      if (entry.url) URL.revokeObjectURL(entry.url);
    }
    updateQueue();
  };
}

export function useLibraryPreview(path: string | null, focus = false): string | null {
  const raw = path != null && isRawPath(path);
  const capable = useSession((state) => state.hostState.phase === 'ready'
    && !!state.hello?.methods?.includes('thumbnail')
    && (!raw || !!state.hello?.thumbnail_options?.includes('embedded-only')));
  const source = capable ? path : null;
  const subscribe = useCallback((listener: () => void) => source ? watch(source, focus, listener) : () => {}, [source, focus]);
  const read = useCallback(() => source ? entries.get(source)?.url ?? null : null, [source]);
  return useSyncExternalStore(subscribe, read);
}
