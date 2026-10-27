// exporter.ts — write the open frame through a recipe (`Export/Exporter.swift`).
//
// The file is the canvas's frame (trap 33): the engine's print, Layer 2, then
// the geometry. With the host's `write_image` (PROTOCOL-REQUESTS R1) the app
// renders `full` as rgba16 in the recipe's space, grades and crops it here —
// the same arithmetic as the canvas shader (`layer2Pixel`, `sourcePoint`) —
// and hands the pixels to the host, which embeds the ICC profile and lands
// the file whole. Without it, `export_image` writes the engine's print and the
// page says that the crop and the grade are not in the file.

import { type Adjustments,ADJUSTMENTS_DEFAULT,PROPHOTO_MID_GREY, SRGB_MID_GREY, curveTables, isNeutral, layer2Pixel, layer2Uniforms } from '@shared/adjustments';
import { type Geometry,GEOMETRY_DEFAULT,isIdentity, outputSize, sourcePoint } from '@shared/geometry';
import type { FilmParams } from '@shared/params';
import { engineGeometry, hasFilmFrame, printGeometry, wireGeometry } from '@shared/filmFrame';
import type {FrameLayout} from '@shared/filmFrame';
import type {PairInfo} from '@shared/protocol';
import type {PairDocument} from '@shared/pairs';
import {composePairPixels,pairHasPresentation,presentationRects,printDelta,filmPrint} from '@shared/pairPresentation';
import {jsonEqual} from '@shared/params';
import type { StockCatalog } from '@shared/stocks';
import { host } from '../host/client';
import { baseName, dirName, joinPath, platform } from '../platform';
import { type ExportRecipe, extensionOf, hostFormat, resolveTarget, stem, stockToken } from './recipes';

