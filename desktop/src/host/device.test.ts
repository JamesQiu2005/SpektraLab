import { describe, expect, it } from 'vitest';
import { isSoftwareDevice } from './device';

describe('isSoftwareDevice', () => {
  it('recognises the software rasterizers that present themselves as Vulkan devices', () => {
    for (const name of ['llvmpipe (LLVM 17.0.6, 256 bits)', 'SwiftShader Device (Subzero)', 'Microsoft Basic Render Driver', 'Software Rasterizer', 'WARP'])
      expect(isSoftwareDevice(name), name).toBe(true);
  });
  it('takes hardware and unknown names as hardware', () => {
    for (const name of ['AMD Radeon RX 9070', 'NVIDIA GeForce RTX 4070', 'Intel(R) Arc(TM) A380 Graphics', 'Mock GPU', '', null, undefined])
      expect(isSoftwareDevice(name), String(name)).toBe(false);
  });
});
