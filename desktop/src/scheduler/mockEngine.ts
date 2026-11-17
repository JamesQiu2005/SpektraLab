// mockEngine.ts — the in-page stand-in for the Rust `HostEngine`
// (`desktop/crates/spk-scheduler/src/host/engine.rs`), so the browser mock and
// the unit tests run jobs by the rules the app's real engine runs them by
// (WIRE.md, "Sessions"):
//
//  - a canvas job runs on the frame's **editing session**, kept between canvas
//    jobs; one at a time (another frame's canvas job closes the old one); the
//    same frame from another decode is `redecode`d in place;
//  - every other job is **one-shot**: its own session, closed however it ends;
//    `export_frame`, `export_cineon`, `render_proof` get `source_path` and no
//    session; `thumbnail` needs none; `preview_stock_lut` / `render_source`
//    borrow the editing session of the same frame and source;
//  - a session the host no longer knows (`not_found`) is opened again once;
//  - `editingOpen` / `editingCall` are the webview's own calls on the frame's
//    editing session (`HostEngine::open_editing` / `call_editing`).
//
// It speaks to the host through a `HostCaller` (`method, params → {result,
// payload}`): the page's typed host client (`typedCaller`), so the Playwright
// mock host and the unit tests' stand-in clients serve it unchanged.

import type { HostReply, JobSpec, RenderStage, SourceSpec } from './types';
import { HostCallError } from '../host/transport';

export type HostCaller = (method: string, params: Record<string, unknown>) => Promise<HostReply>;

const SESSION_METHODS = ['render_view', 'render', 'export_image', 'export_di', 'preview_stock_lut', 'render_source', 'scene_latitude', 'overscan_geometry'];
const PRIVATE_SESSION_METHODS = ['export_frame', 'export_cineon', 'render_proof'];
const SESSIONLESS_METHODS = ['thumbnail', 'write_image', 'export_cube', 'probe'];
const PROGRESS_METHODS = ['render_view', 'render', 'export_frame', 'export_cineon', 'export_image', 'render_proof'];
const BORROWING_METHODS = ['preview_stock_lut', 'render_source'];

/** The host's progress stage as the scheduler names it (`HostEngine::stage_of`). */
export function stageOf(job: JobSpec, hostStage: string): RenderStage {
  if (hostStage === 'transform') return 'Scan';
  if (hostStage === 'encode') return 'Save';
  if (hostStage === 'done') return job.decodesOriginal ? 'Save' : 'Scan';
  return job.kind === 'canvasReprint' ? 'Print' : 'Film';
}

export interface EngineRun { method: string; result: Record<string, unknown>; payload: Uint8Array; reprint: boolean }

/** What the in-page scheduler runs a job on. */
export interface Engine {
  adopt?(frameId: string, session: string): void;
  run(job: JobSpec, jobId: string, progress: (stage: RenderStage, fraction: number) => void): Promise<EngineRun>;
  cancel(jobId: string): void;
  open(frameId: string, source: SourceSpec): Promise<HostReply>;
  call(frameId: string, session: string, method: string, params: Record<string, unknown>): Promise<HostReply>;
  closeEditing(frameId?: string | null): Promise<void>;
}

/** `{path, decode, pair}`: what the session's pixels are made of (`SourceSpec::key`). */
const keyOf = (s: SourceSpec) => JSON.stringify({ path: s.path, decode: s.decode ?? null, pair: s.pair ?? null });

const openCall = (s: SourceSpec): [string, Record<string, unknown>] => s.pair
  ? ['open_pair', { path: s.path, pair: s.pair, params: s.params ?? {} }]
  : ['open', { path: s.path, ...(s.decode ? { decode: s.decode } : {}), ...(s.params ? { params: s.params } : {}) }];

interface Editing { frame: string; session: string; key: string; source: SourceSpec }

/** An error as the engine words it: `code: message` (the Rust `EngineError::Failed`). */
export class EngineFailure extends Error {
  constructor(readonly code: string, message: string) { super(`${code}: ${message}`); }
}

const codeOf = (e: unknown) => (e instanceof HostCallError ? e.code : (e as { code?: string })?.code) ?? 'internal';
const messageOf = (e: unknown) => (e instanceof Error ? e.message : String(e));

