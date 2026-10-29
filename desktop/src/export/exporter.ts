// Export immutable frame settings. The host grades, crops, converts colour
// and writes atomically; full-resolution pixels never enter the webview.

import { type Adjustments, curveTables, isNeutral, layer2Pixel, layer2Uniforms } from '@shared/adjustments';
import { type Geometry, GEOMETRY_DEFAULT, isIdentity, outputSize, sourcePoint } from '@shared/geometry';
import { canvasGeometryFor, resolveFilmEdgeParams, sourceGeometryFor } from '@shared/filmEdge';
import type { FileMetadata, PairInfo } from '@shared/protocol';
import { decodePair, isPairPath, pairFitRegion, pairSnapshotFor, resolvePairParams, sourcePairLayout, type HalfFramePair } from '@shared/pair';
import { type FilmParams, type FeatureGate, filmFormatMM, fullDelta, normalizeStockPair } from '@shared/params';
import { type DecodeSettings, type Sidecar, decodeSidecar, newSidecar } from '@shared/sidecar';
import { decodeWire, isRawPath } from '@shared/whiteBalance';
import type { StockCatalog } from '@shared/stocks';
import { latitudeRequest } from '@shared/latitude';
import { tz } from '../i18n';
import { host } from '../host/client';
import { baseName, dirName, joinPath, platform } from '../platform';
import { type ExportRecipe, extensionOf, hostFormat, resolveTarget, stem, stockToken } from './recipes';

export interface FrameToExport {
  path: string;
  session?: string;
  noFilm: boolean;
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
  /** Dedicated Cineon exports always use the negative's framing, even when
   * the ordinary photo preview bypasses film simulation. */
  filmGeometry: Geometry;
  filmSourceGeometry: Geometry;
  decode: DecodeSettings;
  gate: FeatureGate;
  native?: { width: number; height: number };
  dateTaken?: string;
  scenePlacement?: Record<string, unknown>;
  scenePlacementSide?: 'right';
  sourceGeometry?: Geometry;
  pair?: HalfFramePair & { printEffects?: boolean };
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
  metadata?: FileMetadata | null;
  pair?: HalfFramePair | null;
  pairInfo?: PairInfo | null;
}

export type PreparedExportFrame = { path: string; frame: FrameToExport } | { path: string; error: string };

