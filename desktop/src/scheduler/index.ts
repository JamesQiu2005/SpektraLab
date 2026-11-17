// index.ts — the webview's one scheduler.
//
// Under Tauri it is the Rust scheduler (`TauriScheduler` over the commands of
// `desktop/crates/spk-scheduler/WIRE.md`): the webview queues nothing and owns
// no session. In the browser (Playwright, `vite` alone) and in unit tests it is
// the in-page mock (`LocalScheduler` on a `MockEngine` over the page's host
// client), which speaks the same wire.

import { host } from '../host/client';
import { inTauri } from '../host/transport';
import { LocalScheduler } from './localScheduler';
import { MockEngine } from './mockEngine';
import { TauriScheduler } from './tauriScheduler';
import { typedCaller } from './typedCaller';
import type { JobKind, JobSpec, JobSnapshotWire, Outcome, OutcomeWire, SchedulerClient } from './types';

const settleFor = (): Partial<Record<JobKind, number>> =>
  // Unit tests drive the session's own logic; the settle itself is held by
  // localScheduler.test.ts on a virtual clock (no timing in either).
  (import.meta as unknown as { env?: { MODE?: string } }).env?.MODE === 'test' ? { canvasDevelop: 0, canvasReprint: 0 } : {};

let client: SchedulerClient | null = null;

/** The in-page scheduler the browser mock and the tests run on. */
export function mockScheduler(): LocalScheduler {
  const h = host() as unknown as { onEvent?: (cb: (e: Record<string, unknown>) => void) => () => void };
  return new LocalScheduler(new MockEngine(typedCaller, h.onEvent ? (cb) => h.onEvent!(cb) : undefined), { settleMs: settleFor() });
}

/** The scheduler the pages submit to. */
export function scheduler(): SchedulerClient {
  client ??= inTauri() ? new TauriScheduler() : mockScheduler();
  return client;
}

/** For tests and the mock harness: replace the scheduler. */
export function setScheduler(next: SchedulerClient | null) { client = next; }

export function localScheduler(): LocalScheduler | null { const s = scheduler(); return s instanceof LocalScheduler ? s : null; }

/** A job that did not finish: its outcome, and the host's error code where the message carries one (`code: message`). */
export class JobEnded extends Error {
  constructor(readonly outcome: OutcomeWire) {
    super(outcome.message ? outcome.message.replace(/^[a-z_]+: /, '') : `job ${outcome.outcome}`);
  }
  get code() {
    if (this.outcome.outcome === 'cancelled') return 'cancelled';
    return /^([a-z_]+): /.exec(this.outcome.message ?? '')?.[1] ?? 'internal';
  }
  get cancelled() { return this.outcome.outcome === 'cancelled'; }
}

/** What a finished job made: the host reply's `result` and the payload (WIRE.md, `hostResult`). */
export interface JobResult { result: Record<string, unknown>; payload: Uint8Array; outcome: OutcomeWire }

/** Submit a job and wait for it; its result, or throws `JobEnded`. */
export async function runJob(job: JobSpec, onSubmitted?: (id: string) => void): Promise<JobResult> {
  const s = scheduler();
  const id = await s.submit(job);
  onSubmitted?.(id);
  return finished(await s.outcome(id));
}

export function finished(out: Outcome): JobResult {
  if (out.outcome.outcome !== 'finished') throw new JobEnded(out.outcome);
  return { result: out.outcome.result?.hostResult ?? {}, payload: out.payload, outcome: out.outcome };
}

/** The canvas a job renders at: `long_edge` along the frame's shape (or the frame itself). */
export function canvasOf(size: { width: number; height: number } | null | undefined, longEdge: number): { width: number; height: number } {
  const w = Math.max(1, size?.width ?? longEdge), h = Math.max(1, size?.height ?? longEdge);
  if (!longEdge || Math.max(w, h) <= longEdge) return { width: w, height: h };
  const k = longEdge / Math.max(w, h);
  return { width: Math.max(1, Math.round(w * k)), height: Math.max(1, Math.round(h * k)) };
}

export type { JobSnapshotWire, JobSpec, Outcome, OutcomeWire };
