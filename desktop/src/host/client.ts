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
  ParamsSchema,
  ProbeResult,
  Tier,
  WireParams,
} from '@shared/protocol';
import { browserTransport } from './browserShim';
import { tauriTransport } from './tauriTransport';
import { HostCallError, inTauri, type Transport } from './transport';

export { HostCallError };

/** Pixels as the canvas takes them: rgba8, top row first. */
export interface RgbaImage {
  width: number;
  height: number;
  data: Uint8Array;
  colorSpace: string;
}

export interface RenderReply extends RgbaImage {
  tier: Tier;
  reprinted: boolean;
  ms: number;
}

function rgba8(info: ImageInfo, payload: Uint8Array): RgbaImage {
  if (info.format !== 'rgba8') throw new HostCallError('render', 'bad_request', `expected rgba8, got ${info.format}`);
  const tight = info.width * 4;
  let data = payload;
  if (info.row_bytes && info.row_bytes !== tight) {
    data = new Uint8Array(tight * info.height);
    for (let y = 0; y < info.height; y++)
      data.set(payload.subarray(y * info.row_bytes, y * info.row_bytes + tight), y * tight);
  }
  return { width: info.width, height: info.height, data, colorSpace: info.color_space };
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

  async hello(): Promise<HelloResult> {
    return (await this.call<HelloResult>('hello')).result;
  }
  async paramsSchema(): Promise<ParamsSchema> {
    return (await this.call<ParamsSchema>('params_schema')).result;
  }
  async probe(path: string): Promise<ProbeResult> {
    return (await this.call<ProbeResult>('probe', { path })).result;
  }
  async thumbnail(path: string, longEdge: number): Promise<RgbaImage> {
    const r = await this.call<{ image: ImageInfo; orientation?: number }>('thumbnail', { path, long_edge: longEdge }, 60_000);
    return rgba8(r.result.image, r.payload);
  }
  async open(path: string, params: WireParams, decode?: object | null): Promise<OpenResult> {
    return (await this.call<OpenResult>('open', decode ? { path, params, decode } : { path, params }, 300_000)).result;
  }
  /** Decode the session's file again with other decode settings; params are kept (R2). */
  async redecode(session: string, decode: object): Promise<OpenResult> {
    return (await this.call<OpenResult>('redecode', { session, decode }, 300_000)).result;
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
    return { ...rgba8(r.result.image, r.payload), tier: r.result.tier ?? tier, reprinted: !!r.result.reprinted, ms: performance.now() - t0 };
  }
  async sceneLatitude(session: string, request: Record<string, unknown>): Promise<Record<string, unknown>> {
    return (await this.call<Record<string, unknown>>('scene_latitude', { session, request })).result;
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
    color_space?: 'sRGB' | 'display-p3' | 'prophoto';
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
