// layoutExport.ts — a multi-photo layout (shared/layouts.ts) to a file: each cell's photograph developed with
// its own settings (opened in the editor and rendered at full size, as a batch export does), placed to
// cover its cell (`coverPlacement`), on a sheet of the layout's grey, written by the host.

import { host } from '../host/client';
import { select, sessionStore } from '../state/session';
import { type LayoutDoc, cellRects, coverPlacement, sheetSize } from '@shared/layouts';
import { ADOBE_MID_GREY, PROPHOTO_MID_GREY, SRGB_MID_GREY, borderCode } from '@shared/adjustments';
import { outputSize } from '@shared/geometry';
import { filePixels, rgba16 } from './exporter';
import { waitForDeveloped } from './ExportPage';
import type { ExportSpace } from './recipes';

export interface LayoutExportOptions {
  path: string;
  format: 'jpeg' | 'png' | 'tiff16';
  quality: number;
  colorSpace: ExportSpace;
}

export async function exportLayout(
  doc: LayoutDoc,
  o: LayoutExportOptions,
  progress: (done: number, total: number, name: string) => void,
): Promise<{ path: string; width: number; height: number }> {
  const { width: W, height: H } = sheetSize(doc);
  const sheet = new Uint16Array(W * H * 4);
  const bg = Math.round(borderCode(doc.tone, o.colorSpace) * 65535);
  for (let i = 0; i < W * H; i++) {
    sheet[4 * i] = bg;
    sheet[4 * i + 1] = bg;
    sheet[4 * i + 2] = bg;
    sheet[4 * i + 3] = 65535;
  }
  const rects = cellRects(doc, W, H);
  const midGrey = o.colorSpace === 'prophoto' ? PROPHOTO_MID_GREY : o.colorSpace === 'adobe-rgb' ? ADOBE_MID_GREY : SRGB_MID_GREY;
  const display = o.colorSpace === 'sRGB' ? 'srgb' : o.colorSpace;
  const back = sessionStore.getState().selection;
  sessionStore.setState({ batchExporting: true });
  try {
    for (let i = 0; i < rects.length; i++) {
      const cell = doc.cells[i];
      const r = rects[i]!;
      if (!cell) continue;
      progress(i, rects.length, cell.path.split(/[\\/]/).pop() ?? cell.path);
      await select(cell.path);
      const ready = await waitForDeveloped(cell.path);
      const s = sessionStore.getState();
      if (!ready || !s.engineSession || !s.nativeSize) throw new Error(`${cell.path}: the photograph did not develop`);
      const rr = await host().transport.request('render', { session: s.engineSession, tier: 'full', format: 'rgba16', display }, { timeoutMs: 1_800_000 });
      const info = rr.result.image as { width: number; height: number };
      const src = rgba16(rr.payload, info.width, info.height);
      // The photograph as its edit frames it, then sized to cover the cell at its zoom.
      const own = outputSize(s.sidecar.geometry, { width: info.width, height: info.height });
      const place = coverPlacement(own.width, own.height, r.w, r.h, cell);
      const px = filePixels(src, { width: info.width, height: info.height }, s.sidecar.geometry, s.sidecar.adjustments, { width: place.w, height: place.h }, midGrey);
      for (let y = 0; y < r.h; y++) {
        const sy = y - place.oy;
        if (sy < 0 || sy >= place.h) continue;
        const from = (sy * place.w - place.ox) * 4;
        sheet.set(px.subarray(from, from + r.w * 4), ((r.y + y) * W + r.x) * 4);
      }
    }
    progress(rects.length, rects.length, '');
    const w = await host().transport.request(
      'write_image',
      { path: o.path, format: o.format, quality: o.format === 'jpeg' ? o.quality : undefined, color_space: o.colorSpace, width: W, height: H, overwrite: true },
      { payload: new Uint8Array(sheet.buffer), timeoutMs: 600_000 },
    );
    return { path: String(w.result.path), width: W, height: H };
  } finally {
    sessionStore.setState({ batchExporting: false });
    if (back && sessionStore.getState().selection !== back) void select(back);
  }
}
