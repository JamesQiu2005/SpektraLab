import type { FilmParams } from './params';
import type { FileMetadata } from './protocol';
import { type Geometry, type Size, isIdentity, outputSize } from './geometry';

const positive = (v: number | undefined): v is number => v !== undefined && Number.isFinite(v) && v > 0;
const trimmed = (v: number) => v.toFixed(1).replace(/\.0$/, '');
const roundAway = (v: number) => Math.sign(v) * Math.round(Math.abs(v));

/** Session+FilmEdge.swift::ShootingData: actual EXIF only, maximum 22 glyphs. */
export function shootingLine(metadata: FileMetadata | null): string {
  if (!metadata) return '';
  const fields: string[] = [];
  const m = metadata;
  if (positive(m.shutter_s)) fields.push(m.shutter_s >= 1 ? `${trimmed(m.shutter_s)}s` : `1/${Math.round(1 / m.shutter_s)}`);
  if (positive(m.aperture)) fields.push(`F${trimmed(m.aperture)}`);
  const mode = ({ 1: 'M', 2: 'P', 3: 'A', 4: 'S' } as Record<number, string>)[m.exposure_program ?? 0];
  if (mode) fields.push(mode);
  if (m.exposure_bias_ev !== undefined && Number.isFinite(m.exposure_bias_ev)) {
    const bias = roundAway(m.exposure_bias_ev * 10) / 10;
    if (bias !== 0) fields.push(`${bias > 0 ? '+' : ''}${bias.toFixed(1)}`);
  }
  if (positive(m.focal_35mm)) fields.push(`${Math.round(m.focal_35mm)}mm`);
  while (fields.join(' ').length > 22) fields.pop();
  return fields.join(' ');
}

function captureDate(text: string | undefined, order: string): string {
  // Keep the shutter's calendar day. Date/UTC conversion would shift it in
  // another time zone. The host exposes ISO; legacy EXIF uses colon separators.
  const day = /^(\d{4})[:-](\d{2})[:-](\d{2})/.exec(text ?? '');
  if (!day) return '';
  const [year, month, date] = day.slice(1).map(Number) as [number, number, number];
  if (year <= 1800 || month < 1 || month > 12 || date < 1 || date > 31) return '';
  const yy = `'${String(year % 100).padStart(2, '0')}`;
  return order === 'us' ? `${month} ${date} ${yy}` : `${yy} ${month} ${date}`;
}

export function resolveImprints(p: FilmParams, metadata: FileMetadata | null, physicalAspect = 1.5, geometry?: Geometry, native?: Size | null): FilmParams {
  const long = p.filmSide === 'short' ? p.sideLengthMM * Math.max(physicalAspect, 1) : p.sideLengthMM;
  const short = long / Math.max(physicalAspect, 1);
  const candidates: [string, number, number][] = [['135', 36, 24], ['135_half', 24, 18], ['120_645', 56, 41.5]];
  const camera = p.filmEdge.active ? p.filmEdge.format :
    candidates.find(([, a, b]) => Math.abs(a-long) <= 1 && Math.abs(b-short) <= 1)?.[0] ?? null;
  const data = shootingLine(metadata);
  return { ...p,
    filmEdge: { ...p.filmEdge, fNumber: positive(metadata?.aperture) ? metadata!.aperture! : 0 },
    dateBack: { ...p.dateBack, camera, dataText: data,
      ...(geometry ? { framing: isIdentity(geometry) ? '' : JSON.stringify(geometry),
        frameScale: native ? Math.max(...Object.values(outputSize(geometry, native))) / Math.max(native.width, native.height) : 1 } : {}),
      text: p.dateBack.face === 'data' ? data : captureDate(metadata?.datetime_original, p.dateBack.order) },
  };
}

/** Mac FilmParams.wireFilmFormatMM/dateScale: keep grain pitch while sizing
 * the date and its insets against the cropped picture, not the whole decode. */
export function dateScales(p: FilmParams, overscanSupported: boolean, dateSupported: boolean) {
  const cut = ! (overscanSupported && p.filmEdge.active) && dateSupported &&
    dateCapability(p, overscanSupported).active && !!p.dateBack.framing;
  const filmMM = p.filmFormatMM * (cut ? p.dateBack.frameScale : 1);
  const cameraMM = ({ '135': 36, '135_half': 24, '120_645': 56 } as Record<string, number>)[p.dateBack.camera ?? ''];
  return { filmMM, imprint: cut && cameraMM ? Math.min(1, Math.max(0.05, filmMM/cameraMM)) : 1 };
}

/** The original camera's real imprint locations, shared by controls and wire. */
export function dateCapability(p: FilmParams, overscanSupported = true) {
  const edge = overscanSupported && p.filmEdge.active;
  const camera = edge ? p.filmEdge.format : p.dateBack.camera;
  const supported = !!camera && ['135', '135_half', '120_645', '120_6x6', '120_6x7', '120_6x8', '120_6x9'].includes(camera);
  const needsEdge = p.dateBack.face === 'data' || !!camera?.startsWith('120_');
  const canPrint = supported && (!needsEdge || edge);
  const active = p.dateBack.active && canPrint && (p.dateBack.face === 'data' || p.dateBack.placement === 'frame' || edge);
  return { camera, canPrint, active, dataToo: active && edge && p.dateBack.withData && p.dateBack.face !== 'data' };
}
