// thumbs.ts — the filmstrip's pictures: the host's `thumbnail` (the embedded
// preview) until the frame has been printed in this session, then the print.
// Uncropped on purpose (ARCHITECTURE §7.7): each surface applies geometry.

import { host } from '../host/client';
import { rgbaToURL } from './frames';

interface Entry {
  url: string;
  print: boolean;
  filmCanvas?: boolean;
}

const MAX_CONCURRENT = 2;
type RequestSource = 'general' | 'filmstrip';

class ThumbCache {
  private map = new Map<string, Entry>();
  private queue: { path: string; source: RequestSource }[] = [];
  private pending = new Set<string>();
  private filmstripPaths = new Set<string>();
  private paused = false;
  private running = 0;
  private listeners = new Set<() => void>();
  private failed = new Set<string>();
  private revisions = new Map<string, number>();
  private epoch = 0;

  get(path: string, source: RequestSource = 'general'): string | null {
    const e = this.map.get(path);
    if (e) return e.url;
    if (source === 'filmstrip' && !this.filmstripPaths.has(path)) return null;
    // An export-grid request must survive the same cell leaving the strip.
    if (source === 'general') {
      const queued = this.queue.find((request) => request.path === path);
      if (queued) queued.source = 'general';
    }
    if (!this.pending.has(path) && !this.failed.has(path)) {
      this.pending.add(path);
      this.queue.push({ path, source });
      this.pump();
    }
    return null;
  }

  isFilmCanvas(path: string): boolean { return !!this.map.get(path)?.filmCanvas; }

  // The selection scheduler owns this pause. Already submitted requests finish;
  // none are duplicated or replaced, and clearing a library does not unpause it.
  setPaused(paused: boolean) {
    this.paused = paused;
    if (!paused) this.pump();
  }

  setFilmstripPaths(paths: Iterable<string>) {
    this.filmstripPaths = new Set(paths);
    this.queue = this.queue.filter(({ path, source }) => {
      if (source !== 'filmstrip' || this.filmstripPaths.has(path)) return true;
      this.pending.delete(path);
      return false;
    });
  }

  setPrint(path: string, url: string, filmCanvas = false) {
    const old = this.map.get(path);
    if (old) URL.revokeObjectURL(old.url);
    this.map.set(path, { url, print: true, filmCanvas });
    this.emit();
  }

  reset() {
    this.epoch++;
    for (const e of this.map.values()) URL.revokeObjectURL(e.url);
    this.map.clear();
    this.queue = [];
    this.filmstripPaths.clear();
    this.pending.clear();
    this.failed.clear();
    this.revisions.clear();
  }

  invalidate(path: string) {
    const old = this.map.get(path);
    if (old) URL.revokeObjectURL(old.url);
    this.map.delete(path);
    this.failed.delete(path);
    this.revisions.set(path, (this.revisions.get(path) ?? 0) + 1);
    this.emit();
  }

  onChange(cb: () => void) {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  private emit() {
    for (const l of this.listeners) l();
  }

  private pump() {
    while (!this.paused && this.running < MAX_CONCURRENT && this.queue.length) {
      const { path } = this.queue.shift()!;
      if (this.map.has(path)) { this.pending.delete(path); continue; }
      const epoch = this.epoch, revision = this.revisions.get(path) ?? 0;
      const current = () => epoch === this.epoch && revision === (this.revisions.get(path) ?? 0);
      this.running++;
      void (async () => {
        try {
          const img = await host().thumbnail(path, 320);
          const url = await rgbaToURL(img);
          if (url && current() && !this.map.get(path)?.print) this.map.set(path, { url, print: false });
          else if (url) URL.revokeObjectURL(url);
          else if (current()) this.failed.add(path);
        } catch {
          if (current()) this.failed.add(path);
        } finally {
          if (epoch === this.epoch) this.pending.delete(path);
          this.running--;
          this.emit();
          this.pump();
        }
      })();
    }
  }
}

export const thumbs = new ThumbCache();
