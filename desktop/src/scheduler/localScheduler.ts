// localScheduler.ts — the in-page scheduler: the browser mock (Playwright, `vite`
// alone) and the unit tests' scheduler. **Not on the app's path**: under Tauri
// the webview submits to the Rust scheduler (`tauriScheduler.ts`). It speaks
// WIRE.md exactly as the Rust one does (`wire.test.ts` holds both to WIRE.md's
// examples), and runs jobs on an `Engine` (`mockEngine.ts`: the Rust
// `HostEngine`'s session rules, over the page's host client).
//
// The rules the pages rely on, as phase 1 built them:
//
//  - **an edit settles** before it renders: a canvas job waits `settleMs`
//    (180 ms) after it is submitted, saying `settling` (the app's client keeps
//    the same settle before it submits to Rust; WIRE has none);
//  - **newer edits fold into the newest job**: a canvas job submitted while an
//    older canvas job of the same frame is still waiting replaces it (the old
//    one ends `cancelled`); a full view, a thumbnail and a stock preview fold
//    the same way (by frame, by frame, by slot);
//  - a waiting job **says why** (`settling`, `queued`, `dialog`, `background`);
//  - two lanes: renders run one at a time; thumbnails beside them, two at a time;
//  - cancel takes a job out of the queue; a running one is cancelled on the
//    engine (a call with a progress id is stopped; one without finishes and its
//    result is thrown away).

import {
  JOB_PRIORITY, isCanvas, verbOf, waitText,
  type BudgetReadingWire, type FrontendState, type HostReply, type JobKind, type JobSnapshotWire, type JobSpec,
  type JobStateWire, type Outcome, type OutcomeWire, type RenderStage, type SchedulerClient, type SourceSpec, type WaitReason,
} from './types';
import type { Engine, EngineRun } from './mockEngine';

