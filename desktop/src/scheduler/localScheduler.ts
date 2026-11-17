// localScheduler.ts — phase 1's scheduler, in the page.
//
// The Windows host is one serial worker (README §7), so this is a queue with
// one job running at a time, ordered by who asked (`JOB_PRIORITY`), and the
// rules the pages rely on:
//
//  - **an edit settles** before it renders: a canvas job waits `settleMs`
//    (180 ms) after it is submitted, saying `settling`;
//  - **newer edits fold into the newest job**: a canvas job submitted while an
//    older canvas job of the same frame is still waiting replaces it (the old
//    one ends `cancelled`, `supersededBy` the new one); one that is already
//    running finishes, but is marked `superseded` so its picture is not shown;
//    a full view, a thumbnail and a stock preview fold the same way (by frame,
//    by frame, by slot);
//  - a waiting job **says why** (`settling`, `queued`, `dialog`, `background`);
//  - cancel takes a job out of the queue; a running one ends `cancelled` after
//    its current host step, which the host cannot interrupt.
//
// It runs the job's steps through an injected executor, so the tests drive it
// on a virtual clock with a fake host, and the app drives it with the v1 host
// client. In phase 2 the Rust scheduler (`desktop/crates/spk-scheduler`)
// takes this role behind the same `SchedulerClient` and this file becomes the
// in-page mock only.

import {
  JOB_PRIORITY, isCanvas,
  type BudgetReading, type FrontendState, type HostStep, type JobKind, type JobOutcome, type JobRequest,
  type JobSnapshot, type JobState, type RenderStage, type SchedulerClient, type StepResult,
} from './types';

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

export interface StepContext {
  job: Readonly<JobRequest>;
  jobId: string;
  /** Report the stage (and a fraction where the host has one). */
  progress(stage: RenderStage | null, fraction: number | null): void;
}
export type StepExecutor = (step: HostStep, ctx: StepContext) => Promise<StepResult>;

export interface LocalSchedulerOptions {
  clock?: Clock;
  /** Per kind; canvas jobs default to 180 ms (README §7), the rest to 0. */
  settleMs?: Partial<Record<JobKind, number>>;
  budget?: () => Omit<BudgetReading, 'running' | 'queued'>;
}

interface Entry {
  id: string;
  req: JobRequest;
  submitted: number;
  readyAt: number;
  state: JobState;
  startedAt?: number;
  endedAt?: number;
  superseded: boolean;
  supersededBy?: string;
  cancelRequested: boolean;
  results: StepResult[];
  waiters: ((o: JobOutcome) => void)[];
  outcome?: JobOutcome;
}

export const DEFAULT_SETTLE: Record<JobKind, number> = {
  canvasReprint: 180, canvasDevelop: 180, fullView: 0, export: 0, thumbnail: 0, stockPreview: 0,
};

/** Jobs that fold into each other: the same frame and the same purpose. */
function foldKey(r: JobRequest): string {
  if (isCanvas(r.kind)) return `canvas|${r.frameId}`;
  if (r.kind === 'stockPreview') return `stock|${r.slot ?? r.frameId}`;
  if (r.kind === 'export') return `export|${r.frameId}|${JSON.stringify(r.steps)}`;
  return `${r.kind}|${r.frameId}`;
}

export class LocalScheduler implements SchedulerClient {
  private entries = new Map<string, Entry>();
  private order: string[] = [];
  private running: Entry | null = null;
  private listeners = new Set<(s: JobSnapshot) => void>();
  private timer: unknown = null;
  private nextId = 1;
  private front: FrontendState = { visiblePage: 'edit', openFrame: null, foreground: true, interaction: 'idle', dialogOpen: false };
  private readonly clock: Clock;
  private readonly settle: Record<JobKind, number>;
  /** Kept so `snapshot()` can still report a job that ended (the page reads the last outcome). */
  private ended: Entry[] = [];

  constructor(private exec: StepExecutor, private opts: LocalSchedulerOptions = {}) {
    this.clock = opts.clock ?? realClock;
    this.settle = { ...DEFAULT_SETTLE, ...(opts.settleMs ?? {}) };
  }

