// thumbs.ts — the filmstrip's pictures: the host's `thumbnail` (the embedded
// preview) until the frame has been printed in this session, then the print.
// Uncropped on purpose (ARCHITECTURE §7.7): each surface applies geometry.

import { host } from '../host/client';
import { rgbaToURL } from './frames';

interface Entry {
  url: string;
  print: boolean;
}

const MAX_CONCURRENT = 2;

class ThumbCache {
  private map = new Map<string, Entry>();
  private queue: string[] = [];
  private pending = new Set<string>();
  private running = 0;
  private listeners = new Set<() => void>();
  private failed = new Set<string>();

  get(path: string): string | null {
    const e = this.map.get(path);
    if (e) return e.url;
    if (!this.pending.has(path) && !this.failed.has(path)) {
      this.pending.add(path);
      this.queue.push(path);
      this.pump();
    }
    return null;
  }

  setPrint(path: string, url: string) {
    const old = this.map.get(path);
    if (old) URL.revokeObjectURL(old.url);
    this.map.set(path, { url, print: true });
    this.emit();
  }

  reset() {
    for (const e of this.map.values()) URL.revokeObjectURL(e.url);
    this.map.clear();
    this.queue = [];
    this.pending.clear();
    this.failed.clear();
  }

  onChange(cb: () => void) {
    this.listeners.add(cb);
    return () => this.listeners.delete(cb);
  }

  private emit() {
    for (const l of this.listeners) l();
  }

  private pump() {
    while (this.running < MAX_CONCURRENT && this.queue.length) {
      const path = this.queue.shift()!;
      this.running++;
      void (async () => {
        try {
          const img = await host().thumbnail(path, 320);
          const url = await rgbaToURL(img);
          if (url && !this.map.get(path)?.print) this.map.set(path, { url, print: false });
          else if (!url) this.failed.add(path);
        } catch {
          this.failed.add(path);
        } finally {
          this.pending.delete(path);
          this.running--;
          this.emit();
          this.pump();
        }
      })();
    }
  }
}

export const thumbs = new ThumbCache();
