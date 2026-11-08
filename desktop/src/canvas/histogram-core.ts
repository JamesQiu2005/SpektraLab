// histogram-core.ts — the counting itself, with no UI imports, so the Web
// Worker that runs it loads nothing but this file (a worker importing React
// through histogram.ts failed to start on a cold Vite dev server, and the
// histogram then never appeared).

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