export interface FrameToExport {
  path: string;
  session: string;
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
  native: { width: number; height: number };
  dateTaken?: string;
  pairComplete?: boolean;
  pairDocument?:PairDocument|null;
  pairInfo?:PairInfo|null;
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
  return { dir, base: r.format === 'di' ? `${base}_DI` : base };
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

export function outputFor(r: ExportRecipe, g: Geometry, native: { width: number; height: number }) {
  const o = outputSize(g, native);
  if (r.format === 'di' || !r.longEdge || r.longEdge >= Math.max(o.width, o.height)) return o;
  const k = r.longEdge / Math.max(o.width, o.height);
  return { width: Math.max(1, Math.round(o.width * k)), height: Math.max(1, Math.round(o.height * k)) };
}

export async function exportFrame(r: ExportRecipe, f: FrameToExport, catalog: StockCatalog, methods: readonly string[] | undefined): Promise<ExportOutcome> {
  try {
    if(f.pairComplete===false) throw new Error('Both half-frame holes need available photographs before export.');
    const geometry = printGeometry(f.params, f.geometry);
    const { dir, base } = await targetFor(r, f, catalog);
    await platform().ensureDir(dir);
    const target = await resolveTarget(dir, base, extensionOf(r), r.existing, (p) => platform().pathExists(p), joinPath);
    if (!target) return { kind: 'skipped', path: joinPath(dir, `${base}.${extensionOf(r)}`) };
    if (r.format === 'di') {
      if (!methods?.includes('export_cineon')) throw new Error('This host cannot export a raw Cineon Digital Intermediate.');
      const negativeGeometry = hasFilmFrame(f.params) ? engineGeometry(f.params, f.geometry, f.native) : wireGeometry(f.geometry);
      const res = await host().exportCineon(f.session, target.path, negativeGeometry, target.overwrite);
      return { kind: 'written', path: res.path, width: res.width, height: res.height, carriesEdits: false };
    }
    const edited = !isIdentity(geometry) || (f.adjustments.enabled && !isNeutral(f.adjustments));
    if (hostWrites(methods)) {
      const display = r.colorSpace === 'sRGB' ? 'srgb' : r.colorSpace;
      const rr = await host().transport.request(
        'render',
        { session: f.session, tier: 'full', format: 'rgba16', display },
        { timeoutMs: 1_800_000 },
      );
      const info = rr.result.image as { width: number; height: number; row_bytes: number };
      if (rr.payload.byteLength !== info.width * info.height * 8) throw new Error('The full-resolution export payload is incomplete.');
      platform().log('info', `export: received ${info.width}x${info.height} rgba16; applying framing and Post-Dev`);
      const src = rr.payload.byteOffset % 2 === 0
        ? new Uint16Array(rr.payload.buffer, rr.payload.byteOffset, info.width * info.height * 4)
        : new Uint16Array(rr.payload.slice().buffer);
      const out = outputFor(r, geometry, { width: info.width, height: info.height });
      const midGrey = r.colorSpace === 'prophoto' ? PROPHOTO_MID_GREY : SRGB_MID_GREY;
      let presented=src,pregraded=false;
      if(f.pairDocument&&pairHasPresentation(f.pairDocument,f.params,f.adjustments)) {
        if(!methods?.includes('render_layer')||!f.pairInfo)throw new Error('This host cannot export per-hole print/grade layers');
        const size={width:info.width,height:info.height};
        const grade=(data:Uint16Array,a:Adjustments)=>!a.enabled||isNeutral(a)?data:filePixels(data,size,GEOMETRY_DEFAULT,a,size,midGrey);
        const rects=presentationRects(hasFilmFrame(f.params)?(await host().transport.request('overscan_geometry',{session:f.session})).result as unknown as FrameLayout:null,f.pairInfo.rects);
        const film=filmPrint(f.params),layers:(Uint16Array|null)[]=[];
        for(const h of [f.pairDocument.left,f.pairDocument.right]) {
          if(!h){layers.push(null);continue;}
          const ownPrint=h.print&&!jsonEqual(h.print,film),ownGrade=h.adjustments&&!jsonEqual(h.adjustments,f.adjustments);
          if(!ownPrint&&!ownGrade){layers.push(null);continue;}
          let pixels=src;
          if(ownPrint){
            const layer=await host().transport.request('render_layer',{session:f.session,tier:'full',format:'rgba16',display,delta:printDelta(f.params,h.print!)},{timeoutMs:1_800_000});
            const li=layer.result.image as {width:number;height:number};
            if(li.width!==info.width||li.height!==info.height||layer.payload.byteLength!==src.byteLength)throw new Error('Export pair layer size mismatch');
            pixels=new Uint16Array(layer.payload.slice().buffer);
          }
          layers.push(grade(pixels,h.adjustments??f.adjustments));
        }
        presented=composePairPixels(grade(src,f.adjustments),size,layers,rects);pregraded=true;
      }
      const px = filePixels(presented, { width: info.width, height: info.height }, geometry, pregraded?ADJUSTMENTS_DEFAULT:f.adjustments, out, midGrey);
      platform().log('info', `export: writing ${out.width}x${out.height} ${hostFormat(r)}`);
      const w = await host().transport.request(
        'write_image',
        {
          path: target.path,
          format: hostFormat(r),
          quality: r.format === 'jpeg' ? r.quality : undefined,
          color_space: r.colorSpace,
          width: out.width,
          height: out.height,
          overwrite: target.overwrite,
          source_path: f.path,
          session:f.session,
        },
        { payload: new Uint8Array(px.buffer), timeoutMs: 600_000 },
      );
      return { kind: 'written', path: String(w.result.path), width: out.width, height: out.height, carriesEdits: true };
    }
    const res = await host().exportImage({
      session: f.session,
      path: target.path,
      format: hostFormat(r),
      quality: r.format === 'jpeg' ? r.quality : undefined,
      color_space: r.colorSpace,
      long_edge: r.longEdge || undefined,
      overwrite: target.overwrite,
    });
    return { kind: 'written', path: res.path, width: res.width, height: res.height, carriesEdits: !edited };
  } catch (e) {
    return { kind: 'failed', message: (e as Error).message };
  }
}

export async function exportCube(printStock: string, suggested: string): Promise<string | null> {
  const p = await platform().pickSave('Export .cube', suggested, 'cube');
  if (!p) return null;
  const r = await host().exportCube(printStock, p);
  return r.path;
}
