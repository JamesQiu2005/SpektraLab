// Trap 33: give the frame a crop *and* a quarter turn, read every surface,
// compare with the canvas.

import { describe, expect, it } from 'vitest';
import { GEOMETRY_DEFAULT, type Geometry, outputSize, shaderMap, sourcePoint, uniform } from './geometry';
import { resampleOutput, thumbnailGeometryPlan } from './surfaces';

const image = { width: 60, height: 40 };
const g: Geometry = { ...GEOMETRY_DEFAULT, crop: { x: 0.2, y: 0.1, width: 0.5, height: 0.6 }, angle: 7, quarterTurns: 1, flipH: true };

/** A source whose every pixel says where it is (r = x, g = y). */
function coordinateImage(): Uint8Array {
  const px = new Uint8Array(image.width * image.height * 4);
  for (let y = 0; y < image.height; y++)
    for (let x = 0; x < image.width; x++) {
      const i = (y * image.width + x) * 4;
      px[i] = x * 4;
      px[i + 1] = y * 6;
      px[i + 2] = 0;
      px[i + 3] = 255;
    }
  return px;
}

describe('every surface shows the canvas frame', () => {
  it('the exported pixels are the canvas map (shader) sampled', () => {
    const out = outputSize(g, image);
    const px = resampleOutput(coordinateImage(), image, g, out.width, out.height, (n) => new Float32Array(n));
    const u = uniform(g, image);
    for (const [x, y] of [
      [1, 1],
      [out.width - 2, 3],
      [5, out.height - 2],
    ] as const) {
      const s = shaderMap(u, { x: (x + 0.5) / out.width, y: (y + 0.5) / out.height });
      const i = (y * out.width + x) * 4;
      expect(px[i]! / 4).toBeCloseTo(s.x * image.width - 0.5, 0);
      expect(px[i + 1]! / 6).toBeCloseTo(s.y * image.height - 0.5, 0);
    }
  });

  it('the filmstrip outlines exactly the canvas output', () => {
    const plan = thumbnailGeometryPlan(g, image, 100);
    expect(plan.cropPolygon).not.toBeNull();
    // Invert the image transform: cell px → image px → normalised source.
    const [a, b, c, d, e, f] = plan.imageTransform;
    const det = a * d - b * c;
    const toSource = (p: { x: number; y: number }) => {
      const x = p.x - e;
      const y = p.y - f;
      return { x: (d * x - c * y) / det / image.width, y: (-b * x + a * y) / det / image.height };
    };
    const outline = plan.cropPolygon!.map(toSource);
    const canvasCorners = [
      { x: 0, y: 0 },
      { x: 1, y: 0 },
      { x: 1, y: 1 },
      { x: 0, y: 1 },
    ].map((p) => sourcePoint(g, p, image));
    for (const cc of canvasCorners) {
      const hit = outline.some((o) => Math.abs(o.x - cc.x) < 1e-9 && Math.abs(o.y - cc.y) < 1e-9);
      expect(hit).toBe(true);
    }
    // And the strip shows the photograph turned, as the canvas does.
    expect(plan.width).toBeLessThan(plan.height);
  });
});
