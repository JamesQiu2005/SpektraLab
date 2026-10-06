// surfaces.ts — how each surface that shows the frame derives its picture
// from the one geometry map (ARCHITECTURE.md §7.7, AGENTS.md trap 33).
//
//   canvas, navigator, histogram  → the output: `sourcePoint(g, ·)` (in GLSL)
//   filmstrip, export strip       → the whole photograph turned and flipped,
//                                   the crop's outline from the same geometry
//   exported file                 → `resampleOutput` below, the same map on the CPU
//
// `surfaces.test.ts` gives a frame a crop *and* a quarter turn and checks that
// every surface lands on the canvas's frame.

import { type Geometry, type Point, type Size, GEOMETRY_DEFAULT, corners, outputPoint, outputSize, sourcePoint } from './geometry';

export interface ThumbPlan {
  width: number;
  height: number;
  /** image px → cell px, canvas 2D `setTransform(a, b, c, d, e, f)` order. */
  imageTransform: [number, number, number, number, number, number];
  /** The crop's outline in cell px, or null when nothing is cropped. */
  cropPolygon: Point[] | null;
}

/** The turns and flips alone: what the filmstrip shows the whole frame through. */
export const orientationOnly = (g: Geometry): Geometry => ({ ...GEOMETRY_DEFAULT, quarterTurns: g.quarterTurns, flipH: g.flipH, flipV: g.flipV });

export function thumbnailGeometryPlan(g: Geometry, image: Size, cellHeight: number): ThumbPlan {
  const d = orientationOnly(g);
  const out = outputSize(d, image);
  const k = cellHeight / out.height;
  const width = Math.max(1, Math.round(out.width * k));
  const height = Math.max(1, Math.round(cellHeight));
  const cell = (s: Point): Point => {
    const o = outputPoint(d, s, image);
    return { x: o.x * width, y: o.y * height };
  };
  const o = cell({ x: 0, y: 0 });
  const ex = cell({ x: 1, y: 0 });
  const ey = cell({ x: 0, y: 1 });
  const imageTransform: ThumbPlan['imageTransform'] = [
    (ex.x - o.x) / image.width,
    (ex.y - o.y) / image.width,
    (ey.x - o.x) / image.height,
    (ey.y - o.y) / image.height,
    o.x,
    o.y,
  ];
  const cropped = !(g.crop.x === 0 && g.crop.y === 0 && g.crop.width === 1 && g.crop.height === 1 && g.angle === 0);
  return { width, height, imageTransform, cropPolygon: cropped ? corners(g, image).map(cell) : null };
}

/**
 * The output on the CPU: bilinear samples of `src` (rgba, any numeric array,
 * `channels` per pixel) through `sourcePoint`. Used where the shader cannot
 * be (an export written from rgba16).
 */
export function resampleOutput<T extends Float32Array | Uint8Array | Uint16Array>(
  src: ArrayLike<number>,
  srcSize: Size,
  g: Geometry,
  outW: number,
  outH: number,
  make: (n: number) => T,
): T {
  const out = make(outW * outH * 4);
  const { width: W, height: H } = srcSize;
  for (let y = 0; y < outH; y++) {
    for (let x = 0; x < outW; x++) {
      const s = sourcePoint(g, { x: (x + 0.5) / outW, y: (y + 0.5) / outH }, srcSize);
      const fx = Math.min(Math.max(s.x * W - 0.5, 0), W - 1);
      const fy = Math.min(Math.max(s.y * H - 0.5, 0), H - 1);
      const x0 = Math.floor(fx);
      const y0 = Math.floor(fy);
      const x1 = Math.min(x0 + 1, W - 1);
      const y1 = Math.min(y0 + 1, H - 1);
      const tx = fx - x0;
      const ty = fy - y0;
      const o = (y * outW + x) * 4;
      for (let c = 0; c < 4; c++) {
        const a = src[(y0 * W + x0) * 4 + c]!;
        const b = src[(y0 * W + x1) * 4 + c]!;
        const cc = src[(y1 * W + x0) * 4 + c]!;
        const dd = src[(y1 * W + x1) * 4 + c]!;
        out[o + c] = (a * (1 - tx) + b * tx) * (1 - ty) + (cc * (1 - tx) + dd * tx) * ty;
      }
    }
  }
  return out;
}
