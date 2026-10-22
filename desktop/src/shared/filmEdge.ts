// FilmEdge.swift and Session+FilmEdge.swift, pinned upstream f1440bd1.
// These are host/UI rules; all fog, edge and date exposure math stays in the engine.
import type { DateBackSettings, FeatureGate, FilmEdgeSettings, FilmParams } from './params';
import type { FileMetadata } from './protocol';
import type { Stock, StockCatalog } from './stocks';
import { GEOMETRY_DEFAULT, constrained, isIdentity, outputSize, type Geometry, type Size } from './geometry';

export const EDGE_FORMATS = [
  { id: '135', label: '135', long: 36, short: 24, gauge: '135' },
  { id: '135_half', label: 'Half frame', long: 24, short: 18, gauge: '135' },
  { id: '120_645', label: '645', long: 56, short: 41.5, gauge: '120' },
  { id: '120_6x6', label: '6×6', long: 56, short: 56, gauge: '120' },
  { id: '120_6x7', label: '6×7', long: 69.5, short: 56, gauge: '120' },
  { id: '120_6x8', label: '6×8', long: 76, short: 56, gauge: '120' },
  { id: '120_6x9', label: '6×9', long: 84, short: 56, gauge: '120' },
  { id: '135_xpan', label: 'XPan', long: 65, short: 24, gauge: '135', panoramic: true },
  { id: '120_6x12', label: '6×12', long: 112, short: 56, gauge: '120', panoramic: true },
  { id: '120_6x17', label: '6×17', long: 168, short: 56, gauge: '120', panoramic: true },
] as const;
export const edgeFormat = (id: string) => EDGE_FORMATS.find((f) => f.id === id);
export function edgeEffective(edge: FilmEdgeSettings, gate?: FeatureGate) { return gate?.overscan !== false && edge.active && !!edgeFormat(edge.format); }
export function stockSupportsEdge(stock: Stock | undefined, format: string): boolean {
  const gauge = edgeFormat(format)?.gauge;
  return !gauge || !stock?.formats || stock.formats.includes(gauge) || (gauge === '135' && stock.formats.includes('35mm_motion'));
}
export function dateCamera(d: DateBackSettings, edge: FilmEdgeSettings, gate?: FeatureGate) {
  return edgeFormat(edgeEffective(edge, gate) ? edge.format : d.camera ?? '');
}
export function datePrints(face: string, d: DateBackSettings, edge: FilmEdgeSettings, gate?: FeatureGate): boolean {
  const camera = dateCamera(d, edge, gate);
  return !!camera && !('panoramic' in camera) && (face !== 'data' && camera.gauge !== '120' || edgeEffective(edge, gate));
}
export function dateEffective(d: DateBackSettings, edge: FilmEdgeSettings, gate?: FeatureGate): boolean {
  return gate?.dateImprint !== false && d.active && datePrints(d.face, d, edge, gate)
    && (d.face === 'data' || d.placement === 'frame' || edgeEffective(edge, gate));
}
export function sourceGeometryFor(p: FilmParams, g: Geometry, gate?: FeatureGate): Geometry | null {
  return edgeEffective(p.filmEdge, gate) || (dateEffective(p.dateBack, p.filmEdge, gate) && !isIdentity(g)) ? g : null;
}
export function canvasGeometryFor(p: FilmParams, g: Geometry, gate?: FeatureGate): Geometry {
  return sourceGeometryFor(p, g, gate) ? GEOMETRY_DEFAULT : g;
}
export function geometryInNegative(p: FilmParams, gate?: FeatureGate): boolean {
  return edgeEffective(p.filmEdge, gate) || dateEffective(p.dateBack, p.filmEdge, gate);
}
export function gateFramed(g: Geometry, edge: FilmEdgeSettings, size: Size, landscape?: boolean): Geometry {
  const f = edgeFormat(edge.format);
  if (!f || !(size.width > 0 && size.height > 0)) return g;
  const along = edge.pair ? 37 : f.long, across = edge.pair ? 24 : f.short;
  const horizontal = landscape ?? (g.crop.width * size.width >= g.crop.height * size.height);
  return constrained({ ...g, lockedRatio: horizontal ? along / across : across / along }, size);
}
export function framingKey(g: Geometry): string {
  const c = g.crop;
  return [c.x.toFixed(6), c.y.toFixed(6), c.width.toFixed(6), c.height.toFixed(6), g.angle.toFixed(4),
    ((g.quarterTurns % 4) + 4) % 4, Number(g.flipH), Number(g.flipV)].join(',');
}
export function captureDate(text: string | undefined, order: string): string {
  const match = /^(\d{4})[:-](\d{2})[:-](\d{2})(?:[T\s]|$)/.exec(text ?? '');
  if (!match) return '';
  const [year, month, day] = match.slice(1).map(Number) as [number, number, number];
  if (year <= 1800 || month < 1 || month > 12 || day < 1 || day > new Date(Date.UTC(year, month, 0)).getUTCDate()) return '';
  const yy = `'${String(year % 100).padStart(2, '0')}`;
  return order === 'us' ? `${month} ${day} ${yy}` : `${yy} ${month} ${day}`;
}
export function shootingText(m: FileMetadata | null): string {
  if (!m) return '';
  const extra = m as FileMetadata & { exposure_program?: number; exposure_bias_ev?: number; focal_35mm?: number };
  const trim = (n: number) => n.toFixed(1).replace(/\.0$/, '');
  const fields: string[] = [];
  if (m.shutter_s && Number.isFinite(m.shutter_s) && m.shutter_s > 0)
    fields.push(m.shutter_s >= 1 ? `${trim(m.shutter_s)}s` : `1/${Math.round(1 / m.shutter_s)}`);
  if (m.aperture && Number.isFinite(m.aperture) && m.aperture > 0) fields.push(`F${trim(m.aperture)}`);
  const mode = ({ 1: 'M', 2: 'P', 3: 'A', 4: 'S' } as Record<number, string>)[extra.exposure_program ?? 0];
  if (mode) fields.push(mode);
  if (Number.isFinite(extra.exposure_bias_ev)) {
    const b = Math.round(extra.exposure_bias_ev! * 10) / 10;
    if (b !== 0) fields.push(`${b > 0 ? '+' : ''}${b.toFixed(1)}`);
  }
  if (extra.focal_35mm && Number.isFinite(extra.focal_35mm) && extra.focal_35mm > 0) fields.push(`${Math.round(extra.focal_35mm)}mm`);
  while (fields.join(' ').length > 22) fields.pop();
  return fields.join(' ');
}
const EDGE_WORDS: Record<string, [string, string?]> = {
  kodak_gold_200: ['KODAK GB 200-7', 'KODAK 200'], kodak_portra_800: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_portra_800_push1: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'], kodak_portra_800_push2: ['KODAK PORTRA 800-3', 'KODAK PORTRA 800'],
  kodak_ultramax_400: ['KODAK GC 400'], kodak_ektachrome_100: ['KODAK E100'],
  fujifilm_c200: ['FUJI 200'], fujifilm_xtra_400: ['S-400', 'FUJI S-400'],
  fujifilm_pro_400h: ['PRO400H', 'FUJI PRO400H'], fujifilm_provia_100f: ['FUJI RDPIII'], fujifilm_velvia_100: ['RVP100', 'FUJI RVP100'],
  kodak_vision3_50d: ['EASTMAN 5203'], kodak_vision3_250d: ['EASTMAN 5207'], kodak_vision3_200t: ['EASTMAN 5213'], kodak_vision3_500t: ['EASTMAN 5219'],
  kodak_tri_x_400: ['KODAK 400TX'], kodak_tmax_100: ['KODAK 100TMX'], fujifilm_neopan_acros_100_ii: ['FUJI 100 ACROS II'], ilford_hp5_plus_400: ['ILFORD HP5 PLUS'],
};
export function edgeText(stock: Stock | undefined, format: string): string {
  if (!stock) return '';
  const own = EDGE_WORDS[stock.id];
  return own ? (edgeFormat(format)?.gauge === '120' ? own[1] ?? own[0] : own[0]) : stock.name.split('(')[0]!.trim().toUpperCase();
}
export function resolveFilmEdgeParams(p: FilmParams, geometry: Geometry, metadata: FileMetadata | null, catalog: StockCatalog, native?: Size | null): FilmParams {
  const dataText = shootingText(metadata), f = p.filmEdge;
  const sourceAspect = native ? Math.max(native.width, native.height) / Math.max(1, Math.min(native.width, native.height)) : 1.5;
  const camera = edgeEffective(f) ? f.format : EDGE_FORMATS.filter((v) => ['135', '135_half', '120_645'].includes(v.id))
    .find((v) => Math.abs(v.long - p.filmFormatMM) <= 1 && Math.abs(v.short - p.filmFormatMM / sourceAspect) <= 1)?.id ?? null;
  const cut = native ? outputSize(geometry, native) : null;
  return { ...p, filmEdge: { ...f, edgeText: edgeText(catalog.stock(p.filmStock), f.format), fNumber: metadata?.aperture ?? 0,
    framing: framingKey(geometry) }, dateBack: { ...p.dateBack, camera, dataText,
    text: p.dateBack.face === 'data' ? dataText : captureDate(metadata?.datetime_original, p.dateBack.order),
    framing: isIdentity(geometry) ? '' : framingKey(geometry),
    frameScale: cut && native ? Math.max(cut.width, cut.height) / Math.max(native.width, native.height) : 1 } };
}

export function filmFormatForWire(p: FilmParams, gate?: FeatureGate): number {
  return !edgeEffective(p.filmEdge, gate) && dateEffective(p.dateBack, p.filmEdge, gate) && p.dateBack.framing
    ? p.filmFormatMM * p.dateBack.frameScale : p.filmFormatMM;
}
export function dateScale(p: FilmParams, gate?: FeatureGate): number {
  const camera = dateCamera(p.dateBack, p.filmEdge, gate);
  return !edgeEffective(p.filmEdge, gate) && dateEffective(p.dateBack, p.filmEdge, gate) && p.dateBack.framing && camera
    ? Math.max(.05, Math.min(1, filmFormatForWire(p, gate) / camera.long)) : 1;
}
