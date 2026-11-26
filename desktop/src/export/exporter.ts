// exporter.ts — write the open frame through a recipe (`Export/Exporter.swift`).
//
// The file is the canvas's frame (trap 33): the engine's print, Layer 2, then
// the geometry. With the host's `write_image` (PROTOCOL-REQUESTS R1) the app
// renders `full` as rgba16 in the recipe's space, grades and crops it here —
// the same arithmetic as the canvas shader (`layer2Pixel`, `sourcePoint`) —
// and hands the pixels to the host, which embeds the ICC profile and lands
// the file whole. Without it, `export_image` writes the engine's print and the
// page says that the crop and the grade are not in the file.

import { WATERMARK_DEFAULT, blendWatermark } from '@shared/watermark';
import {
  type Adjustments,
  PROPHOTO_MID_GREY,
  ADOBE_MID_GREY,
  SRGB_MID_GREY,
  borderCode,
  borderPixels,
  curveTables,
  isNeutral,
  layer2Pixel,
  layer2Uniforms,
} from '@shared/adjustments';
import { type Geometry, isIdentity, outputSize, sourcePoint } from '@shared/geometry';
import type { FilmParams } from '@shared/params';
import type { StockCatalog } from '@shared/stocks';
import { host } from '../host/client';
import { baseName, dirName, joinPath, platform } from '../platform';
import { type ExistingPolicy, type ExportRecipe, extensionOf, hostFormat, resolveTarget, stem, stockToken } from './recipes';

/** Android: where exports land in shared storage (the gallery shows Pictures). */
export const SHARED_PICTURES = 'Pictures/Develop';
export const SHARED_DOWNLOADS = 'Download/Develop';
const MIME: Record<string, string> = { jpg: 'image/jpeg', png: 'image/png', tif: 'image/tiff', json: 'application/json' };
const mimeOf = (name: string) => MIME[/\.([^.]+)$/.exec(name)?.[1]?.toLowerCase() ?? ''] ?? 'application/octet-stream';

/**
 * Where a file goes. The host writes `write`; `finish` returns where the file ended up. On the desktop that is
 * the target in `dir` itself. On Android (platform().shared) `write` is in app storage and `finish` moves the
 * file to `sharedDir`, with the existing-file policy applied there. `also` does the same for a file written
 * beside it (an "Original + edits" export's edits), under `name`, replacing the app's own earlier copy.
 */
export type Destination =
  | { write: string; overwrite: boolean; finish(written: string): Promise<string>; also(written: string, name: string): Promise<string> }
  | { skipped: string };

export async function destination(dir: string, base: string, ext: string, policy: ExistingPolicy, sharedDir: string): Promise<Destination> {
  const sh = platform().shared;
  if (sh) {
    const t = await resolveTarget(sharedDir, base, ext, policy, (p) => sh.exists(dirName(p), baseName(p)), joinPath);
    if (!t) return { skipped: joinPath(sharedDir, `${base}.${ext}`) };
    // A folder of its own in app storage: a file left by an interrupted export never blocks this one
    // (export_di/export_cube do not overwrite). SharedStoragePlugin deletes each file, then the folder.
    const box = joinPath(await sh.staging(), `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`);
    await platform().ensureDir(box);
    const name = baseName(t.path);
    return {
      write: joinPath(box, name),
      overwrite: true,
      finish: (w) => sh.publish(w, sharedDir, name, mimeOf(name), t.overwrite),
      also: (w, n) => sh.publish(w, sharedDir, n, mimeOf(n), true),
    };
  }
  await platform().ensureDir(dir);
  const t = await resolveTarget(dir, base, ext, policy, (p) => platform().pathExists(p), joinPath);
  if (!t) return { skipped: joinPath(dir, `${base}.${ext}`) };
  return { write: t.path, overwrite: t.overwrite, finish: async (w) => w, also: async (w) => w };
}

/** A render reply's rgba16 pixels, without copying them when the payload sits at an even offset. */
export function rgba16(payload: Uint8Array, width: number, height: number): Uint16Array {
  const n = width * height * 4;
  return payload.byteOffset % 2 === 0
    ? new Uint16Array(payload.buffer, payload.byteOffset, n)
    : new Uint16Array(payload.buffer.slice(payload.byteOffset, payload.byteOffset + n * 2));
}

export interface FrameToExport {
  path: string;
  session: string;
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
  native: { width: number; height: number };
  dateTaken?: string;
}

export type ExportOutcome =
  | { kind: 'written'; path: string; width: number; height: number; carriesEdits: boolean }
  | { kind: 'skipped'; path: string }
  | { kind: 'failed'; message: string };

