// tauriScheduler.ts — the app's scheduler: the Rust one (`spk-scheduler`, over
// the app's one engine host), through the Tauri commands WIRE.md defines
// (`src-tauri/src/scheduler.rs`). The Rust queue owns every rule of order,
// memory and session; this client keeps only what WIRE leaves to the page:
//
//  - **the settle** (README §7): a canvas job waits `SETTLE_MS` here before it
//    is submitted, and a newer canvas job of the same frame replaces one still
//    settling (it ends `cancelled` without ever reaching Rust), so a drag
//    submits its last value, not every value;
//  - **a file dialog holds pending edits** (README §7): a canvas job settles
//    until the dialog closes, saying `dialog`;
//  - ids: a job held here has a page id until Rust gives it one; events and
//    outcomes are reported under the id `submit` returned.

import { invoke } from '@tauri-apps/api/core';
import { listen } from '@tauri-apps/api/event';
import { decodeFrame } from '@shared/framing';
import { HostCallError } from '../host/transport';
import {
  frontendMsg, isCanvas, verbOf, waitText,
  type BudgetReadingWire, type FrontendState, type HostReply, type JobKind, type JobSnapshotWire, type JobSpec,
  type Outcome, type OutcomeWire, type SchedulerClient, type SourceSpec, type WaitReason,
} from './types';

export const SETTLE_MS = 180;
const EMPTY = new Uint8Array(0);

export type Invoke = <T>(cmd: string, args?: Record<string, unknown>) => Promise<T>;
export type Listen = (event: string, cb: (payload: unknown) => void) => Promise<() => void>;

interface Held {
  id: string;
  spec: JobSpec;
  timer: ReturnType<typeof setTimeout> | null;
  /** Resolves with the Rust id, or null when the job ended before it was submitted. */
  submitted: Promise<string | null>;
  resolve: (rust: string | null) => void;
}

/** A host reply framed as `host_request` frames it, or the host's error. */
export function unpackReply(method: string, buf: ArrayBuffer | Uint8Array): HostReply {
  const { header, payload } = decodeFrame(buf instanceof Uint8Array ? buf : new Uint8Array(buf));
  const h = header as { ok: boolean; result?: Record<string, unknown>; error?: { code: string; message: string } };
  if (!h.ok) throw new HostCallError(method, h.error?.code ?? 'internal', h.error?.message ?? 'unknown error');
  return { result: h.result ?? {}, payload };
}

/** `scheduler_outcome`'s frame: the `OutcomeWire` header and the payload. */
export function unpackOutcome(buf: ArrayBuffer | Uint8Array): Outcome {
  const { header, payload } = decodeFrame(buf instanceof Uint8Array ? buf : new Uint8Array(buf));
  return { outcome: header as unknown as OutcomeWire, payload };
}

export class TauriScheduler implements SchedulerClient {
  private held = new Map<string, Held>();
  private toPage = new Map<string, string>();
  private listeners = new Set<(s: JobSnapshotWire) => void>();
  private subscribed: Promise<unknown> | null = null;
  private dialogOpen = false;
  private next = 1;

  constructor(private readonly call: Invoke = invoke as Invoke, private readonly on: Listen = (e, cb) => listen(e, (x) => cb(x.payload)),
              private readonly settleMs = SETTLE_MS) {}

  private subscribe() {
    this.subscribed ??= this.on('scheduler://job', (p) => {
      const s = p as JobSnapshotWire;
      const id = this.toPage.get(s.jobId) ?? s.jobId;
      this.emit(id === s.jobId ? s : { ...s, jobId: id });
    });
    return this.subscribed;
  }

  private emit(s: JobSnapshotWire) { for (const l of this.listeners) { try { l(s); } catch (err) { console.error(err); } } }

  private heldSnapshot(h: Held, reason: WaitReason | 'cancelled'): JobSnapshotWire {
    const s = h.spec;
    const base = { jobId: h.id, frameId: s.frameId, kind: s.kind, tier: s.tier, canvas: s.canvas, what: s.what ?? '', verb: verbOf(s.kind), mode: null,
      ...(s.slot ? { slot: s.slot } : {}) };
    return reason === 'cancelled' ? { ...base, state: 'cancelled' } : { ...base, state: 'waiting', reason, text: waitText(reason) };
  }

  async submit(spec: JobSpec): Promise<string> {
    await this.subscribe();
    if (!isCanvas(spec.kind)) return this.call<string>('scheduler_submit', { job: spec });
    // A newer edit of the same frame replaces the one still settling.
    for (const h of [...this.held.values()]) {
      if (h.spec.frameId !== spec.frameId) continue;
      if (h.spec.kind === 'canvasDevelop') spec = { ...spec, kind: 'canvasDevelop' };
      this.drop(h);
    }
    const id = `page-${this.next++}`;
    let resolve!: (rust: string | null) => void;
    const submitted = new Promise<string | null>((r) => { resolve = r; });
    const h: Held = { id, spec, timer: null, submitted, resolve };
    this.held.set(id, h);
    this.emit(this.heldSnapshot(h, this.dialogOpen ? 'dialog' : 'settling'));
    this.arm(h);
    return id;
  }