export class MockEngine implements Engine {
  private editing: Editing | null = null;
  private lock: Promise<void> = Promise.resolve();
  private cancelled = new Set<string>();
  private inFlight: { job: string; session: string; progressId: string } | null = null;
  /** For a progress forwarder: the host's `progress` events (the Tauri layer forwards them in the app). */
  constructor(private call_: HostCaller, private onEvent?: (cb: (e: Record<string, unknown>) => void) => () => void) {}

  /** Every call that touches a session, one at a time (the engine's `sessions` lock). */
  private async serial<T>(fn: () => Promise<T>): Promise<T> {
    const prior = this.lock;
    let release!: () => void;
    this.lock = new Promise((r) => { release = r; });
    await prior;
    try { return await fn(); } finally { release(); }
  }

  private async ask(method: string, params: Record<string, unknown>): Promise<HostReply> {
    try { return await this.call_(method, params); } catch (e) {
      const code = codeOf(e);
      if (code === 'host_exited' || code === 'not_running') this.editing = null;
      throw new EngineFailure(code, messageOf(e));
    }
  }

  private async close(session: string) { await this.call_('close', { session }).catch(() => {}); }

  private async openSession(source: SourceSpec): Promise<string> {
    const [method, params] = openCall(source);
    const r = await this.ask(method, params);
    const session = r.result.session;
    if (typeof session !== 'string') throw new EngineFailure('internal', `${method}: no session in the reply`);
    return session;
  }

  async open(frameId: string, source: SourceSpec): Promise<HostReply> {
    return this.serial(async () => {
      if (this.editing) { const old = this.editing; this.editing = null; await this.close(old.session); }
      const [method, params] = openCall(source);
      const r = await this.call_(method, params);
      if (typeof r.result.session === 'string') this.editing = { frame: frameId, session: r.result.session, key: keyOf(source), source };
      return r;
    });
  }

  async call(frameId: string, session: string, method: string, params: Record<string, unknown>): Promise<HostReply> {
    return this.serial(async () => {
      const e = this.editing;
      if (!e || e.frame !== frameId || e.session !== session)
        throw new HostCallError(method, 'not_found', `${frameId} has no editing session ${session}`);
      try {
        const r = await this.call_(method, { ...params, session });
        if (method === 'redecode') e.source = { ...e.source, decode: params.decode as Record<string, unknown> };
        if (method === 'update_pair') e.source = { ...e.source, pair: params.pair };
        e.key = keyOf(e.source);
        return r;
      } catch (err) {
        const code = codeOf(err);
        if (code === 'not_found' || code === 'host_exited' || code === 'not_running') this.editing = null;
        throw err;
      }
    });
  }

  /**
   * The test seam: a unit test that puts a frame in the session store as if it had been opened tells
   * the engine the same (the frame's editing session is `session`, from whatever source its first
   * canvas job names). Nothing in the app calls it: the app opens frames through `open`.
   */
  adopt(frameId: string, session: string) {
    this.editing = { frame: frameId, session, key: '*', source: { path: frameId } };
  }

  async closeEditing(frameId?: string | null) {
    await this.serial(async () => {
      if (this.editing && (!frameId || this.editing.frame === frameId)) { const old = this.editing; this.editing = null; await this.close(old.session); }
    });
  }

  cancel(jobId: string) {
    this.cancelled.add(jobId);
    const f = this.inFlight;
    if (f && f.job === jobId) void this.call_('cancel', { session: f.session, progress_id: f.progressId }).catch(() => {});
  }

  async run(job: JobSpec, jobId: string, progress: (stage: RenderStage, fraction: number) => void): Promise<EngineRun> {
    if (this.cancelled.delete(jobId)) throw new EngineFailure('cancelled', 'cancelled');
    try {
      // A sessionless call (a thumbnail) touches no session: the mock lets two run beside the renders, as
      // phase 1's decode lane did (the Rust engine takes its lock for every job).
      if (SESSIONLESS_METHODS.includes(job.request.method)) return await this.runOn(job, jobId, progress);
      return await this.serial(() => this.runOn(job, jobId, progress));
    } finally { this.cancelled.delete(jobId); }
  }