function snapshotGeometry(sidecar: Sidecar, params: FilmParams, gate: FeatureGate) {
  const noFilm = sidecar.noFilm === true;
  return {
    noFilm,
    geometry: canvasGeometryFor(params, sidecar.geometry, gate, noFilm),
    sourceGeometry: sourceGeometryFor(params, sidecar.geometry, gate, noFilm) ?? GEOMETRY_DEFAULT,
    filmGeometry: canvasGeometryFor(params, sidecar.geometry, gate),
    filmSourceGeometry: sourceGeometryFor(params, sidecar.geometry, gate) ?? GEOMETRY_DEFAULT,
  };
}

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
      if (isPairPath(path)) {
        const pair = active?.pair ?? decodePair(await platform().pairLoad(path));
        if (!pair) throw new Error(tz('The half-frame pair recipe cannot be read.', '无法读取半格拼接配方。'));
        const shots: PairInfo = {};
        for (const side of ['left', 'right'] as const) {
          const hole = pair[side];
          if (!hole) throw new Error(tz('Fill both half-frame holes before exporting.', '导出半格拼接前，请先填满两格。'));
          const known = active?.pairInfo?.[side];
          shots[side] = known ?? { ...(await host().probe(hole.path)), available: true };
          if (!shots[side]?.available) throw new Error(shots[side]?.error ?? tz('A half-frame photograph cannot be read.', '无法读取半格中的照片。'));
        }
        const native = sourcePairLayout(pair, { left: shots.left, right: shots.right }).size;
        const params = resolvePairParams(normalizeStockPair(sidecar.params, catalog), pair,
          shots.left?.metadata ?? null, shots.right?.metadata ?? null, catalog);
        result.push({ path, frame: structuredClone({ path, session: active?.session, params,
          adjustments: sidecar.adjustments, ...snapshotGeometry(sidecar, params, frozenGate),
          decode: sidecar.decode, gate: frozenGate, native, pair: pairSnapshotFor(pair, params),
          dateTaken: shots.left?.metadata?.datetime_original ?? shots.right?.metadata?.datetime_original,
          scenePlacement: sidecar.placementNeedsFit ? { ...latitudeRequest(params.sceneLatitude), region: pairFitRegion(pair, params.placementIsRight) } : undefined,
          scenePlacementSide: sidecar.placementNeedsFit && params.placementIsRight ? 'right' : undefined,
        }) });
        continue;
      }
      const info = active?.native && active.metadata !== undefined ? null : await host().probe(path);
      const native = active?.native ?? (info ? { width: info.width, height: info.height } : undefined);
      if (!native || native.width <= 0 || native.height <= 0) throw new Error(tz('The photograph has no usable dimensions.', '这张照片没有可用的尺寸。'));
      let params = { ...normalizeStockPair(sidecar.params, catalog) };
      const size = recalculateEffectsAfterCrop ? outputSize(sidecar.geometry, native) : native;
      const aspect = Math.max(size.width, size.height) / Math.max(1, Math.min(size.width, size.height));
      const crop = sidecar.geometry.crop;
      const cropScale = recalculateEffectsAfterCrop ? 1 / Math.max(crop.width, crop.height, 1e-3) : 1;
      params.filmFormatMM = filmFormatMM(params.filmSide, params.sideLengthMM, aspect, cropScale);
      params = resolveFilmEdgeParams(params, sidecar.geometry, active?.metadata ?? info?.metadata ?? null, catalog, native);
      result.push({ path, frame: structuredClone({
        path, session: active?.session, params, adjustments: sidecar.adjustments,
        ...snapshotGeometry(sidecar, params, frozenGate),
        decode: sidecar.decode, gate: frozenGate, native,
        dateTaken: active?.dateTaken ?? info?.metadata.datetime_original,
        scenePlacement: sidecar.placementNeedsFit ? latitudeRequest(params.placementIsRight ? params.sceneLatitudeOther : params.sceneLatitude) : undefined,
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
  tiffOptions?: readonly string[];
  frameOptions?: readonly string[];
  cancelled?: () => boolean;
  active?: (job: ExportJob | null) => void;
}
let exportSerial = 0;

/** Ordinary output follows the saved display mode. DI requires film simulation
 * and uses the negative's film-side geometry and placement. */
function recipeView(r: ExportRecipe, f: FrameToExport, control: ExportControl) {
  const di = r.format === 'di', noFilm = !di && f.noFilm;
  if (di && f.noFilm) throw new Error('Enable film simulation before exporting a Digital Intermediate.');
  if (noFilm) {
    if (f.pair || isPairPath(f.path) || f.params.filmEdge.pair)
      throw new Error('Export without film simulation is unavailable for half-frame pairs. Enable film simulation.');
    if (!(control.frameOptions ? control.frameOptions.includes('no-film') : f.gate.noFilm))
      throw new Error('This engine cannot export without film simulation. Update the engine or enable film simulation.');
  }
  return {
    ...(noFilm ? { no_film: true } : {}),
    geometry: di ? f.filmGeometry : f.geometry,
    source_geometry: di ? f.filmSourceGeometry : f.sourceGeometry ?? GEOMETRY_DEFAULT,
    scene_placement: noFilm ? undefined : f.scenePlacement,
    scene_placement_side: noFilm ? undefined : f.scenePlacementSide,
  };
}

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
    const view = recipeView(r, f, control);
    if (f.pair && !methods?.includes('open_pair')) throw new Error(tz('This engine cannot export half-frame pairs. Update the engine.', '此引擎无法导出半格拼接，请更新引擎。'));
    if ((r.format === 'tiff' || r.format === 'di') &&
        ((r.tiffCompression === 'lzw' && !control.tiffOptions?.includes('lzw')) ||
         (r.format === 'tiff' && r.embedsPreview && !control.tiffOptions?.includes('preview-page'))))
      throw new Error(tz('This engine does not support the selected TIFF compression or preview page. Update the engine.', '此引擎不支持所选的 TIFF 压缩或预览页，请更新引擎。'));
    if (r.format === 'di') {
      if (!methods?.includes('export_cineon') || !f.gate.digitalIntermediate)
        throw new Error(tz('This engine cannot export Cineon Digital Intermediate files.', '此引擎无法导出 Cineon 数字中间片文件。'));
    } else if (!hostWrites(methods)) {
      throw new Error(tz('This engine does not support complete frame export (export_frame). Update the engine before exporting.', '此引擎不支持完整画面导出（export_frame），请更新引擎后再导出。'));
    }
    const { dir, base } = await targetFor(r, f, catalog);
    await platform().ensureDir(dir);
    const target = await resolveTarget(dir, base, extensionOf(r), r.existing, (p) => platform().pathExists(p), joinPath);
    if (cancelled()) return { kind: 'cancelled' };
    if (!target) return { kind: 'skipped', path: joinPath(dir, `${base}.${extensionOf(r)}`) };
    const params = fullDelta(f.params, f.gate, catalog);
    const decode = decodeWire(f.decode, isRawPath(f.path));
    const job = { session: f.session ?? '', progressId: `export-${Date.now()}-${++exportSerial}` };
    control.active?.(job);
    const res = await host().transport.request(r.format === 'di' ? 'export_cineon' : 'export_frame', {
      session: f.session, source_path: f.path, params, decode: decode ?? undefined,
      adjustments: f.adjustments, ...view,
      pair: f.pair,
      path: target.path, format: hostFormat(r), quality: r.format === 'jpeg' ? r.quality : undefined,
      tiff_compression: r.format === 'tiff' || r.format === 'di' ? r.tiffCompression ?? 'none' : undefined,
      embed_preview: r.format === 'tiff' ? r.embedsPreview ?? false : undefined,
      color_space: r.colorSpace, long_edge: r.format === 'di' ? 0 : r.longEdge, overwrite: target.overwrite, progress_id: job.progressId,
    }, { timeoutMs: 1_800_000 });
    if (res.payload.byteLength) throw new Error(tz('export_frame unexpectedly returned image data.', 'export_frame 意外返回了图像数据。'));
    const { path, width, height, timings_ms } = res.result;
    if (typeof path !== 'string' || typeof width !== 'number' || typeof height !== 'number' || width <= 0 || height <= 0)
      throw new Error(tz('The engine returned invalid export dimensions.', '引擎返回的导出尺寸无效。'));
    platform().log('info', `export (${hostFormat(r)}, ${width}x${height}) host ms: ${JSON.stringify(timings_ms ?? {})} · TOTAL ${Math.round(performance.now() - started)}`);
    return { kind: 'written', path, width, height, carriesEdits: r.format !== 'di' };
  } catch (e) {
    if (cancelled() && (e as { code?: string }).code === 'cancelled') return { kind: 'cancelled' };
    return { kind: 'failed', message: e instanceof Error ? e.message : String(e) };
  } finally {
    control.active?.(null);
  }
}
/** No file I/O or full-frame pixel IPC: prove the same frozen export snapshot.
 * JPEG proof is before lossy compression, as on Mac. */
export async function renderProof(
  recipe: ExportRecipe, frame: FrameToExport, catalog: StockCatalog, methods: readonly string[] | undefined,
  display: 'srgb' | 'display-p3', edge: number, generation: number, control: ExportControl = {},
) {
  if (!methods?.includes('render_proof')) throw new Error(tz('This engine does not support export soft proofing. Update the engine.', '此引擎不支持导出软打样，请更新引擎。'));
  if (recipe.format === 'di' && !methods.includes('export_cineon')) throw new Error(tz('Cineon Digital Intermediate proofing is not available on this engine.', '此引擎不支持 Cineon 数字中间片软打样。'));
  const r = structuredClone(recipe), f = structuredClone(frame);
  const view = recipeView(r, f, control);
  if (f.pair && !methods.includes('open_pair')) throw new Error(tz('This engine cannot soft-proof half-frame pairs. Update the engine.', '此引擎无法对半格拼接进行软打样，请更新引擎。'));
  const job = { session: f.session ?? '', progressId: `proof-${Date.now()}-${++exportSerial}` };
  if (control.cancelled?.()) return null;
  control.active?.(job);
  try {
    const proof = await host().renderProof({
      session: f.session, source_path: f.path, params: fullDelta(f.params, f.gate, catalog),
      decode: decodeWire(f.decode, isRawPath(f.path)) ?? undefined,
      adjustments: f.adjustments, ...view, format: r.format === 'di' ? 'di' : hostFormat(r),
      pair: f.pair,
      color_space: r.colorSpace, long_edge: r.format === 'di' ? 0 : r.longEdge,
      display, proof_long_edge: Math.max(1, Math.min(4096, Math.ceil(edge))), generation, progress_id: job.progressId,
    });
    return control.cancelled?.() ? null : proof;
  } finally { control.active?.(null); }
}
export async function exportCube(printStock: string, suggested: string): Promise<string | null> {
  const p = await platform().pickSave('Export .cube', suggested, 'cube');
  if (!p) return null;
  const r = await host().exportCube(printStock, p);
  return r.path;
}
