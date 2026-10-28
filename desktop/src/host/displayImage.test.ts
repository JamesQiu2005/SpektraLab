import { describe, expect, it } from 'vitest';
import { displayImage } from './client';
import { preview8 } from '../canvas/colorSpace';

describe('high precision display transport', () => {
  it('retains every little-endian UNORM16 code and removes row padding', () => {
    const payload = new Uint8Array(24);
    const view = new DataView(payload.buffer);
    [1, 257, 12345, 65535].forEach((v, i) => view.setUint16(i * 2, v, true));
    [65534, 1024, 34567, 65535].forEach((v, i) => view.setUint16(12 + i * 2, v, true));
    const image = displayImage({ width: 1, height: 2, row_bytes: 12, format: 'rgba16', color_space: 'Display P3' }, payload);
    expect(image.format).toBe('rgba16');
    expect([...new Uint16Array(image.data.buffer)]).toEqual([1, 257, 12345, 65535, 65534, 1024, 34567, 65535]);
    expect(image.colorSpace).toBe('Display P3');
  });

  it('refuses partial rows, missing pixels and invalid dimensions', () => {
    for (const info of [
      { width: 2, height: 1, row_bytes: 8 }, { width: 1, height: 2, row_bytes: 8 },
      { width: 0, height: 1, row_bytes: 8 }, { width: 1.5, height: 1, row_bytes: 8 },
    ]) expect(() => displayImage({ ...info, format: 'rgba16', color_space: 'sRGB' }, new Uint8Array(8))).toThrow();
  });

  it('downsamples a 16-bit thumbnail before converting it to eight bits', () => {
    const codes = new Uint16Array([0, 2570, 65535, 65535, 65535, 5140, 0, 65535]);
    const small = preview8({ width: 2, height: 1, data: new Uint8Array(codes.buffer), format: 'rgba16', colorSpace: 'Display P3' }, 1, 1);
    expect([...small.data]).toEqual([128, 15, 128, 255]);
    expect(small.format).toBe('rgba8');
    expect(small.colorSpace).toBe('Display P3');
    expect([...codes]).toEqual([0, 2570, 65535, 65535, 65535, 5140, 0, 65535]);
  });
});
