import { describe, expect, it } from 'vitest';
import { clampZoom, minimumZoom, steppedZoom } from './zoom';

describe('manual viewport zoom', () => {
  it('crosses fit in either direction and shares the 5%–1600% limits with stepping', () => {
    expect(clampZoom(.2 * .8, .2)).toBeCloseTo(.16);
    expect(steppedZoom(.2, -1, .2)).toBe(.125);
    expect(steppedZoom(.0625, -1, .2)).toBe(.05);
    expect(steppedZoom(.05, -1, .2)).toBe(.05);
    expect(clampZoom(0, .2)).toBe(.05);
    expect(clampZoom(Infinity, .2)).toBe(16);
    expect(steppedZoom(16, 1, .2)).toBe(16);
    expect(steppedZoom(.125, 1, .2)).toBe(.25);
  });

  it('can shrink a very large image below fit and zoom back in with either control', () => {
    expect(minimumZoom(.02)).toBe(.01);
    expect(clampZoom(.015, .02)).toBe(.015);
    expect(steppedZoom(.02, -1, .02)).toBe(.01);
    expect(steppedZoom(.01, -1, .02)).toBe(.01);
    expect(steppedZoom(.01, 1, .02)).toBe(.05);
    expect(clampZoom(.01 * 2, .02)).toBe(.02);
  });
});
