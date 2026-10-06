// frames.ts — the pixels on the canvas, outside the reactive store (a 45 MP
// frame is 180 MB; the store carries a version number instead).

import type { RenderReply, RgbaImage } from '../host/client';

export const frameImages: {
  /** The engine's print at the tier it was rendered (sRGB-encoded rgba8). */
  print: RenderReply | null;
  /** The decode as the camera's embedded preview shows it (Original, Before). */
  original: RgbaImage | null;
} = { print: null, original: null };

export const THUMB_EDGE = 320;

/** rgba8 → a small JPEG object URL (for an <img>). */
export async function rgbaToURL(img: RgbaImage, longEdge = THUMB_EDGE): Promise<string | null> {
  try {
    const s = Math.min(1, longEdge / Math.max(img.width, img.height));
    const w = Math.max(1, Math.round(img.width * s));
    const h = Math.max(1, Math.round(img.height * s));
    const src = new ImageData(new Uint8ClampedArray(img.data.buffer as ArrayBuffer, img.data.byteOffset, img.width * img.height * 4), img.width, img.height);
    const bmp = await createImageBitmap(src, { resizeWidth: w, resizeHeight: h, resizeQuality: 'medium' });
    const canvas = new OffscreenCanvas(w, h);
    canvas.getContext('2d')!.drawImage(bmp, 0, 0);
    bmp.close();
    const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.85 });
    return URL.createObjectURL(blob);
  } catch {
    return null;
  }
}

export const makeThumbFromPrint = (img: RgbaImage) => rgbaToURL(img);
