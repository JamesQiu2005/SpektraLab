// Export immutable frame settings. The host grades, crops, converts colour
// and writes atomically; full-resolution pixels never enter the webview.

import { type Adjustments, curveTables, isNeutral, layer2Pixel, layer2Uniforms } from '@shared/adjustments';
import { type Geometry, isIdentity, outputSize, sourcePoint } from '@shared/geometry';
import { type FilmParams, type FeatureGate, filmFormatMM, fullDelta } from '@shared/params';
import { type DecodeSettings, type Sidecar, decodeSidecar, newSidecar } from '@shared/sidecar';
import { decodeWire, isRawPath } from '@shared/whiteBalance';
import type { StockCatalog } from '@shared/stocks';
import { host } from '../host/client';
import { baseName, dirName, joinPath, platform } from '../platform';
import { type ExportRecipe, extensionOf, hostFormat, resolveTarget, stem, stockToken } from './recipes';

export interface FrameToExport {
  path: string;
  session?: string;
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
  decode: DecodeSettings;
  gate: FeatureGate;
  native?: { width: number; height: number };
  dateTaken?: string;
}

export type ExportOutcome =
  | { kind: 'written'; path: string; width: number; height: number; carriesEdits: boolean }
  | { kind: 'skipped'; path: string }
  | { kind: 'cancelled' }
  | { kind: 'failed'; message: string };

export function hostWrites(methods: readonly string[] | undefined): boolean {
  return !!methods?.includes('export_frame');
}

