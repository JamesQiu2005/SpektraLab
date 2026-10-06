// histogram.ts — counts of the *output* (the canvas's frame: geometry and
// Layer 2 applied — AGENTS.md trap 33), off the main thread.

import { createElement } from 'react';

import { computeHistogram, type Histogram } from './histogram-core';

export { computeHistogram, type Histogram };

let worker: Worker | null = null;
let workerFailed = false;
let seq = 0;
// Each request keeps its own pixels, so a worker that dies can still be answered.
const waiting = new Map<number, { px: Uint8Array; resolve: (h: Histogram) => void }>();

/** The worker failed to load or crashed: answer everything inline from now on. */
function abandonWorker() {
  workerFailed = true;
  worker?.terminate();
  worker = null;
  for (const { px, resolve } of waiting.values()) resolve(computeHistogram(px));
  waiting.clear();
}

/** In a Web Worker when one can be started; inline otherwise. */
export function histogramOf(px: Uint8Array): Promise<Histogram> {
  if (workerFailed) return Promise.resolve(computeHistogram(px));
  try {
    if (!worker) {
      worker = new Worker(new URL('./histogram.worker.ts', import.meta.url), { type: 'module' });
      worker.onmessage = (e: MessageEvent<{ id: number; h: Histogram }>) => {
        waiting.get(e.data.id)?.resolve(e.data.h);
        waiting.delete(e.data.id);
      };
      worker.onerror = abandonWorker;
      worker.onmessageerror = abandonWorker;
    }
    const id = ++seq;
    return new Promise((resolve) => {
      waiting.set(id, { px, resolve });
      const copy = px.slice();
      worker!.postMessage({ id, px: copy }, [copy.buffer]);
    });
  } catch {
    abandonWorker();
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
