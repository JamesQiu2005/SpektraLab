import { describe, expect, it } from 'vitest';
import { GEOMETRY_DEFAULT, sourcePoint, type Geometry } from '@shared/geometry';
import { processedImageMap } from './glRenderer';

const native = { width: 7028, height: 4688 };
const mapped = (m: Float32Array, p: { x: number; y: number }) => ({
  x: m[0]! * p.x + m[3]! * p.y + m[6]!,
  y: m[1]! * p.x + m[4]! * p.y + m[7]!,
});

describe('backend processed preview geometry', () => {
  it('does not crop, rotate, or flip a processed frame twice', () => {
    for (let turns = 0; turns < 4; ++turns) {
      for (let flips = 0; flips < 4; ++flips) {
        const g: Geometry = { ...GEOMETRY_DEFAULT, crop: { x: 0.17, y: 0.11, width: 0.61, height: 0.72 },
          angle: 7.5, quarterTurns: turns, flipH: !!(flips & 1), flipV: !!(flips & 2) };
        const matrix = processedImageMap(g, native);
        for (const output of [{ x: 0.01, y: 0.99 }, { x: 0.8, y: 0.2 }, { x: 0.5, y: 0.5 }]) {
          const sample = mapped(matrix, sourcePoint(g, output, native));
          expect(sample.x).toBeCloseTo(output.x, 5);
          expect(sample.y).toBeCloseTo(output.y, 5);
        }
      }
    }
  });

  it('keeps cropped stale frames located in the source while the crop editor opens', () => {
    const g: Geometry = { ...GEOMETRY_DEFAULT, crop: { x: 0.25, y: 0.25, width: 0.5, height: 0.5 } };
    const matrix = processedImageMap(g, native);
    expect(mapped(matrix, { x: 0.25, y: 0.25 })).toEqual({ x: 0, y: 0 });
    expect(mapped(matrix, { x: 0.75, y: 0.75 })).toEqual({ x: 1, y: 1 });
    expect(mapped(matrix, { x: 0.1, y: 0.1 }).x).toBeLessThan(0);
  });

  it('leaves unprocessed original and legacy frames in source coordinates', () => {
    expect(mapped(processedImageMap(undefined, native), { x: 0.3, y: 0.7 })).toEqual({ x: 0.3, y: 0.7 });
  });
});
