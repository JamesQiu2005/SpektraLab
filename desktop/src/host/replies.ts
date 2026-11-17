// replies.ts — a host reply's pixels as the page draws them, decoded from the
// protocol's `{result, payload}` wherever the reply came from: the host
// directly (`client.ts`), a scheduler job's outcome (`hostResult` + the
// payload, WIRE.md), or the frame's editing session. Kept apart from
// `client.ts` so a test that stands in for the host client still decodes
// replies with the real rules.

import type { ImageInfo, PairInfo, Tier } from '@shared/protocol';
import type { Geometry } from '@shared/geometry';
import { HostCallError } from './transport';

/** Display-encoded top-first pixels. RGBA16 is little-endian UNORM16. */
export interface RgbaImage {
  width: number;
  height: number;
  data: Uint8Array;
  format?: 'rgba8' | 'rgba16';
  colorSpace: string;
  /** Geometry already committed by render_view; undefined for legacy/raw previews. */
  processedGeometry?: Geometry;
  nativeSize?: { width: number; height: number };
  pairInfo?: PairInfo;
}

export interface RenderReply extends RgbaImage {
  tier: Tier;
  reprinted: boolean;
  ms: number;
}

export function displayImage(info: ImageInfo, payload: Uint8Array): RgbaImage {
  if (!info || (info.format !== 'rgba8' && info.format !== 'rgba16'))
    throw new HostCallError('render', 'bad_request', 'unsupported display pixel format');
  const bytes = info.format === 'rgba16' ? 8 : 4;
  const tight = info.width * bytes, stride = info.row_bytes || tight;
  if (!Number.isSafeInteger(info.width) || !Number.isSafeInteger(info.height) || info.width <= 0 || info.height <= 0 ||
      !Number.isSafeInteger(stride) || stride < tight || payload.byteLength !== stride * info.height)
    throw new HostCallError('render', 'internal', 'invalid display pixel dimensions or payload');
  let data = payload;
  if (stride !== tight) {
    data = new Uint8Array(tight * info.height);
    for (let y = 0; y < info.height; y++) data.set(payload.subarray(y * stride, y * stride + tight), y * tight);
  }
  return { width: info.width, height: info.height, data, format: info.format, colorSpace: info.color_space };
}

/** `render_view`'s reply: the generation it was asked for, or it is refused (a late reply of an older edit). */
export function renderViewReply(result: Record<string, unknown>, payload: Uint8Array, asked: { generation: number; geometry?: Geometry; tier?: Tier }, ms = 0): RenderReply {
  const r = result as { image: ImageInfo; tier?: Tier; print_cached?: boolean; generation?: number; pair_info?: PairInfo };
  if (r.generation !== asked.generation) throw new HostCallError('render_view', 'internal', 'view generation mismatch');
  const image = r.image;
  return { ...displayImage(image, payload), processedGeometry: asked.geometry, pairInfo: r.pair_info,
    nativeSize: image.source_width && image.source_height ? { width: image.source_width, height: image.source_height } : undefined,
    tier: r.tier ?? asked.tier ?? 'live', reprinted: !!r.print_cached, ms };
}

/** The legacy `render`'s reply. */
export function renderReply(result: Record<string, unknown>, payload: Uint8Array, tier: Tier, ms = 0): RenderReply {
  const r = result as { image: ImageInfo; tier?: Tier; reprinted?: boolean };
  return { ...displayImage(r.image, payload), tier: r.tier ?? tier, reprinted: !!r.reprinted, ms };
}

/** `thumbnail`'s reply (and any `{image}` reply). */
export function imageReply(result: Record<string, unknown>, payload: Uint8Array): RgbaImage {
  return displayImage((result as { image: ImageInfo }).image, payload);
}

/** `render_source`'s reply: the generation asked, a tight RGBA8 frame. */
export function sourceReply(result: Record<string, unknown>, payload: Uint8Array, generation: number): RgbaImage {
  const r = result as { image: ImageInfo; generation: number };
  const i = r.image;
  if (r.generation !== generation || !i || i.width <= 0 || i.height <= 0 ||
      i.row_bytes !== i.width * 4 || payload.byteLength !== i.width * i.height * 4)
    throw new HostCallError('render_source', 'internal', 'invalid or outdated decoded source response');
  return displayImage(i, payload);
}

/** A decoded picture back into the protocol's `{image}` + payload (the in-page mock's adapter over a typed client). */
export function encodeImage(img: RgbaImage, extra: Record<string, unknown> = {}): { result: Record<string, unknown>; payload: Uint8Array } {
  const bytes = img.format === 'rgba16' ? 8 : 4;
  return {
    result: {
      image: { width: img.width, height: img.height, format: img.format ?? 'rgba8', color_space: img.colorSpace, row_bytes: img.width * bytes,
        ...(img.nativeSize ? { source_width: img.nativeSize.width, source_height: img.nativeSize.height } : {}) },
      ...(img.pairInfo ? { pair_info: img.pairInfo } : {}),
      ...extra,
    },
    payload: img.data,
  };
}
