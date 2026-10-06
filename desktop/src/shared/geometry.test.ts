import { describe, expect, it } from 'vitest';
import {
  GEOMETRY_DEFAULT,
  type Geometry,
  constrained,
  decodeGeometry,
  encodeGeometry,
  fits,
  outputPoint,
  outputSize,
  outputToSourceTransform,
  resized,
  shaderMap,
  sourcePoint,
  straightened,
  turned,
  uniform,
} from './geometry';

const image = { width: 3000, height: 2000 };
function rng(seed: number) {
  let s = seed;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296);
}
function randomGeometry(r: () => number): Geometry {
  const w = 0.3 + r() * 0.6;
  const h = 0.3 + r() * 0.6;
  return {
    ...GEOMETRY_DEFAULT,
    crop: { x: r() * (1 - w), y: r() * (1 - h), width: w, height: h },
    angle: (r() - 0.5) * 20,
    quarterTurns: Math.floor(r() * 4),
    flipH: r() > 0.5,
    flipV: r() > 0.5,
  };
}

describe('geometry', () => {
  it('the shader map is the model map (the canvas shows the exported frame)', () => {
    const r = rng(7);
    for (let i = 0; i < 200; i++) {
      const g = randomGeometry(r);
      const u = uniform(g, image);
      for (let k = 0; k < 10; k++) {
        const p = { x: r(), y: r() };
        const a = sourcePoint(g, p, image);
        const b = shaderMap(u, p);
        expect(b.x).toBeCloseTo(a.x, 9);
        expect(b.y).toBeCloseTo(a.y, 9);
      }
    }
  });

  it('outputPoint inverts sourcePoint', () => {
    const r = rng(11);
    for (let i = 0; i < 100; i++) {
      const g = randomGeometry(r);
      const p = { x: r(), y: r() };
      const q = outputPoint(g, sourcePoint(g, p, image), image);
      expect(q.x).toBeCloseTo(p.x, 9);
      expect(q.y).toBeCloseTo(p.y, 9);
    }
  });

  it('the affine transform agrees with the point map', () => {
    const g = { ...randomGeometry(rng(3)), quarterTurns: 1 };
    const [a, b, c, d, tx, ty] = outputToSourceTransform(g, image);
    const out = outputSize(g, image);
    for (const p of [{ x: 0.2, y: 0.7 }, { x: 0.9, y: 0.1 }]) {
      const s = sourcePoint(g, p, image);
      const x = p.x * out.width;
      const y = p.y * out.height;
      expect((a * x + c * y + tx) / image.width).toBeCloseTo(s.x, 9);
      expect((b * x + d * y + ty) / image.height).toBeCloseTo(s.y, 9);
    }
  });

  it('a quarter turn swaps the output size; the identity maps to itself', () => {
    expect(outputSize(turned(GEOMETRY_DEFAULT, 1), image)).toEqual({ width: 2000, height: 3000 });
    expect(sourcePoint(GEOMETRY_DEFAULT, { x: 0.3, y: 0.6 }, image)).toEqual({ x: 0.3, y: 0.6 });
    // A right turn: the output's top-left is the source's bottom-left.
    const p = sourcePoint(turned(GEOMETRY_DEFAULT, 1), { x: 0, y: 0 }, image);
    expect(p.x).toBeCloseTo(0);
    expect(p.y).toBeCloseTo(1);
  });

  it('straightening keeps the crop inside the frame', () => {
    const g = straightened(GEOMETRY_DEFAULT, 10, image);
    expect(fits(g, image)).toBe(true);
    expect(g.crop.width).toBeLessThan(1);
  });

  it('resizing with a lock keeps the ratio and the frame', () => {
    const g = constrained({ ...GEOMETRY_DEFAULT, aspect: 'square' }, image);
    expect((g.crop.width * image.width) / (g.crop.height * image.height)).toBeCloseTo(1, 4);
    const h = resized(g, 'bottomRight', { x: 1.2, y: 1.2 }, image);
    expect(fits(h, image)).toBe(true);
    expect((h.crop.width * image.width) / (h.crop.height * image.height)).toBeCloseTo(1, 4);
  });

  it('round-trips the Swift sidecar shape (CGSize as [w, h])', () => {
    const g = { ...randomGeometry(rng(5)), intendedSize: { width: 0.5, height: 0.4 }, aspect: 'r3x2' as const };
    const json = JSON.parse(JSON.stringify(encodeGeometry(g)));
    expect(json.intendedSize).toEqual([0.5, 0.4]);
    expect(decodeGeometry(json)).toEqual({ ...g, lockedRatio: null });
  });
});