  private arm(h: Held) {
    if (this.dialogOpen) return;
    h.timer = setTimeout(() => void this.release(h), this.settleMs);
  }

  private async release(h: Held) {
    if (this.held.get(h.id) !== h) return;
    this.held.delete(h.id);
    try {
      const rust = await this.call<string>('scheduler_submit', { job: h.spec });
      this.toPage.set(rust, h.id);
      h.resolve(rust);
    } catch (e) {
      this.failed.set(h.id, e instanceof Error ? e.message : String(e));
      h.resolve(null);
    }
  }

  private failed = new Map<string, string>();

  private drop(h: Held) {
    if (h.timer) clearTimeout(h.timer);
    this.held.delete(h.id);
    this.emit(this.heldSnapshot(h, 'cancelled'));
    h.resolve(null);
  }

  private async rustId(id: string): Promise<string | null> {
    const h = this.held.get(id);
    if (h) return h.submitted;
    for (const [rust, page] of this.toPage) if (page === id) return rust;
    return id.startsWith('page-') ? null : id;
  }

  async cancel(jobId: string): Promise<void> {
    const h = this.held.get(jobId);
    if (h) { this.drop(h); return; }
    const rust = await this.rustId(jobId);
    if (rust) await this.call('scheduler_cancel', { jobId: rust });
  }

  async cancelFrame(frameId: string, kinds?: JobKind[]): Promise<void> {
    for (const h of [...this.held.values()]) if (h.spec.frameId === frameId && (!kinds || kinds.includes(h.spec.kind))) this.drop(h);
    await this.call('scheduler_cancel_frame', { frameId, ...(kinds ? { kinds } : {}) });
  }

  async outcome(jobId: string): Promise<Outcome> {
    const rust = await this.rustId(jobId);
    if (!rust) {
      const message = this.failed.get(jobId);
      this.failed.delete(jobId);
      return { outcome: message ? { jobId, outcome: 'failed', message } : { jobId, outcome: 'cancelled' }, payload: EMPTY };
    }
    try {
      const out = unpackOutcome(await this.call<ArrayBuffer>('scheduler_outcome', { jobId: rust }));
      return { outcome: { ...out.outcome, jobId }, payload: out.payload };
    } catch (e) {
      return { outcome: { jobId, outcome: 'failed', message: e instanceof Error ? e.message : String(e) }, payload: EMPTY };
    }
  }

  async snapshot(frameId?: string): Promise<JobSnapshotWire[]> {
    const rows = await this.call<JobSnapshotWire[]>('scheduler_snapshot', frameId ? { frameId } : {});
    const mine = [...this.held.values()].filter((h) => !frameId || h.spec.frameId === frameId)
      .map((h) => this.heldSnapshot(h, this.dialogOpen ? 'dialog' : 'settling'));
    const theirs = rows.map((s) => ({ ...s, jobId: this.toPage.get(s.jobId) ?? s.jobId }));
    return frameId ? (theirs.length ? theirs : mine.slice(0, 1)) : [...theirs, ...mine];
  }

  budget(): Promise<BudgetReadingWire> { return this.call<BudgetReadingWire>('scheduler_budget'); }

  async frontendState(state: FrontendState): Promise<void> {
    const was = this.dialogOpen;
    this.dialogOpen = state.dialogOpen;
    if (was && !state.dialogOpen) for (const h of this.held.values()) { this.emit(this.heldSnapshot(h, 'settling')); this.arm(h); }
    if (!was && state.dialogOpen) for (const h of this.held.values()) { if (h.timer) clearTimeout(h.timer); h.timer = null; this.emit(this.heldSnapshot(h, 'dialog')); }
    await this.call('scheduler_frontend_state', { state: frontendMsg(state) });
  }

  memoryPressure(level: 'warning' | 'critical'): Promise<void> { return this.call('scheduler_memory_pressure', { level }); }

  onJob(listener: (s: JobSnapshotWire) => void): () => void {
    void this.subscribe();
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async editingOpen(frameId: string, source: SourceSpec): Promise<HostReply> {
    return unpackReply(source.pair ? 'open_pair' : 'open', await this.call<ArrayBuffer>('scheduler_editing_open', { frameId, source }));
  }

  async editingCall(frameId: string, session: string, method: string, params: Record<string, unknown>): Promise<HostReply> {
    return unpackReply(method, await this.call<ArrayBuffer>('scheduler_editing_call', { frameId, session, method, params }));
  }
}
