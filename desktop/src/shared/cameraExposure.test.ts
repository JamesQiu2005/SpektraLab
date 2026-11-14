import { describe, expect, it } from 'vitest';
import { cameraExposureEV, type CameraExposureImage } from './cameraExposure';

export function gray(value: number, width = 32, height = 32): CameraExposureImage {
  const encoded = value <= .0031308 ? 12.92 * value : 1.055 * value ** (1 / 2.4) - .055;
  const data = new Uint8Array(width * height * 4).fill(Math.round(255 * encoded));
  for (let i = 3; i < data.length; i += 4) data[i] = 255;
  return { width, height, data };
}

describe('camera preview exposure', () => {
  it('measures linear light rather than the ratio of display codes, in both directions', () => {
    expect(cameraExposureEV(gray(.06), gray(.18))).toBeCloseTo(Math.log2(3), 1);
    expect(cameraExposureEV(gray(.36), gray(.18))).toBeCloseTo(-1, 1);
    expect(cameraExposureEV(gray(.18), gray(.18))).toBe(0);
  });
  it('uses a scalar despite differently sized previews and ignores bright and dark tails', () => {
    const source = gray(.06), camera = gray(.18, 64, 64);
    for (let i = 0; i < source.data.length / 10; i += 4) source.data.fill(0, i, i + 3);
    for (let i = 0; i < camera.data.length / 10; i += 4) camera.data.fill(255, i, i + 3);
    expect(cameraExposureEV(source, camera)).toBeCloseTo(Math.log2(3), 1);
  });
  it('refuses an empty, clipped, transparent, or differently cropped reference', () => {
    expect(cameraExposureEV(gray(.06), gray(0))).toBeNull();
    expect(cameraExposureEV(gray(.06), gray(1))).toBeNull();
    expect(cameraExposureEV(gray(0), gray(.18))).toBeNull();
    expect(cameraExposureEV(gray(.06), gray(.18, 64, 32))).toBeNull();
    expect(cameraExposureEV(gray(.06), { width: 32, height: 32, data: new Uint8Array() })).toBeNull();
    const transparent = gray(.18); transparent.data[3] = 0;
    expect(cameraExposureEV(gray(.06), transparent)).toBeNull();
  });
});
