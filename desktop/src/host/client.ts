// client.ts — the host's methods (HOST-PROTOCOL.md §3) as typed calls.
//
// Everything above this file speaks in these types; nothing above it knows
// whether the host is the C++ engine, the stdio mock or the in-page shim.

import type {
  FileMetadata,
  HelloResult,
  HostState,
  ImageInfo,
  OpenResult,
  PairInfo,
  ParamsSchema,
  ProbeResult,
  RenderProofResult,
  Tier,
  WireParams,
} from '@shared/protocol';
import { browserTransport } from './browserShim';
import { tauriTransport } from './tauriTransport';
import { HostCallError, inTauri, type Transport } from './transport';
import type { Adjustments } from '@shared/adjustments';
import type { Geometry } from '@shared/geometry';
import type { HalfFramePair } from '@shared/pair';

export { HostCallError };

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

export interface ProofReply extends RgbaImage {
  proof: RenderProofResult;
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

export class Host {
  readonly transport: Transport;
  constructor(t: Transport) {
    this.transport = t;
  }

  get kind() {
    return this.transport.kind;
  }

  private async call<T>(method: string, params: Record<string, unknown> = {}, timeoutMs?: number) {
    const r = await this.transport.request(method, params, { timeoutMs });
    return { result: r.result as T, payload: r.payload };
  }

  state(): Promise<HostState> {
    return this.transport.state();
  }
  onState(cb: (s: HostState) => void) {
    return this.transport.onState(cb);
  }
  onEvent(cb: (e: Record<string, unknown>) => void) {
    return this.transport.onEvent(cb);
  }
  restart() {
    return this.transport.restart();
  }
  diagnostics() {
    return this.transport.diagnostics();
  }
  async memoryReport(): Promise<Record<string, unknown>> {
    return (await this.call<Record<string, unknown>>('memory_report', {}, 30_000)).result;
  }

  async hello(): Promise<HelloResult> {
    return (await this.call<HelloResult>('hello')).result;
  }
  async paramsSchema(): Promise<ParamsSchema> {
    return (await this.call<ParamsSchema>('params_schema')).result;
  }
  async probe(path: string): Promise<ProbeResult> {
    return (await this.call<ProbeResult>('probe', { path })).result;
  }
  async thumbnail(path: string, longEdge: number, embeddedOnly = false): Promise<RgbaImage> {
    const r = await this.call<{ image: ImageInfo; orientation?: number }>('thumbnail',
      { path, long_edge: longEdge, ...(embeddedOnly ? { embedded_only: true } : {}) }, 60_000);
    return displayImage(r.result.image, r.payload);
  }
  async open(path: string, params: WireParams, decode?: object | null): Promise<OpenResult> {
    return (await this.call<OpenResult>('open', decode ? { path, params, decode } : { path, params }, 300_000)).result;
  }
  async openPair(path: string, params: WireParams, pair: HalfFramePair): Promise<OpenResult> {
    return (await this.call<OpenResult>('open_pair', { path, params, pair: structuredClone(pair) }, 600_000)).result;
  }
  async updatePair(session: string, pair: HalfFramePair, params: WireParams): Promise<OpenResult> {
    return (await this.call<OpenResult>('update_pair', { session, params, pair: structuredClone(pair) }, 600_000)).result;
  }
  /** Decode the session's file again with other decode settings; params are kept (R2). */
  async redecode(session: string, decode: object): Promise<OpenResult> {
    return (await this.call<OpenResult>('redecode', { session, decode }, 300_000)).result;
  }
  async renderSource(session: string, opts: { long_edge: number; display: 'srgb' | 'display-p3'; generation: number }): Promise<RgbaImage> {
    const r = await this.call<{ image: ImageInfo; generation: number }>('render_source', { session, ...opts }, 180_000);
    const i = r.result.image;
    if (r.result.generation !== opts.generation || !i || i.width <= 0 || i.height <= 0 ||
        i.row_bytes !== i.width * 4 || r.payload.byteLength !== i.width * i.height * 4)
      throw new HostCallError('render_source', 'internal', 'invalid or outdated decoded source response');
    return displayImage(i, r.payload);
  }
  async pickNeutral(session: string, x: number, y: number, side?: 'left' | 'right'): Promise<{ temperature_k: number; tint: number }> {
    return (await this.call<{ temperature_k: number; tint: number }>('pick_neutral', { session, x, y, ...(side ? { side } : {}) }, 30_000)).result;
  }
  async close(session: string): Promise<void> {
    await this.call('close', { session });
  }
  async setParams(session: string, delta: WireParams): Promise<WireParams> {
    return (await this.call<{ params: WireParams }>('set_params', { session, delta })).result.params;
  }
  async solve(session: string, target = 'both'): Promise<Record<string, unknown>> {
    return (await this.call<Record<string, unknown>>('solve', { session, target }, 120_000)).result;
  }
  async render(session: string, tier: Tier, opts: { reprint?: boolean; progressId?: string } = {}): Promise<RenderReply> {
    const t0 = performance.now();
    const r = await this.call<{ image: ImageInfo; tier: Tier; reprinted: boolean }>(
      'render',
      { session, tier, reprint: opts.reprint ?? false, format: 'rgba8', display: 'srgb', progress_id: opts.progressId },
      tier === 'full' ? 900_000 : 180_000,
    );
    return { ...displayImage(r.result.image, r.payload), tier: r.result.tier ?? tier, reprinted: !!r.result.reprinted, ms: performance.now() - t0 };
  }
  async sceneLatitude(session: string, request: Record<string, unknown>, snapshot?: { params?: WireParams; source_geometry?: Geometry }): Promise<Record<string, unknown>> {
    return (await this.call<Record<string, unknown>>('scene_latitude', { session, request, ...snapshot })).result;
  }

