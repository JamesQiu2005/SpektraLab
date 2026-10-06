// histogram.ts — counts of the *output* (the canvas's frame: geometry and
// Layer 2 applied — AGENTS.md trap 33), off the main thread.

import { createElement } from 'react';

export interface Histogram {
  r: Uint32Array;
  g: Uint32Array;
  b: Uint32Array;
  y: Uint32Array;
}

export function computeHistogram(px: Uint8Array): Histogram {
  const h = { r: new Uint32Array(256), g: new Uint32Array(256), b: new Uint32Array(256), y: new Uint32Array(256) };
  for (let i = 0; i < px.length; i += 4) {
    const r = px[i]!;
    const g = px[i + 1]!;
    const b = px[i + 2]!;
    h.r[r]!++;
    h.g[g]!++;
    h.b[b]!++;
    h.y[Math.round(0.2126 * r + 0.7152 * g + 0.0722 * b)]!++;
  }
  return h;
}

let worker: Worker | null = null;
let seq = 0;
const waiting = new Map<number, (h: Histogram) => void>();

/** In a Web Worker when one can be started; inline otherwise. */
export function histogramOf(px: Uint8Array): Promise<Histogram> {
  try {
    if (!worker) {
      worker = new Worker(new URL('./histogram.worker.ts', import.meta.url), { type: 'module' });
      worker.onmessage = (e: MessageEvent<{ id: number; h: Histogram }>) => {
        waiting.get(e.data.id)?.(e.data.h);
        waiting.delete(e.data.id);
      };
    }
    const id = ++seq;
    return new Promise((resolve) => {
      waiting.set(id, resolve);
      const copy = px.slice();
      worker!.postMessage({ id, px: copy }, [copy.buffer]);
    });
  } catch {
    return Promise.resolve(computeHistogram(px));
  }
}

function path(bins: Uint32Array, peak: number, w: number, h: number): string {
  let d = `M0 ${h}`;
  for (let i = 0; i < 256; i++) {
    const x = (i / 255) * w;
    const y = h - (Math.min(bins[i]!, peak) / peak) * h;
    d += ` L${x.toFixed(1)} ${y.toFixed(1)}`;
  }
  return d + ` L${w} ${h} Z`;
}

export function HistogramOverlay({ h, width = 150, height = 44 }: { h: Histogram; width?: number; height?: number }) {
  // The 99.5th percentile bin as the ceiling, so one spike does not flatten the rest.
  const all = [...h.r, ...h.g, ...h.b].sort((a, b) => a - b);
  const peak = Math.max(1, all[Math.floor(all.length * 0.995)] ?? 1);
  return createElement(
    'svg',
    { className: 'histogram', width, height, viewBox: `0 0 ${width} ${height}`, 'data-testid': 'histogram' },
    createElement('path', { d: path(h.y, peak, width, height), fill: 'var(--hist-y)', fillOpacity: 0.25 }),
    createElement('path', { d: path(h.r, peak, width, height), fill: 'none', stroke: 'var(--hist-r)', strokeWidth: 1 }),
    createElement('path', { d: path(h.g, peak, width, height), fill: 'none', stroke: 'var(--hist-g)', strokeWidth: 1 }),
    createElement('path', { d: path(h.b, peak, width, height), fill: 'none', stroke: 'var(--hist-b)', strokeWidth: 1 }),
  );
}
