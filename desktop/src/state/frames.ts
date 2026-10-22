// frames.ts — the pixels on the canvas, outside the reactive store (a 45 MP
// frame is 180 MB; the store carries a version number instead).

import type { RenderReply, RgbaImage } from '../host/client';
import { imageData, preview8 } from '../canvas/colorSpace';

export const frameImages: {
  /** Display-tagged rgba8/rgba16; render_view already applied the grade and geometry. */
  print: RenderReply | null;
  /** Current decoded source, display-tagged; embedded preview only while loading. */
  original: RgbaImage | null;
} = { print: null, original: null };

export const THUMB_EDGE = 320;

/** rgba8 → a small JPEG object URL (for an <img>). */
export async function rgbaToURL(img: RgbaImage, longEdge = THUMB_EDGE): Promise<string | null> {
  try {
    const s = Math.min(1, longEdge / Math.max(img.width, img.height));
    const w = Math.max(1, Math.round(img.width * s));
    const h = Math.max(1, Math.round(img.height * s));
    const src = imageData(img.format === 'rgba16' ? preview8(img, w, h) : img);
    const bmp = await createImageBitmap(src, { resizeWidth: w, resizeHeight: h, resizeQuality: 'medium' });
    const canvas = new OffscreenCanvas(w, h);
    // Persist thumbnails as managed sRGB JPEGs so old runtimes and the OS
    // thumbnail cache can consume them too; drawImage performs the conversion.
    canvas.getContext('2d', { colorSpace: 'srgb' })!.drawImage(bmp, 0, 0);
    bmp.close();
    const blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.85 });
    return URL.createObjectURL(blob);
  } catch {
    return null;
  }
}

export const makeThumbFromPrint = (img: RgbaImage) => rgbaToURL(img);
