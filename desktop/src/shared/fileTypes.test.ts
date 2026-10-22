import { describe, expect, it } from 'vitest';
import rust from '../../src-tauri/src/files.rs?raw';
import cpp from '../../../engine/host/image_io.cpp?raw';
import { RAW_EXTENSIONS, RASTER_EXTENSIONS, PHOTO_PICKER_EXTENSIONS } from './fileTypes';
import { decodeWire, isRawPath } from './whiteBalance';
import { DECODE_DEFAULT } from './sidecar';

describe('photograph routing across picker, directory scan and native decoder', () => {
  it('keeps the desktop accepted extensions and native RAW routing in sync', () => {
    const listed = [...rust.match(/pub const IMAGE_EXTENSIONS[^=]*=\s*&\[([\s\S]*?)\];/)![1]!.matchAll(/"([a-z0-9]+)"/g)].map((m) => m[1]);
    const routed = [...cpp.match(/raw_exts\[\]\s*=\s*\{([\s\S]*?)\};/)![1]!.matchAll(/"\.([a-z0-9]+)"/g)].map((m) => m[1]);
    expect(listed.sort()).toEqual([...RAW_EXTENSIONS, ...RASTER_EXTENSIONS].sort());
    expect(routed.sort()).toEqual([...RAW_EXTENSIONS].sort());
  });
  it.each(['IIQ', '3FR', 'FFF', 'GPR', 'MEF', 'ARI', 'BAY', 'K25'])('includes %s in the picker and sends restored decode settings on the first open', (ext) => {
    expect(PHOTO_PICKER_EXTENSIONS).toContain(ext);
    const raw = isRawPath(`D:/照片/Camera.${ext}`);
    expect(raw).toBe(true);
    expect(decodeWire({ ...DECODE_DEFAULT, whiteBalance: 'Custom', temperature: 6200, tint: 8, lensCorrection: true }, raw))
      .toEqual({ white_balance: { mode: 'custom', temperature_k: 6200, tint: 8 }, lens_correction: true });
  });
  it.each(RASTER_EXTENSIONS)('keeps %s out of the RAW decode settings route', (ext) => {
    expect(PHOTO_PICKER_EXTENSIONS).toContain(ext);
    expect(decodeWire(DECODE_DEFAULT, isRawPath(`/photo.${ext.toUpperCase()}`))).toBeNull();
  });
});
