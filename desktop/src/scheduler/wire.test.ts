// The in-page mock and the app's binding to the Rust scheduler agree on the
// wire: both are held to WIRE.md's own `wire-example` blocks (the same blocks
// the crate's `tests/wire.rs` holds the Rust code to). The mock must *produce*
// the shapes the examples have (same keys, same kinds of value); the Tauri
// binding must *read* the examples as the page's types and hand back what it
// was given.

import { describe, expect, it } from 'vitest';
import wireMd from '../../crates/spk-scheduler/WIRE.md?raw';
import { encodeFrame } from '@shared/framing';
import { LocalScheduler } from './localScheduler';
import type { Engine } from './mockEngine';
import { TauriScheduler, unpackOutcome, type Invoke } from './tauriScheduler';
import { frontendMsg, type BudgetReadingWire, type JobSnapshotWire, type JobSpec, type OutcomeWire } from './types';

/** Every ```json wire-example <Type> block of WIRE.md, parsed. */
function examples(type: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  const re = /```json wire-example (\w+)\r?\n([\s\S]*?)```/g;
  for (let m = re.exec(wireMd); m; m = re.exec(wireMd)) if (m[1] === type) out.push(JSON.parse(m[2]!) as Record<string, unknown>);
  return out;
}

/** A value's shape: an object's keys and their shapes, a list's first element's, a scalar's kind. */
function shape(v: unknown): unknown {
  if (v === null) return 'null';
  if (Array.isArray(v)) return v.length ? [shape(v[0])] : [];
  if (typeof v === 'object') return Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([k, x]) => [k, shape(x)]));
  return typeof v;
}

const flush = async () => { for (let i = 0; i < 20; i++) await Promise.resolve(); };

/** An engine that finishes a job when told, with the host reply the example's outcome carries. */
function engine(result: Record<string, unknown>, payload: Uint8Array) {
  let finish: (() => void) | null = null;
  let progress: ((s: 'Film', f: number) => void) | null = null;
  const e: Engine = {
    run: (_job, _id, p) => new Promise((resolve) => {
      progress = p as typeof progress;
      finish = () => resolve({ method: 'render_view', result, payload, reprint: false });
    }),
    cancel: () => {}, open: async () => ({ result: {}, payload }), call: async () => ({ result: {}, payload }), closeEditing: async () => {},
  };
  return { e, finish: () => finish!(), progress: (f: number) => progress!('Film', f) };
}