  setExecutor(exec: StepExecutor) { this.exec = exec; }
  setSettle(settle: Partial<Record<JobKind, number>>) { Object.assign(this.settle, settle); }

  async submit(req: JobRequest): Promise<string> {
    const id = `j${this.nextId++}`;
    const now = this.clock.now();
    const key = foldKey(req);
    let kind = req.kind;
    for (const oid of this.order) {
      const o = this.entries.get(oid)!;
      if (foldKey(o.req) !== key) continue;
      // A develop folded into a reprint still has to develop.
      if (isCanvas(kind) && o.req.kind === 'canvasDevelop') kind = 'canvasDevelop';
      this.finish(o, { state: 'cancelled', supersededBy: id }, { supersededBy: id });
    }
    if (this.running && foldKey(this.running.req) === key && !this.running.superseded) {
      this.running.superseded = true;
      this.running.supersededBy = id;
      this.emit(this.running);
    }
    const r = { ...req, kind };
    const e: Entry = { id, req: r, submitted: now, readyAt: now + (this.settle[kind] ?? 0), state: { state: 'queued' },
      superseded: false, cancelRequested: false, results: [], waiters: [] };
    this.entries.set(id, e);
    this.order.push(id);
    this.emit(e);
    this.pump();
    return id;
  }

  async cancel(jobId: string): Promise<void> {
    const e = this.entries.get(jobId);
    if (!e || e.outcome) return;
    if (e === this.running) { e.cancelRequested = true; return; }
    this.finish(e, { state: 'cancelled' });
    this.pump();
  }

  async cancelFrame(frameId: string, kinds?: JobKind[]): Promise<void> {
    for (const e of [...this.entries.values()]) {
      if (e.req.frameId !== frameId || (kinds && !kinds.includes(e.req.kind))) continue;
      await this.cancel(e.id);
    }
  }

  outcome(jobId: string): Promise<JobOutcome> {
    const e = this.entries.get(jobId) ?? this.ended.find((x) => x.id === jobId);
    if (!e) return Promise.resolve({ id: jobId, status: 'cancelled', superseded: false, results: [] });
    if (e.outcome) return Promise.resolve(e.outcome);
    return new Promise((res) => e.waiters.push(res));
  }

  async snapshot(frameId?: string): Promise<JobSnapshot[]> {
    return [...this.entries.values()].filter((e) => !frameId || e.req.frameId === frameId).map((e) => this.snap(e));
  }

  async budget(): Promise<BudgetReading> {
    const b = this.opts.budget?.() ?? { device: null, backend: null, budgetBytes: null, inUseBytes: null };
    return { ...b, running: this.running ? 1 : 0, queued: this.order.length };
  }

  async frontendState(state: FrontendState): Promise<void> {
    this.front = state;
    for (const id of this.order) this.emit(this.entries.get(id)!, true);
    this.pump();
  }

