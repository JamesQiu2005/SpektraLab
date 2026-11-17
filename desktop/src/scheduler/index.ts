// index.ts — the webview's one scheduler, and the host steps its jobs are
// made of.
//
// Phase 1: a `LocalScheduler` in the page whose executor maps each step onto
// the v1 host client (`host().renderView`, `host().setParams`, …), so the app
// runs unchanged under `tauri dev` against the v1 host and in the browser
// against the in-page mock. Phase 2 binds `scheduler()` to the Tauri commands
// of `desktop/crates/spk-scheduler/WIRE.md` and the executor goes away; the
// steps below are already the protocol's own method names and params.

import { host } from '../host/client';
import { LocalScheduler, type StepExecutor } from './localScheduler';
import type { HostStep, JobKind, JobOutcome, JobRequest, JobSnapshot, SchedulerClient } from './types';
import type { WireParams, Tier } from '@shared/protocol';

type RenderViewOptions = Parameters<ReturnType<typeof host>['renderView']>[2];
type ExportParams = Record<string, unknown>;

/** The host requests a job is made of (HOST-PROTOCOL §3 method names). */
export const steps = {
  setParams: (session: string, delta: WireParams): HostStep => ({ method: 'set_params', params: { session, delta } }),
  render: (session: string, tier: Tier, reprint: boolean): HostStep => ({ method: 'render', params: { session, tier, reprint } }),
  renderView: (session: string, tier: Tier, options: RenderViewOptions): HostStep => ({ method: 'render_view', params: { session, tier, ...options } }),
  thumbnail: (path: string, longEdge: number, embeddedOnly: boolean): HostStep => ({ method: 'thumbnail', params: { path, long_edge: longEdge, embedded_only: embeddedOnly } }),
  exportFrame: (method: 'export_frame' | 'export_cineon', params: ExportParams): HostStep => ({ method, params }),
};

/** Phase 1's executor: each step through the typed v1 client (whose replies are already decoded). */
export const hostExecutor: StepExecutor = async (step) => {
  const p = step.params as Record<string, unknown> & { session: string; tier: Tier };
  switch (step.method) {
    case 'set_params':
      return { result: await host().setParams(p.session, p.delta as WireParams) };
    case 'render':
      return { result: await host().render(p.session, p.tier, { reprint: !!p.reprint }) };
    case 'render_view': {
      const { session, tier, ...options } = p;
      return { result: await host().renderView(session, tier, options as unknown as RenderViewOptions) };
    }
    case 'thumbnail':
      return { result: await host().thumbnail(String(p.path), Number(p.long_edge), !!p.embedded_only) };
    default: {
      const r = await host().transport.request(step.method, step.params, { timeoutMs: 1_800_000 });
      return { result: r.result, payload: r.payload };
    }
  }
};

const settleFor = (): Partial<Record<JobKind, number>> =>
  // Unit tests drive the session's own logic; the settle itself is held by
  // localScheduler.test.ts on a virtual clock (no timing in either).
  (import.meta as unknown as { env?: { MODE?: string } }).env?.MODE === 'test' ? { canvasDevelop: 0, canvasReprint: 0 } : {};

let instance: LocalScheduler | null = null;
let client: SchedulerClient | null = null;

/** The scheduler the pages submit to. */
export function scheduler(): SchedulerClient {
  if (!client) {
    instance = new LocalScheduler(hostExecutor, { settleMs: settleFor() });
    client = instance;
  }
  return client;
}

/** For tests and the mock harness: replace the scheduler (e.g. a LocalScheduler on a virtual clock). */
export function setScheduler(next: SchedulerClient | null) {
  client = next;
  instance = next instanceof LocalScheduler ? next : null;
}

export function localScheduler(): LocalScheduler | null { scheduler(); return instance; }

export class JobEnded extends Error {
  constructor(readonly outcome: JobOutcome) {
    super(outcome.error?.message ?? (outcome.superseded ? 'Superseded display request' : `job ${outcome.status}`));
  }
  get code() { return this.outcome.error?.code ?? (this.outcome.status === 'cancelled' ? 'cancelled' : 'internal'); }
}

/** Submit a job and wait for it; the last step's result, or throws `JobEnded`. */
export async function runJob<T>(job: JobRequest, onSubmitted?: (id: string) => void): Promise<T> {
  const s = scheduler();
  const id = await s.submit(job);
  onSubmitted?.(id);
  const out = await s.outcome(id);
  if (out.status !== 'done') throw new JobEnded(out);
  return out.results[out.results.length - 1]?.result as T;
}

/** As `runJob`, but the last step's whole reply (result and payload). */
export async function runJobRaw(job: JobRequest): Promise<{ result: Record<string, unknown>; payload: Uint8Array }> {
  const s = scheduler();
  const out = await s.outcome(await s.submit(job));
  if (out.status !== 'done') throw new JobEnded(out);
  const last = out.results[out.results.length - 1];
  return { result: (last?.result ?? {}) as Record<string, unknown>, payload: last?.payload ?? new Uint8Array(0) };
}

export type { JobSnapshot, JobRequest, JobOutcome };