describe('WIRE.md, both ways', () => {
  it('has the examples this test reads', () => {
    expect(examples('JobSpec')).toHaveLength(1);
    expect(examples('JobSnapshotWire')).toHaveLength(2);
    expect(examples('OutcomeWire')).toHaveLength(2);
    expect(examples('BudgetReadingWire')).toHaveLength(1);
    expect(examples('FrontendStateMsg')).toHaveLength(1);
  });

  it('the mock takes WIRE’s JobSpec and reports the job in the shapes of WIRE’s snapshots and outcome', async () => {
    const [spec] = examples('JobSpec') as unknown as JobSpec[];
    const [, runningEx] = examples('JobSnapshotWire');
    const [finishedEx, failedEx] = examples('OutcomeWire');
    const host = (finishedEx!.result as { hostResult: Record<string, unknown>; payloadBytes: number });
    const payload = new Uint8Array(host.payloadBytes);
    const { e, finish, progress } = engine(host.hostResult, payload);
    const s = new LocalScheduler(e, { settleMs: { canvasReprint: 0, canvasDevelop: 0 } });
    const seen: JobSnapshotWire[] = [];
    s.onJob((x) => seen.push(x));
    const id = await s.submit({ ...spec!, kind: 'canvasDevelop' });
    expect(id).toMatch(/^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/);
    await flush();
    progress(0.35);
    const running = seen.filter((x) => x.state === 'running').at(-1)!;
    expect(shape(running)).toEqual(shape(runningEx));
    finish();
    const out = await s.outcome(id);
    expect(shape(out.outcome)).toEqual(shape(finishedEx));
    expect(out.payload.byteLength).toBe(host.payloadBytes);
    expect(out.outcome.result!.hostResult).toEqual(host.hostResult);
    // A failure: the outcome's and the snapshot's shapes.
    const f = new LocalScheduler({ ...e, run: async () => { throw new Error((failedEx as unknown as OutcomeWire).message); } });
    const fid = await f.submit({ ...spec!, kind: 'export', tier: 'full' });
    const failed = await f.outcome(fid);
    expect(shape(failed.outcome)).toEqual(shape(failedEx));
    expect(failed.outcome.message).toBe((failedEx as unknown as OutcomeWire).message);
  });

  it('the mock says why a job waits in WIRE’s waiting shape', async () => {
    const [waitingEx] = examples('JobSnapshotWire');
    const { e } = engine({}, new Uint8Array(0));
    const s = new LocalScheduler(e);
    await s.submit({ ...(examples('JobSpec')[0] as unknown as JobSpec), kind: 'fullView', tier: 'full' }); // runs
    const id = await s.submit({ ...(examples('JobSpec')[0] as unknown as JobSpec), frameId: 'other', kind: 'export', tier: 'full', what: 'Export JPEG' });
    const waiting = s.peek(id)!;
    expect(waiting).toMatchObject({ state: 'waiting', reason: 'queued', text: 'Waiting its turn' });
    // WIRE's example waits for memory, a reason only the Rust budget gives, so it is planned
    // (`mode: "wait(memory)"`); one waiting its turn is not planned yet (`mode: null`). Otherwise the same shape.
    expect(waiting.mode).toBeNull();
    expect(shape({ ...waiting, mode: 'planned' })).toEqual(shape(waitingEx));
  });

  it('the mock’s budget reading has WIRE’s shape, and the page’s frontend state is WIRE’s message', async () => {
    const [budgetEx] = examples('BudgetReadingWire');
    const budget = await new LocalScheduler(engine({}, new Uint8Array(0)).e).budget();
    expect(shape(budget)).toEqual(shape(budgetEx));
    const [front] = examples('FrontendStateMsg');
    const msg = frontendMsg({ visiblePage: 'edit', openFrame: 'lib:7F1C', foreground: true, interaction: 'dragging', dialogOpen: false });
    for (const [k, v] of Object.entries(msg)) expect(shape(v)).toEqual(shape((front as Record<string, unknown>)[k]));
    expect(msg).toMatchObject({ visiblePage: 'develop', openFrame: 'lib:7F1C', foreground: true, scene: 'active', interaction: { dragging: 'print' } });
  });

  it('the Tauri binding sends WIRE’s JobSpec and reads WIRE’s snapshots, outcome and budget as they are', async () => {
    const [spec] = examples('JobSpec') as unknown as JobSpec[];
    const snapshots = examples('JobSnapshotWire') as unknown as JobSnapshotWire[];
    const [finishedEx] = examples('OutcomeWire') as unknown as OutcomeWire[];
    const [budgetEx] = examples('BudgetReadingWire') as unknown as BudgetReadingWire[];
    const payload = new Uint8Array(finishedEx!.result!.payloadBytes).fill(7);
    const sent: [string, Record<string, unknown> | undefined][] = [];
    let listener: ((p: unknown) => void) | null = null;
    const call: Invoke = async <T,>(cmd: string, args?: Record<string, unknown>) => {
      sent.push([cmd, args]);
      switch (cmd) {
        case 'scheduler_submit': return finishedEx!.jobId as T;
        case 'scheduler_outcome': return encodeFrame(finishedEx as unknown as Record<string, unknown>, payload).buffer as T;
        case 'scheduler_snapshot': return snapshots as T;
        case 'scheduler_budget': return budgetEx as T;
        default: return null as T;
      }
    };
    const t = new TauriScheduler(call, async (_e, cb) => { listener = cb; return () => {}; }, 0);
    const events: JobSnapshotWire[] = [];
    t.onJob((x) => events.push(x));
    // A non-canvas job goes straight to Rust, exactly as WIRE's JobSpec.
    const id = await t.submit({ ...spec!, kind: 'export', tier: 'full' });
    expect(sent.find(([c]) => c === 'scheduler_submit')![1]).toEqual({ job: { ...spec!, kind: 'export', tier: 'full' } });
    expect(id).toBe(finishedEx!.jobId);
    const out = await t.outcome(id);
    expect(out.outcome).toEqual(finishedEx);
    expect(out.payload.byteLength).toBe(payload.byteLength);
    expect(out.payload.every((b) => b === 7)).toBe(true);
    expect(unpackOutcome(encodeFrame(finishedEx as unknown as Record<string, unknown>, payload)).outcome).toEqual(finishedEx);
    expect(await t.snapshot()).toEqual(snapshots);
    expect(await t.budget()).toEqual(budgetEx);
    await flush();
    listener!(snapshots[1]);
    expect(events).toEqual([snapshots[1]]);
    // A canvas job settles in the page first (WIRE has no settle), then is the same JobSpec.
    const page = await t.submit(spec!);
    expect(page).toMatch(/^page-/);
    await new Promise((r) => setTimeout(r, 5));
    expect(sent.filter(([c]) => c === 'scheduler_submit').at(-1)![1]).toEqual({ job: spec });
    listener!({ ...snapshots[1], jobId: finishedEx!.jobId });
    expect(events.at(-1)!.jobId).toBe(page);
  });
});