export function hostWrites(methods: readonly string[] | undefined): boolean {
  return !!methods?.includes('write_image');
}

export async function targetFor(r: ExportRecipe, f: FrameToExport, catalog: StockCatalog) {
  const dir0 = r.folder.kind === 'fixed' ? r.folder.path : dirName(f.path);
  const dir = r.subfolder.trim() ? joinPath(dir0, r.subfolder.trim()) : dir0;
  const name = baseName(f.path).replace(/\.[^.]+$/, '');
  const date = f.dateTaken ? new Date(f.dateTaken) : new Date();
  const base = stem(r, {
    originalName: name,
    filmStock: stockToken(catalog.stock(f.params.filmStock)?.name ?? f.params.filmStock),
    printStock: f.params.scanFilm ? 'Scan' : stockToken(catalog.stock(f.params.printStock)?.name ?? f.params.printStock),
    date: Number.isFinite(date.getTime()) ? date : new Date(),
  });
  return { dir, base };
}

/** The file's pixels: the print (rgba16) → geometry → Layer 2, at `out` size. */
export function filePixels(
  src: Uint16Array,
  srcSize: { width: number; height: number },
  g: Geometry,
  a: Adjustments,
  out: { width: number; height: number },
  midGrey: number,
): Uint16Array {
  const u = layer2Uniforms(a, midGrey);
  const tables = u.curvesActive ? curveTables(a.curves) : null;
  const { width: W, height: H } = srcSize;
  const res = new Uint16Array(out.width * out.height * 4);
  const k = 1 / 65535;
  for (let y = 0; y < out.height; y++) {
    for (let x = 0; x < out.width; x++) {
      const s = sourcePoint(g, { x: (x + 0.5) / out.width, y: (y + 0.5) / out.height }, srcSize);
      const fx = Math.min(Math.max(s.x * W - 0.5, 0), W - 1);
      const fy = Math.min(Math.max(s.y * H - 0.5, 0), H - 1);
      const x0 = Math.floor(fx);
      const y0 = Math.floor(fy);
      const x1 = Math.min(x0 + 1, W - 1);
      const y1 = Math.min(y0 + 1, H - 1);
      const tx = fx - x0;
      const ty = fy - y0;
      const c: [number, number, number] = [0, 0, 0];
      for (let ch = 0; ch < 3; ch++) {
        const p00 = src[(y0 * W + x0) * 4 + ch]!;
        const p01 = src[(y0 * W + x1) * 4 + ch]!;
        const p10 = src[(y1 * W + x0) * 4 + ch]!;
        const p11 = src[(y1 * W + x1) * 4 + ch]!;
        c[ch] = ((p00 * (1 - tx) + p01 * tx) * (1 - ty) + (p10 * (1 - tx) + p11 * tx) * ty) * k;
      }
      const [r, gg, b] = layer2Pixel(c, u, tables, s.x, s.y);
      const o = (y * out.width + x) * 4;
      res[o] = Math.round(r * 65535);
      res[o + 1] = Math.round(gg * 65535);
      res[o + 2] = Math.round(b * 65535);
      res[o + 3] = 65535;
    }
  }
  return res;
}

/**
 * The picture inside its border (Adjustments.border): a new plane, the border's grey round the
 * picture's pixels, which are copied unchanged. Returns the input when there is no border.
 */
export function withBorder(
  px: Uint16Array,
  size: { width: number; height: number },
  a: Adjustments,
  space: 'sRGB' | 'display-p3' | 'prophoto' | 'adobe-rgb',
): { px: Uint16Array; width: number; height: number } {
  const b = borderPixels(a.enabled ? a.border : undefined, size.width, size.height);
  if (!b.left && !b.top && !b.right && !b.bottom) return { px, ...size };
  const W = size.width + b.left + b.right;
  const H = size.height + b.top + b.bottom;
  const out = new Uint16Array(W * H * 4);
  const v = Math.round(borderCode(a.border.tone, space) * 65535);
  for (let i = 0; i < W * H; i++) {
    out[4 * i] = v;
    out[4 * i + 1] = v;
    out[4 * i + 2] = v;
    out[4 * i + 3] = 65535;
  }
  for (let y = 0; y < size.height; y++)
    out.set(px.subarray(y * size.width * 4, (y + 1) * size.width * 4), ((y + b.top) * W + b.left) * 4);
  return { px: out, width: W, height: H };
}

export function outputFor(r: ExportRecipe, g: Geometry, native: { width: number; height: number }) {
  const o = outputSize(g, native);
  if (!r.longEdge || r.longEdge >= Math.max(o.width, o.height)) return o;
  const k = r.longEdge / Math.max(o.width, o.height);
  return { width: Math.max(1, Math.round(o.width * k)), height: Math.max(1, Math.round(o.height * k)) };
}