  onJob(listener: (s: JobSnapshot) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  /** For tests and the page: the snapshot of one job, ended or not. */
  peek(jobId: string): JobSnapshot | null {
    const e = this.entries.get(jobId) ?? this.ended.find((x) => x.id === jobId);
    return e ? this.snap(e) : null;
  }

  // ----------------------------------------------------------------- inside

  private snap(e: Entry): JobSnapshot {
    const { steps: _steps, ...job } = e.req;
    return { id: e.id, job: { ...job, submitted: e.submitted }, state: e.state, startedAt: e.startedAt, endedAt: e.endedAt, superseded: e.superseded || undefined };
  }

  private emit(e: Entry, waitingOnly = false) {
    if (waitingOnly && e.state.state !== 'queued' && e.state.state !== 'waiting') return;
    if (!e.outcome && e !== this.running) e.state = this.waitState(e);
    const s = this.snap(e);
    for (const l of this.listeners) l(s);
  }

  private waitState(e: Entry): JobState {
    if (this.front.dialogOpen && isCanvas(e.req.kind)) return { state: 'waiting', reason: 'dialog' };
    if (!this.front.foreground && e.req.kind !== 'export') return { state: 'waiting', reason: 'background' };
    if (this.clock.now() < e.readyAt) return { state: 'waiting', reason: 'settling' };
    if (this.running || this.blockedBySettling(e)) return { state: 'waiting', reason: 'queued' };
    return { state: 'queued' };
  }

  /** A canvas job still settling holds back anything less urgent (it would wait behind it otherwise). */
  private blockedBySettling(e: Entry): boolean {
    const now = this.clock.now();
    return this.order.some((id) => {
      const o = this.entries.get(id)!;
      return o !== e && isCanvas(o.req.kind) && now < o.readyAt && JOB_PRIORITY[o.req.kind] < JOB_PRIORITY[e.req.kind];
    });
  }

  private runnable(e: Entry, now: number): boolean {
    if (now < e.readyAt) return false;
    if (this.front.dialogOpen && isCanvas(e.req.kind)) return false;
    if (!this.front.foreground && e.req.kind !== 'export') return false;
    return !this.blockedBySettling(e);
  }

  private pump() {
    if (this.running) return;
    if (this.timer !== null) { this.clock.clearTimeout(this.timer); this.timer = null; }
    const now = this.clock.now();
    const ready = this.order.map((id) => this.entries.get(id)!).filter((e) => this.runnable(e, now));
    ready.sort((a, b) => JOB_PRIORITY[a.req.kind] - JOB_PRIORITY[b.req.kind] || a.submitted - b.submitted);
    const next = ready[0];
    if (next) { void this.run(next); return; }
    // Nothing ready: wake when the first settling job is.
    const waits = this.order.map((id) => this.entries.get(id)!.readyAt).filter((t) => t > now);
    if (waits.length) this.timer = this.clock.setTimeout(() => { this.timer = null; this.pump(); }, Math.min(...waits) - now);
    for (const id of this.order) this.emit(this.entries.get(id)!, true);
  }

  private async run(e: Entry) {
    this.order = this.order.filter((id) => id !== e.id);
    this.running = e;
    e.startedAt = this.clock.now();
    e.state = { state: 'running', stage: null, fraction: null, step: 0, steps: e.req.steps.length };
    this.emit(e);
    for (const id of this.order) this.emit(this.entries.get(id)!, true);
    let failure: { message: string; code?: string } | null = null;
    for (let i = 0; i < e.req.steps.length; i++) {
      if (e.cancelRequested) break;
      e.state = { state: 'running', stage: null, fraction: null, step: i, steps: e.req.steps.length };
      this.emit(e);
      try {
        const r = await this.exec(e.req.steps[i]!, {
          job: e.req, jobId: e.id,
          progress: (stage, fraction) => {
            if (this.running !== e) return;
            e.state = { state: 'running', stage, fraction, step: i, steps: e.req.steps.length };
            this.emit(e);
          },
        });
        e.results.push(r);
      } catch (err) {
        const ex = err as { message?: string; code?: string };
        failure = { message: ex?.message ?? String(err), ...(ex?.code ? { code: ex.code } : {}) };
        break;
      }
    }
    this.running = null;
    if (failure) this.finish(e, { state: 'failed', ...failure }, { error: failure });
    else if (e.cancelRequested) this.finish(e, { state: 'cancelled' });
    else this.finish(e, { state: 'done' });
    this.pump();
  }

  private finish(e: Entry, state: JobState, extra: Partial<JobOutcome> = {}) {
    this.order = this.order.filter((id) => id !== e.id);
    e.state = state;
    e.endedAt = this.clock.now();
    const status = state.state === 'done' ? 'done' : state.state === 'failed' ? 'failed' : 'cancelled';
    e.outcome = { id: e.id, status, superseded: e.superseded || !!extra.supersededBy, supersededBy: e.supersededBy ?? extra.supersededBy, results: e.results, ...extra };
    this.entries.delete(e.id);
    this.ended.push(e);
    if (this.ended.length > 64) this.ended.shift();
    this.emit(e);
    for (const w of e.waiters.splice(0)) w(e.outcome);
  }
}
