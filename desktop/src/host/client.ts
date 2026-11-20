// client.ts — the host's methods (HOST-PROTOCOL.md §3) as typed calls.
//
// Everything above this file speaks in these types; nothing above it knows
// whether the host is the C++ engine, the stdio mock or the in-page shim.

import type {
  FileMetadata,
  HelloResult,
  HostState,
  ImageInfo,
  MemoryReport,
  OpenResult,
  ParamsSchema,
  ProbeResult,
  RenderProofResult,
  Tier,
  WireParams,
} from '@shared/protocol';
import { browserTransport } from './browserShim';
import { tauriTransport } from './tauriTransport';
import { HostCallError, inTauri, type Transport } from './transport';
import { displayImage, renderReply, renderViewReply, sourceReply, type RenderReply, type RgbaImage } from './replies';
import type { Adjustments } from '@shared/adjustments';
import type { Geometry } from '@shared/geometry';
import type { HalfFramePair } from '@shared/pair';

export { HostCallError };

export type { RgbaImage, RenderReply };
export { displayImage };

export interface ProofReply extends RgbaImage {
  proof: RenderProofResult;
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
  async memoryReport(): Promise<MemoryReport> {
    return (await this.call<MemoryReport>('memory_report', {}, 30_000)).result;
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
    const r = await this.call<Record<string, unknown>>('render_source', { session, ...opts }, 180_000);
    return sourceReply(r.result, r.payload, opts.generation);
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
    const r = await this.call<Record<string, unknown>>(
      'render',
      { session, tier, reprint: opts.reprint ?? false, format: 'rgba8', display: 'srgb', progress_id: opts.progressId },
      tier === 'full' ? 900_000 : 180_000,
    );
    return renderReply(r.result, r.payload, tier, performance.now() - t0);
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
    const r = await this.call<Record<string, unknown>>('render_view', { session, tier, ...snapshot, format }, tier === 'full' ? 900_000 : 180_000);
    return renderViewReply(r.result, r.payload, { ...snapshot, tier }, performance.now() - t0);
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