export async function exportFrame(r: ExportRecipe, f: FrameToExport, catalog: StockCatalog, methods: readonly string[] | undefined): Promise<ExportOutcome> {
  try {
    const { dir, base } = await targetFor(r, f, catalog);
    const sub = r.subfolder.trim();
    // Android: pictures to Pictures/; "Original + edits" (a RAW and a .json, which Pictures/ refuses) to Download/.
    const shared = r.format === 'original' ? SHARED_DOWNLOADS : SHARED_PICTURES;
    const target = await destination(dir, base, extensionOf(r, f.path), r.existing, sub ? joinPath(shared, sub) : shared);
    if ('skipped' in target) return { kind: 'skipped', path: target.skipped };
    if (r.format === 'original') {
      const [first, ...rest] = await platform().exportOriginal(f.path, dirName(target.write), baseName(target.write), target.overwrite);
      const where = await target.finish(first!);
      // The edits are named after the copy as it was stored (Android may have changed its name).
      for (const p of rest) await target.also(p, p.endsWith('.spektra.json') ? `${baseName(where)}.spektra.json` : baseName(p));
      return { kind: 'written', path: where, width: 0, height: 0, carriesEdits: true };
    }
    if (r.format === 'di') {
      const res = await host().exportDi(f.session, f.params.printStock, target.write);
      return { kind: 'written', path: await target.finish(res.path), width: 0, height: 0, carriesEdits: false };
    }
    const edited = !isIdentity(f.geometry) || (f.adjustments.enabled && !isNeutral(f.adjustments));
    if (hostWrites(methods)) {
      const display = r.colorSpace === 'sRGB' ? 'srgb' : r.colorSpace;
      const rr = await host().transport.request(
        'render',
        { session: f.session, tier: 'full', format: 'rgba16', display },
        { timeoutMs: 1_800_000 },
      );
      const info = rr.result.image as { width: number; height: number; row_bytes: number };
      const src = rgba16(rr.payload, info.width, info.height);
      const out = outputFor(r, f.geometry, { width: info.width, height: info.height });
      const midGrey = r.colorSpace === 'prophoto' ? PROPHOTO_MID_GREY : r.colorSpace === 'adobe-rgb' ? ADOBE_MID_GREY : SRGB_MID_GREY;
      const picture = filePixels(src, { width: info.width, height: info.height }, f.geometry, f.adjustments, out, midGrey);
      const framed = withBorder(picture, out, f.adjustments, r.colorSpace);
      // The watermark over the picture, inside the border (watermark.ts), as the canvas draws it.
      {
        const b = borderPixels(f.adjustments.enabled ? f.adjustments.border : undefined, out.width, out.height);
        blendWatermark(framed.px, framed.width, framed.height, { x: b.left, y: b.top, width: out.width, height: out.height },
          f.adjustments.enabled ? f.adjustments.watermark : WATERMARK_DEFAULT, (tone) => borderCode(tone, r.colorSpace));
      }
      const w = await host().transport.request(
        'write_image',
        {
          path: target.write,
          format: hostFormat(r),
          quality: r.format === 'jpeg' ? r.quality : undefined,
          color_space: r.colorSpace,
          width: framed.width,
          height: framed.height,
          overwrite: target.overwrite,
          source_path: f.path,
        },
        { payload: new Uint8Array(framed.px.buffer), timeoutMs: 600_000 },
      );
      return { kind: 'written', path: await target.finish(String(w.result.path)), width: framed.width, height: framed.height, carriesEdits: true };
    }
    const res = await host().exportImage({
      session: f.session,
      path: target.write,
      format: hostFormat(r),
      quality: r.format === 'jpeg' ? r.quality : undefined,
      color_space: r.colorSpace,
      long_edge: r.longEdge || undefined,
      overwrite: target.overwrite,
    });
    return { kind: 'written', path: await target.finish(res.path), width: res.width, height: res.height, carriesEdits: !edited };
  } catch (e) {
    return { kind: 'failed', message: (e as Error).message };
  }
}

export async function exportCube(printStock: string, suggested: string): Promise<string | null> {
  if (platform().shared) {
    // Android: no save dialog that gives a path; the LUT goes to Download/Develop.
    const d = await destination('', suggested.replace(/\.cube$/i, ''), 'cube', 'addSuffix', SHARED_DOWNLOADS);
    if ('skipped' in d) return null;
    return d.finish((await host().exportCube(printStock, d.write)).path);
  }
  const p = await platform().pickSave('Export .cube', suggested, 'cube');
  if (!p) return null;
  const r = await host().exportCube(printStock, p);
  return r.path;
}
