// words.ts — the status line's words (README §7, V5's words rule: names,
// values, states, actions). Pure functions of the session and the
// scheduler's job, so every state is tested on its words.
//
//   a job waiting or running, film side   Developing · Gold 200 (· 1.4 s past a second)
//   print side                            Printing · Yellow +0.10
//   done, edits                           Edited · Tone · Curve · Enlarger
//   done, no edits                        Developed · Porta 400 · Porta Enduro
//   the engine cannot start               Engine stopped
//   exporting                             Exporting _DSC0061 / Exporting 3 of 12 · JPEG · sRGB
//
// The line fits its room or drops trailing parts, never "…" (README §5):
// `fitParts` drops whole parts from the end.

import { tz } from '../i18n';
import type { StockCatalog } from '@shared/stocks';
import type { FilmParams } from '@shared/params';
import type { Adjustments } from '@shared/adjustments';
import { ADJUSTMENTS_DEFAULT, CURVES_IDENTITY } from '@shared/adjustments';
import type { JobSnapshot } from '../scheduler/types';

export const SEP = '  ·  ';

/** A stock's short name, as the cards and the status line write it. */
export function shortName(catalog: StockCatalog, id: string): string {
  return catalog.stock(id)?.name.replace(/^(Kodak|Fujifilm|Ilford|Fuji) (Professional )?/, '') ?? id;
}

/**
 * A stock's name on its card (PC-E1): the short name, made to fit two lines of
 * a 92 epx card at 12 epx — the maker gone, and the words a card does not need
 * ("Type", "Professional") dropped. The full name stays the card's tooltip and
 * accessible name.
 */
export function cardName(catalog: StockCatalog, id: string): string {
  return shortName(catalog, id).replace(/\bType\s+/g, '').replace(/\bProfessional\s+/g, '')
    // a print film's family word: "Vision Premier 2393" is Premier 2393 on its card ("Vision 2383" keeps it: it is the name)
    .replace(/^Vision (?=[A-Z][a-z])/, '').replace(/\s{2,}/g, ' ').trim();
}

const signed2 =(v: number) => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(2);

/** The words a canvas job stands for: the film for a develop, the moved control for a print. */
export function canvasWhat(catalog: StockCatalog, want: FilmParams, delta: Record<string, unknown>, reprint: boolean): string {
  if (!reprint) return shortName(catalog, want.filmStock);
  if ('y_filter_shift' in delta) return `${tz('Yellow', '黄')} ${signed2(want.yFilterShift)}`;
  if ('m_filter_shift' in delta) return `${tz('Magenta', '品红')} ${signed2(want.mFilterShift)}`;
  if ('preflash_exposure' in delta) return `${tz('Pre-flash', '预闪')} ${want.preflashExposure.toFixed(2)}`;
  if ('print_exposure' in delta) return `${tz('Brightness', '亮度')} ${signed2(want.printBrightnessStops)}`;
  if ('print_stock' in delta) return shortName(catalog, want.printStock);
  return shortName(catalog, want.printStock);
}

/** The Adjust tiles and Darkroom tiles a frame has moved off rest, in the rail's order. */
export function editedParts(a: Adjustments, p: FilmParams, defaults: FilmParams): string[] {
  const out: string[] = [];
  const d = ADJUSTMENTS_DEFAULT;
  if (a.brightness !== d.brightness || a.exposure !== d.exposure) out.push(tz('Brightness', '亮度'));
  if (a.contrast !== d.contrast) out.push(tz('Contrast', '对比度'));
  if (a.highlights !== d.highlights || a.shadows !== d.shadows || a.whitePoint !== d.whitePoint || a.blackPoint !== d.blackPoint) out.push(tz('Tone', '色调'));
  const zones = Object.values(a.colorBalance);
  if (zones.some((z) => z.saturation !== 0 || z.luminance !== 0)) out.push(tz('Colour Wheels', '色轮'));
  if (a.saturation !== d.saturation) out.push(tz('Saturation', '饱和度'));
  if (a.temperature !== d.temperature || a.tint !== d.tint) out.push(tz('Temperature', '色温'));
  if (JSON.stringify(a.curves) !== JSON.stringify(CURVES_IDENTITY)) out.push(tz('Curve', '曲线'));
  if (a.vignette.amount !== d.vignette.amount) out.push(tz('Vignette', '暗角'));
  if (p.printBrightnessStops !== defaults.printBrightnessStops || p.yFilterShift !== defaults.yFilterShift || p.mFilterShift !== defaults.mFilterShift || p.preflashExposure !== defaults.preflashExposure)
    out.push(tz('Enlarger', '放大机'));
  return out;
}

