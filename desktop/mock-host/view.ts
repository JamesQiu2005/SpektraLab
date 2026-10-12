// UI mock only: synthetic sRGB print → mock grade → geometry → preview gamut.
// Exercises the processed-view protocol, never an oracle for the ProPhoto GPU.
import { ADJUSTMENTS_DEFAULT, applyLayer2, isNeutral, SRGB_MID_GREY, type Adjustments } from '../src/shared/adjustments.ts';
import { GEOMETRY_DEFAULT, isIdentity, outputSize, type Geometry } from '../src/shared/geometry.ts';
import { resampleOutput } from '../src/shared/surfaces.ts';

export function mockView(src: Uint8Array, width: number, height: number,
  adjustments: Adjustments = ADJUSTMENTS_DEFAULT, geometry: Geometry = GEOMETRY_DEFAULT, display = 'srgb', longEdge = 0) {
  let data: Uint8Array = src;
  if (adjustments.enabled && !isNeutral(adjustments)) {
    const grade = Float32Array.from(src, (v) => v / 255);
    applyLayer2(grade, width, height, adjustments, SRGB_MID_GREY);
    data = Uint8Array.from(grade, (v) => Math.max(0, Math.min(255, Math.round(v * 255))));
  }
  const out = outputSize(geometry, { width, height });
  if (longEdge > 0 && Math.max(out.width, out.height) > longEdge) {
    const scale = longEdge / Math.max(out.width, out.height);
    out.width = Math.max(1, Math.round(out.width * scale));
    out.height = Math.max(1, Math.round(out.height * scale));
  }
  if (!isIdentity(geometry) || out.width !== width || out.height !== height)
    data = resampleOutput(data, { width, height }, geometry, out.width, out.height, (n) => new Uint8Array(n));
  if (display === 'display-p3') data = srgbToP3(data);
  return { ...out, data };
}

function srgbToP3(src: Uint8Array): Uint8Array {
  const out = new Uint8Array(src.length);
  const decode = (v: number) => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  const encode = (v: number) => Math.max(0, Math.min(255, Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055))));
  // CSS Color 4 D65 XYZ matrices, composed for linear sRGB → Display P3.
  for (let i = 0; i < src.length; i += 4) {
    const r = decode(src[i]! / 255), g = decode(src[i + 1]! / 255), b = decode(src[i + 2]! / 255);
    out[i] = encode(0.8224619687143623 * r + 0.17753803128563772 * g);
    out[i + 1] = encode(0.03319419885096158 * r + 0.9668058011490382 * g);
    out[i + 2] = encode(0.017082630721120033 * r + 0.07239744066396347 * g + 0.9105199286149166 * b);
    out[i + 3] = src[i + 3]!;
  }
  return out;
}