  private async place(job: JobSpec): Promise<{ session: string | null; owned: boolean; fresh: boolean }> {
    const { method, source } = job.request;
    const canvas = job.kind === 'canvasDevelop' || job.kind === 'canvasReprint';
    const oneShot = job.tier === 'full' || !canvas;
    if (SESSIONLESS_METHODS.includes(method) || (PRIVATE_SESSION_METHODS.includes(method) && oneShot)) return { session: null, owned: false, fresh: false };
    if (!SESSION_METHODS.includes(method) && !PRIVATE_SESSION_METHODS.includes(method)) throw new EngineFailure('failed', `${method} is not a call the scheduler runs`);
    if (!source) throw new EngineFailure('failed', `${method} needs a source to open`);
    const key = keyOf(source);
    const e0 = this.editing;
    if (e0 && e0.key === '*' && e0.frame === job.frameId) { e0.key = key; e0.source = source; }
    const same = !!this.editing && this.editing.frame === job.frameId && this.editing.key === key;
    if (oneShot) {
      if (BORROWING_METHODS.includes(method) && same) return { session: this.editing!.session, owned: false, fresh: false };
      return { session: await this.openSession(source), owned: true, fresh: true };
    }
    if (same) return { session: this.editing!.session, owned: false, fresh: false };
    const e = this.editing;
    if (e && e.frame === job.frameId && e.source.path === source.path && !e.source.pair && !source.pair) {
      try {
        await this.ask('redecode', { session: e.session, decode: source.decode ?? {} });
        e.source = source; e.key = key;
        return { session: e.session, owned: false, fresh: true };
      } catch (err) { if (err instanceof EngineFailure && err.code === 'cancelled') throw err; }
    }
    if (this.editing) { const old = this.editing; this.editing = null; await this.close(old.session); }
    const session = await this.openSession(source);
    this.editing = { frame: job.frameId, session, key, source };
    return { session, owned: false, fresh: true };
  }

  private async runOn(job: JobSpec, jobId: string, progress: (stage: RenderStage, fraction: number) => void): Promise<EngineRun> {
    const { method, source, setParams } = job.request;
    const reprint = job.kind === 'canvasReprint';
    if (source) progress('Decode', 0);
    for (let retried = false; ; retried = true) {
      // No await for a sessionless call: it reaches the host in the same turn as its submit (as phase 1's did).
      const placed = SESSIONLESS_METHODS.includes(method) ? { session: null, owned: false, fresh: false } : await this.place(job);
      try {
        if (setParams && placed.session) await this.ask('set_params', { session: placed.session, delta: setParams });
        if (this.cancelled.has(jobId)) throw new EngineFailure('cancelled', 'cancelled');
        const progressId = PROGRESS_METHODS.includes(method) ? `spk-${jobId}` : null;
        const params: Record<string, unknown> = { ...job.request.params };
        delete params.session; delete params.progress_id;
        if (placed.session) params.session = placed.session;
        if (PRIVATE_SESSION_METHODS.includes(method) && !placed.session && !('source_path' in params) && source) params.source_path = source.path;
        if (progressId) params.progress_id = progressId;
        this.inFlight = progressId ? { job: jobId, session: placed.session ?? '', progressId } : null;
        progress(reprint ? 'Print' : 'Film', placed.fresh ? 0.15 : 0.05);
        const stop = progressId && this.onEvent ? this.onEvent((e) => {
          if (e.event === 'progress' && e.progress_id === progressId) progress(stageOf(job, String(e.stage ?? '')), 0.15 + 0.8 * Math.min(1, Math.max(0, Number(e.fraction) || 0)));
        }) : null;
        let r: HostReply;
        try { r = await this.ask(method, params); } finally { stop?.(); this.inFlight = null; }
        if (!progressId && this.cancelled.has(jobId)) throw new EngineFailure('cancelled', 'cancelled');
        progress(job.decodesOriginal ? 'Save' : 'Scan', 0.97);
        return { method, result: r.result, payload: r.payload, reprint: !!(r.result.reprinted ?? r.result.print_cached) };
      } catch (err) {
        if (err instanceof EngineFailure && err.code === 'not_found' && !placed.fresh && !placed.owned && !retried) { this.editing = null; continue; }
        throw err;
      } finally {
        if (placed.owned && placed.session) await this.close(placed.session);
      }
    }
  }
}