export async function targetFor(r: ExportRecipe, f: Pick<FrameToExport, 'path' | 'params' | 'dateTaken'>, catalog: StockCatalog) {
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

export interface SelectedExportFrame {
  path: string;
  sidecar: Sidecar;
  session?: string;
  native?: { width: number; height: number };
  dateTaken?: string;
}

export type PreparedExportFrame = { path: string; frame: FrameToExport } | { path: string; error: string };

/** Freeze every frame before starting the batch, without opening it in the
 * editor or saving derived settings back to its sidecar. Only small metadata
 * is retained; the host opens and releases each private image in sequence. */
export async function captureExportFrames(
  paths: readonly string[], selected: SelectedExportFrame | null, catalog: StockCatalog,
  gate: FeatureGate, recalculateEffectsAfterCrop: boolean, cancelled: () => boolean = () => false,
): Promise<PreparedExportFrame[]> {
  const current = selected ? structuredClone(selected) : null;
  const frozenGate = structuredClone(gate);
  const result: PreparedExportFrame[] = [];
  for (const path of [...paths]) {
    if (cancelled()) break;
    try {
      const active = path === current?.path ? current : null;
      const saved = active ? null : await platform().sidecarLoad(path);
      const sidecar = active?.sidecar ?? structuredClone(saved == null ? newSidecar() : decodeSidecar(saved));
      const info = active?.native ? null : await host().probe(path);
      const native = active?.native ?? (info ? { width: info.width, height: info.height } : undefined);
      if (!native || native.width <= 0 || native.height <= 0) throw new Error('The photograph has no usable dimensions.');
      // Opening a positive film in the editor applies this same repair.
      const params = { ...sidecar.params, scanFilm: sidecar.params.scanFilm || catalog.isPositive(sidecar.params.filmStock) };
      const size = recalculateEffectsAfterCrop ? outputSize(sidecar.geometry, native) : native;
      const aspect = Math.max(size.width, size.height) / Math.max(1, Math.min(size.width, size.height));
      const crop = sidecar.geometry.crop;
      const cropScale = recalculateEffectsAfterCrop ? 1 / Math.max(crop.width, crop.height, 1e-3) : 1;
      params.filmFormatMM = filmFormatMM(params.filmSide, params.sideLengthMM, aspect, cropScale);
      result.push({ path, frame: structuredClone({
        path, session: active?.session, params, adjustments: sidecar.adjustments,
        geometry: sidecar.geometry, decode: sidecar.decode, gate: frozenGate, native,
        dateTaken: active?.dateTaken ?? info?.metadata.datetime_original,
      }) });
    } catch (e) {
      // An unreadable sidecar must never silently turn into a default export.
      result.push({ path, error: e instanceof Error ? e.message : String(e) });
    }
  }
  return result;
}

/** Legacy CPU reference for surface tests. Production export uses export_frame. */
export function filePixels(
  src: Uint16Array,
  srcSize: { width: number; height: number },
  g: Geometry,
  a: Adjustments,
  out: { width: number; height: number },
  midGrey: number,
): Uint16Array {
  // The neutral full-size export is already the file's RGB16. Running the
  // sampler and the whole grade for every pixel cost ~5 s for 33 MP. Keep an
  // independent result and the same opaque alpha as the general path.
  if (isIdentity(g) && (!a.enabled || isNeutral(a)) && out.width === srcSize.width && out.height === srcSize.height) {
    const copy = src.slice(0, out.width * out.height * 4);
    for (let i = 3; i < copy.length; i += 4) copy[i] = 65535;
    return copy;
  }
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

export function outputFor(r: ExportRecipe, g: Geometry, native: { width: number; height: number }) {
  const o = outputSize(g, native);
  if (!r.longEdge || r.longEdge >= Math.max(o.width, o.height)) return o;
  const k = r.longEdge / Math.max(o.width, o.height);
  return { width: Math.max(1, Math.round(o.width * k)), height: Math.max(1, Math.round(o.height * k)) };
}

export interface ExportJob {
  session: string;
  progressId: string;
}
export interface ExportControl {
  cancelled?: () => boolean;
  active?: (job: ExportJob | null) => void;
}
let exportSerial = 0;

export async function exportFrame(
  recipe: ExportRecipe, frame: FrameToExport, catalog: StockCatalog,
  methods: readonly string[] | undefined, control: ExportControl = {},
): Promise<ExportOutcome> {
  // Freeze synchronously, before directory/name resolution yields to the UI.
  const r = structuredClone(recipe);
  const f = structuredClone(frame);
  const started = performance.now();
  const cancelled = () => control.cancelled?.() ?? false;
  try {
    if (cancelled()) return { kind: 'cancelled' };
    if (r.format === 'di') {
      if (!methods?.includes('export_di') || !f.gate.digitalIntermediate)
        throw new Error('This engine cannot export Digital Intermediate files.');
    } else if (!hostWrites(methods)) {
      throw new Error('This engine does not support complete frame export (export_frame). Update the engine before exporting.');
    }
    const { dir, base } = await targetFor(r, f, catalog);
    await platform().ensureDir(dir);
    const target = await resolveTarget(dir, base, extensionOf(r), r.existing, (p) => platform().pathExists(p), joinPath);
    if (cancelled()) return { kind: 'cancelled' };
    if (!target) return { kind: 'skipped', path: joinPath(dir, `${base}.${extensionOf(r)}`) };
    const params = fullDelta(f.params, f.gate);
    const decode = decodeWire(f.decode, isRawPath(f.path));
    if (r.format === 'di') {
      // DI is a density intermediate, intentionally without display grading
      // or crop. Its independent session keeps editor settings/cache intact.
      const opened = await host().open(f.path, params, decode);
      try {
        if (cancelled()) return { kind: 'cancelled' };
        const res = await host().transport.request('export_di', {
          session: opened.session, print_stock: f.params.printStock,
          path: target.path, overwrite: target.overwrite,
        }, { timeoutMs: 1_800_000 });
        return { kind: 'written', path: String(res.result.path), width: opened.width, height: opened.height, carriesEdits: false };
      } finally {
        await host().close(opened.session);
      }
    }
    const job = { session: f.session ?? '', progressId: `export-${Date.now()}-${++exportSerial}` };
    control.active?.(job);
    const res = await host().transport.request('export_frame', {
      session: f.session, source_path: f.path, params, decode: decode ?? undefined,
      adjustments: f.adjustments, geometry: f.geometry,
      path: target.path, format: hostFormat(r), quality: r.format === 'jpeg' ? r.quality : undefined,
      color_space: r.colorSpace, long_edge: r.longEdge, overwrite: target.overwrite, progress_id: job.progressId,
    }, { timeoutMs: 1_800_000 });
    if (res.payload.byteLength) throw new Error('export_frame unexpectedly returned image data.');
    const { path, width, height, timings_ms } = res.result;
    if (typeof path !== 'string' || typeof width !== 'number' || typeof height !== 'number' || width <= 0 || height <= 0)
      throw new Error('The engine returned invalid export dimensions.');
    platform().log('info', `export (${hostFormat(r)}, ${width}x${height}) host ms: ${JSON.stringify(timings_ms ?? {})} · TOTAL ${Math.round(performance.now() - started)}`);
    return { kind: 'written', path, width, height, carriesEdits: true };
  } catch (e) {
    if (cancelled() && (e as { code?: string }).code === 'cancelled') return { kind: 'cancelled' };
    return { kind: 'failed', message: e instanceof Error ? e.message : String(e) };
  } finally {
    control.active?.(null);
  }
}
export async function exportCube(printStock: string, suggested: string): Promise<string | null> {
  const p = await platform().pickSave('Export .cube', suggested, 'cube');
  if (!p) return null;
  const r = await host().exportCube(printStock, p);
  return r.path;
}
