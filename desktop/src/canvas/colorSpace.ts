// Preview encodings are independent of the linear ProPhoto working space.
// Never attach an sRGB label to unconverted P3 byte values.
import type { DisplaySpace } from '@shared/protocol';

export type PreviewGamut = 'auto' | 'srgb' | 'display-p3';
export interface PreviewPixels {
  width: number;
  height: number;
  data: Uint8Array;
  /** Untagged legacy previews are sRGB. */
  colorSpace?: string;
}

export function resolveDisplaySpace(pref: PreviewGamut, p3Supported: boolean, wideScreen: boolean): DisplaySpace {
  return p3Supported && (pref === 'display-p3' || (pref === 'auto' && wideScreen)) ? 'display-p3' : 'srgb';
}

export function previewSpace(tag?: string): DisplaySpace {
  switch ((tag ?? 'srgb').toLowerCase()) {
    case 'srgb': return 'srgb';
    case 'display-p3': case 'display p3': case 'p3': return 'display-p3';
    default: throw new Error(`Unsupported preview colour space: ${tag}`);
  }
}

const decode = (v: number) => v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
const encode = (v: number) => Math.round(255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * v ** (1 / 2.4) - 0.055));

/** Fallback only: D65 linear Display P3 → XYZ → sRGB, then the sRGB curve.
 * Matrix product from https://www.w3.org/TR/css-color-4/#color-conversion-code.
 * Out-of-sRGB colours are clipped only here, at the fallback display boundary.
 */
export function p3ToSrgb(data: Uint8Array): Uint8ClampedArray<ArrayBuffer> {
  const out = new Uint8ClampedArray(data.length);
  for (let i = 0; i < data.length; i += 4) {
    const r = decode(data[i]! / 255), g = decode(data[i + 1]! / 255), b = decode(data[i + 2]! / 255);
    out[i] = encode(1.2249401762805596 * r - 0.22494017628055993 * g);
    out[i + 1] = encode(-0.04205695470968818 * r + 1.0420569547096883 * g);
    out[i + 2] = encode(-0.019637554590334436 * r - 0.07863604555063189 * g + 1.0982736001409663 * b);
    out[i + 3] = data[i + 3]!;
  }
  return out;
}

export function imageData(img: PreviewPixels): ImageData {
  const space = previewSpace(img.colorSpace);
  if (space === 'display-p3') {
    try {
      const tagged = new ImageData(new Uint8ClampedArray(img.data), img.width, img.height, { colorSpace: space });
      // Older runtimes can silently ignore the settings object.
      if (tagged.colorSpace === 'display-p3') return tagged;
    } catch { /* Unsupported ImageData settings: numerically convert below. */ }
    return new ImageData(p3ToSrgb(img.data), img.width, img.height);
  }
  return new ImageData(new Uint8ClampedArray(img.data), img.width, img.height);
}

/** 2D surfaces use the ImageData's tag; putImageData converts to the context. */
export function paintOutput(canvas: HTMLCanvasElement, img: PreviewPixels): boolean {
  const pixels = imageData(img);
  canvas.width = img.width;
  canvas.height = img.height;
  let ctx: CanvasRenderingContext2D | null;
  try {
    ctx = canvas.getContext('2d', { colorSpace: pixels.colorSpace ?? 'srgb' });
  } catch {
    ctx = canvas.getContext('2d');
  }
  if (!ctx) return false;
  ctx.putImageData(pixels, 0, 0);
  return true;
}