  async renderView(session: string, tier: Tier, opts: {
    adjustments: Adjustments; geometry: Geometry; display: 'srgb' | 'display-p3'; generation: number; long_edge?: number;
    source_geometry?: Geometry;
    no_film?: boolean;
  }): Promise<RenderReply> {
    const snapshot = structuredClone(opts);
    const state = await this.state();
    if (snapshot.no_film && !(state.phase === 'ready' && state.hello.view_options?.includes('no_film')))
      throw new HostCallError('render_view', 'unsupported', 'This engine does not support no_film viewing.');
    const format = state.phase === 'ready' && state.hello.view_formats?.includes('rgba16') ? 'rgba16' : 'rgba8';
    const t0 = performance.now();
    const r = await this.call<{ image: ImageInfo; tier: Tier; print_cached: boolean; generation: number; pair_info?: PairInfo }>(
      'render_view', { session, tier, ...snapshot, format }, tier === 'full' ? 900_000 : 180_000,
    );
    if (r.result.generation !== snapshot.generation) throw new HostCallError('render_view', 'internal', 'view generation mismatch');
      const image = r.result.image;
      return { ...displayImage(image, r.payload), processedGeometry: snapshot.geometry,
        pairInfo: r.result.pair_info,
        nativeSize: image.source_width && image.source_height ? { width: image.source_width, height: image.source_height } : undefined,
      tier: r.result.tier, reprinted: r.result.print_cached, ms: performance.now() - t0 };
  }
  async renderProof(params: Record<string, unknown> & { generation: number }): Promise<ProofReply> {
    const snapshot = structuredClone(params);
    const r = await this.call<RenderProofResult>('render_proof', snapshot, 1_800_000);
    const i = r.result.image;
    if (r.result.generation !== snapshot.generation || !i || i.width <= 0 || i.height <= 0 ||
        i.row_bytes !== i.width * 4 || r.payload.byteLength !== i.width * i.height * 4)
      throw new HostCallError('render_proof', 'internal', 'invalid or outdated proof response');
    return { ...displayImage(i, r.payload), proof: r.result };
  }
  /** True when the request carrying `progressId` was running (else it is refused when it reaches the worker). */
  async cancel(session: string, progressId: string): Promise<boolean> {
    return !!(await this.call<{ was_running?: boolean }>('cancel', { session, progress_id: progressId })).result?.was_running;
  }
  async exportImage(params: {
    session: string;
    path: string;
    format: 'tiff16' | 'tiff8' | 'jpeg' | 'png';
    quality?: number;
    color_space?: 'sRGB' | 'display-p3' | 'prophoto' | 'adobe-rgb' | 'rec2020';
    long_edge?: number;
    overwrite?: boolean;
  }): Promise<{ path: string; width: number; height: number; bytes: number }> {
    return (await this.call<{ path: string; width: number; height: number; bytes: number }>('export_image', params, 1_800_000)).result;
  }
  async exportCube(printStock: string, path: string, size?: number): Promise<{ path: string }> {
    return (await this.call<{ path: string }>('export_cube', { print_stock: printStock, path, size }, 600_000)).result;
  }
  async exportDi(session: string, printStock: string, path: string): Promise<{ path: string }> {
    return (await this.call<{ path: string }>('export_di', { session, print_stock: printStock, path }, 1_800_000)).result;
  }
}

export type { FileMetadata };

let instance: Host | null = null;
/** The one host connection for this webview. */
export function host(): Host {
  if (!instance) instance = new Host(inTauri() ? tauriTransport() : browserTransport());
  return instance;
}