export interface StatusInput {
  engine: 'starting' | 'ready' | 'stopped';
  hasFrame: boolean;
  frameName: string;
  catalog: StockCatalog;
  params: FilmParams;
  noFilm: boolean;
  edited: string[];
  /** The open frame's newest canvas or full-view job, if any is still live. */
  job: JobSnapshot | null;
  /** Elapsed ms of a running job, on the page's clock. */
  elapsedMs: number;
  /** The print the picture shows has landed at least once. */
  printed: boolean;
  exporting: { done: number; total: number; format: string; colour: string; file: string } | null;
  crop: { ratio: string; angle: number } | null;
  /** What the status line says once, after a gated setting was left off (README §3.8). */
  notice: string | null;
}

export function statusParts(i: StatusInput): { parts: string[]; tone: 'normal' | 'danger' } {
  if (i.engine === 'stopped') return { parts: [tz('Engine stopped', '引擎已停止')], tone: 'danger' };
  if (i.engine === 'starting') return { parts: [tz('Starting the engine', '正在启动引擎')], tone: 'normal' };
  if (i.exporting) {
    return i.exporting.total > 1
      ? { parts: [tz(`Exporting ${i.exporting.done + 1} of ${i.exporting.total}`, `正在导出 ${i.exporting.done + 1} / ${i.exporting.total}`), i.exporting.format, i.exporting.colour], tone: 'normal' }
      : { parts: [tz(`Exporting ${i.exporting.file}`, `正在导出 ${i.exporting.file}`)], tone: 'normal' };
  }
  if (!i.hasFrame) return { parts: [], tone: 'normal' };
  if (i.crop) return { parts: [tz('Crop', '裁剪'), i.crop.ratio, `${i.crop.angle >= 0 ? '+' : '−'}${Math.abs(i.crop.angle).toFixed(1)}°`], tone: 'normal' };
  const j = i.job;
  if (j && (j.state.state === 'waiting' || j.state.state === 'queued' || j.state.state === 'running') && !j.superseded) {
    const verb = j.job.kind === 'canvasReprint' ? tz('Printing', '正在印放') : tz('Developing', '正在冲洗');
    const parts = [verb, j.job.what].filter(Boolean);
    if (j.state.state === 'running' && i.elapsedMs >= 1000) parts.push(`${(i.elapsedMs / 1000).toFixed(1)} s`);
    if (j.state.state === 'waiting' && j.state.reason !== 'settling') parts.push(waitWords(j.state.reason));
    return { parts, tone: 'normal' };
  }
  if (i.notice) return { parts: [i.notice], tone: 'normal' };
  if (!i.printed) return { parts: [tz('Developing', '正在冲洗'), shortName(i.catalog, i.params.filmStock)], tone: 'normal' };
  if (i.edited.length) return { parts: [tz('Edited', '已编辑'), ...i.edited], tone: 'normal' };
  if (i.noFilm) return { parts: [tz('Developed', '已冲洗'), tz('No film', '不应用胶片')], tone: 'normal' };
  const paper = i.params.scanFilm ? null : shortName(i.catalog, i.params.printStock);
  return { parts: [tz('Developed', '已冲洗'), shortName(i.catalog, i.params.filmStock), ...(paper ? [paper] : [])], tone: 'normal' };
}

export function waitWords(r: string): string {
  switch (r) {
    case 'dialog': return tz('Waiting for the dialog', '等待对话框关闭');
    case 'background': return tz('Paused in the background', '后台已暂停');
    case 'memory': return tz('Waiting for memory', '等待内存');
    case 'queued': return tz('Waiting its turn', '排队中');
    default: return '';
  }
}

/**
 * Drop trailing parts until the line fits `room` px; the first part always
 * stays (it is the state). `measure` is the page's text measure.
 */
export function fitParts(parts: string[], room: number, measure: (s: string) => number): string {
  for (let n = parts.length; n > 1; n--) {
    const s = parts.slice(0, n).join(SEP);
    if (measure(s) <= room) return s;
  }
  return parts[0] ?? '';
}