export interface Clock {
  now(): number;
  setTimeout(fn: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export const realClock: Clock = {
  now: () => (typeof performance !== 'undefined' ? performance.now() : Date.now()),
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
};

export interface LocalSchedulerOptions {
  clock?: Clock;
  /** Per kind; canvas jobs default to 180 ms (README §7), the rest to 0. */
  settleMs?: Partial<Record<JobKind, number>>;
  /** The engine's name in `budget()`. */
  engineName?: string;
}

interface Entry {
  id: string;
  spec: JobSpec;
  submitted: number;
  readyAt: number;
  state: JobStateWire;
  startedAt?: number;
  cancelRequested: boolean;
  run?: EngineRun;
  waiters: ((o: Outcome) => void)[];
  outcome?: OutcomeWire;
  payload?: Uint8Array;
}

export type Lane = 'render' | 'decode';
export const laneOf = (k: JobKind): Lane => (k === 'thumbnail' ? 'decode' : 'render');
export const LANE_CAPACITY: Record<Lane, number> = { render: 1, decode: 2 };

export const DEFAULT_SETTLE: Record<JobKind, number> = {
  canvasReprint: 180, canvasDevelop: 180, shot: 0, importDevelop: 0, fullView: 0, export: 0, thumbnail: 0, stockPreview: 0,
};

/** Jobs that fold into each other: the same frame and the same purpose. */
function foldKey(r: JobSpec): string {
  if (isCanvas(r.kind)) return `canvas|${r.frameId}`;
  if (r.kind === 'stockPreview') return `stock|${r.frameId}|${r.slot ?? ''}`;
  if (r.kind === 'export') return `export|${r.frameId}|${JSON.stringify(r.request)}`;
  return `${r.kind}|${r.frameId}|${r.slot ?? ''}`;
}

const EMPTY = new Uint8Array(0);
let uuidCounter = 0;
/** Upper-case UUID-shaped ids, as the Rust scheduler's (WIRE.md). */
function jobUuid(): string {
  const n = (++uuidCounter).toString(16).padStart(12, '0').toUpperCase();
  return `00000000-0000-4000-8000-${n}`;
}

const failureMessage = (err: unknown) => (err instanceof Error ? err.message : String(err));
const isCancelled = (err: unknown) => (err as { code?: string })?.code === 'cancelled' || /^cancelled\b/.test(failureMessage(err));

export class LocalScheduler implements SchedulerClient {
  private entries = new Map<string, Entry>();
  private order: string[] = [];
  private running = new Set<Entry>();
  private listeners = new Set<(s: JobSnapshotWire) => void>();
  private timer: unknown = null;
  private front: FrontendState = { visiblePage: 'edit', openFrame: null, foreground: true, interaction: 'idle', dialogOpen: false };
  private readonly clock: Clock;
  private readonly settle: Record<JobKind, number>;
  /** The last 100 ended jobs, as the Rust scheduler keeps them (an id it no longer knows reads as cancelled). */
  private ended: Entry[] = [];

  constructor(private engine: Engine, private opts: LocalSchedulerOptions = {}) {
    this.clock = opts.clock ?? realClock;
    this.settle = { ...DEFAULT_SETTLE, ...(opts.settleMs ?? {}) };
  }

  setEngine(engine: Engine) { this.engine = engine; }
  setSettle(settle: Partial<Record<JobKind, number>>) { Object.assign(this.settle, settle); }

  async submit(spec: JobSpec): Promise<string> {
    if (!spec.frameId) throw new Error('frameId is empty');
    if (!(spec.canvas?.width > 0 && spec.canvas?.height > 0)) throw new Error(`canvas ${spec.canvas?.width}x${spec.canvas?.height} is not a picture`);
    const id = jobUuid();
    const now = this.clock.now();
    const key = foldKey(spec);
    let kind = spec.kind;
    for (const oid of this.order) {
      const o = this.entries.get(oid)!;
      if (foldKey(o.spec) !== key) continue;
      // A develop folded into a reprint still has to develop.
      if (isCanvas(kind) && o.spec.kind === 'canvasDevelop') kind = 'canvasDevelop';
      this.finish(o, { state: 'cancelled' });
    }
    const s = { ...spec, kind };
    const e: Entry = { id, spec: s, submitted: now, readyAt: now + (this.settle[kind] ?? 0), state: { state: 'queued' },
      cancelRequested: false, waiters: [] };
    this.entries.set(id, e);
    this.order.push(id);
    this.emit(e);
    this.pump();
    return id;
  }

  async cancel(jobId: string): Promise<void> {
    const e = this.entries.get(jobId);
    if (!e || e.outcome) return;
    if (this.running.has(e)) { e.cancelRequested = true; this.engine.cancel(jobId); return; }
    this.finish(e, { state: 'cancelled' });
    this.pump();
  }

  async cancelFrame(frameId: string, kinds?: JobKind[]): Promise<void> {
    for (const e of [...this.entries.values()]) {
      if (e.spec.frameId !== frameId || (kinds && !kinds.includes(e.spec.kind))) continue;
      await this.cancel(e.id);
    }
  }

  outcome(jobId: string): Promise<Outcome> {
    const e = this.entries.get(jobId) ?? this.ended.find((x) => x.id === jobId);
    if (!e) return Promise.resolve({ outcome: { jobId, outcome: 'cancelled' }, payload: EMPTY });
    if (e.outcome) return Promise.resolve(this.deliver(e));
    return new Promise((res) => e.waiters.push(res));
  }

  /** Pixels once: the first outcome after the job ended carries them; a later one says `payloadBytes: 0`. */
  private deliver(e: Entry): Outcome {
    const payload = e.payload ?? EMPTY;
    e.payload = undefined;
    const outcome = e.outcome!;
    return { outcome: outcome.result ? { ...outcome, result: { ...outcome.result, payloadBytes: payload.byteLength } } : outcome, payload };
  }

  async snapshot(frameId?: string): Promise<JobSnapshotWire[]> {
    if (frameId) {
      const live = [...this.entries.values()].filter((e) => e.spec.frameId === frameId);
      const shown = live.find((e) => this.running.has(e)) ?? live.find((e) => e.state.state === 'waiting') ?? live[0];
      return shown ? [this.snap(shown)] : [];
    }
    return [...this.entries.values()].map((e) => this.snap(e));
  }

  async budget(): Promise<BudgetReadingWire> {
    const sides = { bytes: 0, appSide: 0, phoneSide: 0, appBytes: 0, phoneBytes: 0, cameraReserve: 0, binding: 'allowance' as const };
    return {
      budget: sides, asked: sides,
      reading: { appAvailable: 0, free: 0, inactive: 0, purgeable: 0, wired: 0, compressed: 0, footprint: 0 },
      frontend: this.front.foreground ? 'camera off; active' : 'camera off; background',
      engine: { name: this.opts.engineName ?? 'in-page mock', makesPictures: true, effectVersions: 'mock' },
      policy: { device: 'mock', developCapMegapixels: 0, previewLongEdge: 1920, previewEdges: [1600, 1920, 2400, 2560, 3200, 3840], timeRatio: 1, unmeasured: ['every number: the in-page mock measures nothing'] },
      jobs: this.running.size + this.order.length,
    };
  }

  async frontendState(state: FrontendState): Promise<void> {
    const moved = this.front.openFrame && this.front.openFrame !== state.openFrame ? this.front.openFrame : null;
    this.front = state;
    // `openFrame` moving to another frame closes the old frame's editing session (WIRE.md).
    if (moved) void this.engine.closeEditing(moved);
    for (const id of this.order) this.emit(this.entries.get(id)!, true);
    this.pump();
  }

  async memoryPressure(_level: 'warning' | 'critical'): Promise<void> { /* the mock holds no memory */ }

  onJob(listener: (s: JobSnapshotWire) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  editingOpen(frameId: string, source: SourceSpec): Promise<HostReply> { return this.engine.open(frameId, source); }
  editingCall(frameId: string, session: string, method: string, params: Record<string, unknown>): Promise<HostReply> {
    return this.engine.call(frameId, session, method, params);
  }

  /** The unit tests' seam (`MockEngine.adopt`): a frame set up in the store as if opened. */
  adoptEditing(frameId: string, session: string) { this.engine.adopt?.(frameId, session); }

  /** For tests and the page: the snapshot of one job, ended or not. */
  peek(jobId: string): JobSnapshotWire | null {
    const e = this.entries.get(jobId) ?? this.ended.find((x) => x.id === jobId);
    return e ? this.snap(e) : null;
  }

  // ----------------------------------------------------------------- inside

  private snap(e: Entry): JobSnapshotWire {
    const s = e.spec;
    return { jobId: e.id, frameId: s.frameId, kind: s.kind, tier: s.tier, canvas: s.canvas, what: s.what ?? '', verb: verbOf(s.kind),
      ...(s.slot ? { slot: s.slot } : {}), ...e.state, mode: this.running.has(e) || e.outcome ? 'whole' : null } as JobSnapshotWire;
  }

  private emit(e: Entry, waitingOnly = false) {
    if (waitingOnly && e.state.state !== 'queued' && e.state.state !== 'waiting') return;
    if (!e.outcome && !this.running.has(e)) e.state = this.waitState(e);
    const s = this.snap(e);
    // A listener that throws must not stop the queue (the Rust facade's events are as isolated).
    for (const l of this.listeners) { try { l(s); } catch (err) { console.error(err); } }
  }

  private waiting(reason: WaitReason): JobStateWire { return { state: 'waiting', reason, text: waitText(reason) }; }

  private waitState(e: Entry): JobStateWire {
    if (this.front.dialogOpen && isCanvas(e.spec.kind)) return this.waiting('dialog');
    if (!this.front.foreground && e.spec.kind !== 'export') return this.waiting('background');
    if (this.clock.now() < e.readyAt) return this.waiting('settling');
    if (this.laneFull(laneOf(e.spec.kind)) || this.blockedBySettling(e)) return this.waiting('queued');
    return { state: 'queued' };
  }

  private laneFull(lane: Lane): boolean {
    let n = 0;
    for (const r of this.running) if (laneOf(r.spec.kind) === lane) n++;
    return n >= LANE_CAPACITY[lane];
  }

  /** A canvas job still settling holds back anything less urgent in its lane (it would wait behind it otherwise). */
  private blockedBySettling(e: Entry): boolean {
    const now = this.clock.now();
    return this.order.some((id) => {
      const o = this.entries.get(id)!;
      return o !== e && isCanvas(o.spec.kind) && now < o.readyAt && JOB_PRIORITY[o.spec.kind] < JOB_PRIORITY[e.spec.kind]
        && laneOf(o.spec.kind) === laneOf(e.spec.kind);
    });
  }

  private runnable(e: Entry, now: number): boolean {
    if (now < e.readyAt) return false;
    if (this.front.dialogOpen && isCanvas(e.spec.kind)) return false;
    if (!this.front.foreground && e.spec.kind !== 'export') return false;
    return !this.blockedBySettling(e);
  }

  private pump() {
    if (this.timer !== null) { this.clock.clearTimeout(this.timer); this.timer = null; }
    const now = this.clock.now();
    for (const lane of ['render', 'decode'] as const) {
      while (!this.laneFull(lane)) {
        const ready = this.order.map((id) => this.entries.get(id)!).filter((e) => laneOf(e.spec.kind) === lane && this.runnable(e, now));
        ready.sort((a, b) => JOB_PRIORITY[a.spec.kind] - JOB_PRIORITY[b.spec.kind] || a.submitted - b.submitted);
        const next = ready[0];
        if (!next) break;
        void this.run(next);
      }
    }
    const waits = this.order.map((id) => this.entries.get(id)!.readyAt).filter((t) => t > now);
    if (waits.length) this.timer = this.clock.setTimeout(() => { this.timer = null; this.pump(); }, Math.min(...waits) - now);
    for (const id of this.order) this.emit(this.entries.get(id)!, true);
  }

  private async run(e: Entry) {
    this.order = this.order.filter((id) => id !== e.id);
    this.running.add(e);
    e.startedAt = this.clock.now();
    const progress = (stage: RenderStage, fraction: number) => {
      if (!this.running.has(e)) return;
      e.state = { state: 'running', stage, fraction, band: 0, bandCount: 1 };
      this.emit(e);
    };
    progress(e.spec.request.source ? 'Decode' : e.spec.kind === 'canvasReprint' ? 'Print' : 'Film', 0);
    for (const id of this.order) this.emit(this.entries.get(id)!, true);
    let failure: string | null = null;
    let cancelled = false;
    try {
      e.run = await this.engine.run(e.spec, e.id, progress);
    } catch (err) {
      if (isCancelled(err)) cancelled = true;
      else failure = failureMessage(err);
    }
    this.running.delete(e);
    if (e.cancelRequested || cancelled) this.finish(e, { state: 'cancelled' });
    else if (failure !== null) this.finish(e, { state: 'failed', message: failure });
    else this.finish(e, { state: 'done' });
    this.pump();
  }

  private finish(e: Entry, state: JobStateWire) {
    this.order = this.order.filter((id) => id !== e.id);
    e.state = state;
    const ended = this.clock.now();
    if (state.state === 'done' && e.run) {
      const image = e.run.result.image as { width?: number; height?: number } | undefined;
      const size = image?.width && image?.height ? { width: image.width, height: image.height } : e.spec.canvas;
      e.payload = e.run.payload;
      e.outcome = { jobId: e.id, outcome: 'finished', result: { seconds: ((ended - (e.startedAt ?? ended)) / 1000), reprint: e.run.reprint, size,
        method: e.run.method, hostResult: e.run.result, payloadBytes: e.run.payload.byteLength } };
    } else if (state.state === 'failed') e.outcome = { jobId: e.id, outcome: 'failed', message: state.message };
    else e.outcome = { jobId: e.id, outcome: 'cancelled' };
    this.entries.delete(e.id);
    this.ended.push(e);
    if (this.ended.length > 100) this.ended.shift();
    this.emit(e);
    const waiters = e.waiters.splice(0);
    if (waiters.length) {
      const first = this.deliver(e);
      waiters.forEach((w, i) => w(i === 0 ? first : this.deliver(e)));
    }
  }
}
