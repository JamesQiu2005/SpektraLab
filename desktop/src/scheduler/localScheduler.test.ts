// The scheduler's rules on a virtual clock (no timing assertions on a real
// one): settle, fold, the order of who asked, waiting reasons, cancel, and a
// failure that does not stop the queue.

import { describe, expect, it } from 'vitest';
import { LocalScheduler, type Clock, type StepExecutor } from './localScheduler';
import type { HostStep, JobRequest, JobSnapshot } from './types';

class VirtualClock implements Clock {
  t = 0;
  private timers: { at: number; fn: () => void; id: number }[] = [];
  private seq = 0;
  now = () => this.t;
  setTimeout = (fn: () => void, ms: number) => { const id = ++this.seq; this.timers.push({ at: this.t + ms, fn, id }); return id; };
  clearTimeout = (h: unknown) => { this.timers = this.timers.filter((x) => x.id !== h); };
  async advance(ms: number) {
    const end = this.t + ms;
    for (;;) {
      this.timers.sort((a, b) => a.at - b.at);
      const next = this.timers[0];
      if (!next || next.at > end) break;
      this.timers.shift();
      this.t = next.at;
      next.fn();
      await flush();
    }
    this.t = end;
    await flush();
  }
}
const flush = async () => { for (let i = 0; i < 10; i++) await Promise.resolve(); };

/** A host whose steps finish only when the test says so. */
function fakeHost() {
  const calls: string[] = [];
  const pending: { step: HostStep; resolve: () => void; reject: (e: Error) => void }[] = [];
  const exec: StepExecutor = (step) => new Promise((resolve, reject) => {
    calls.push(`${step.method}:${String(step.params.tag ?? '')}`);
    pending.push({ step, resolve: () => resolve({ result: { tag: step.params.tag } }), reject });
  });
  return { calls, pending, exec, finishNext: async () => { pending.shift()!.resolve(); await flush(); }, failNext: async (m: string) => { pending.shift()!.reject(Object.assign(new Error(m), { code: 'internal' })); await flush(); } };
}
const job = (kind: JobRequest['kind'], tag: string, frameId = '/a.arw', extra: Partial<JobRequest> = {}): JobRequest =>
  ({ kind, frameId, what: tag, tier: kind === 'fullView' || kind === 'export' ? 'full' : 'live', steps: [{ method: 'render_view', params: { tag } }], ...extra });

function setup() {
  const clock = new VirtualClock();
  const host = fakeHost();
  const s = new LocalScheduler(host.exec, { clock });
  const seen: JobSnapshot[] = [];
  s.onJob((x) => seen.push(x));
  return { clock, host, s, seen };
}

describe('LocalScheduler', () => {
  it('an edit settles 180 ms before it renders, saying so', async () => {
    const { clock, host, s } = setup();
    const id = await s.submit(job('canvasDevelop', 'a'));
    await flush();
    expect(host.calls).toEqual([]);
    expect(s.peek(id)!.state).toEqual({ state: 'waiting', reason: 'settling' });
    await clock.advance(179);
    expect(host.calls).toEqual([]);
    await clock.advance(1);
    expect(host.calls).toEqual(['render_view:a']);
    expect(s.peek(id)!.state.state).toBe('running');
    await host.finishNext();
    expect((await s.outcome(id)).status).toBe('done');
  });

  it('newer edits fold into the newest job while it waits', async () => {
    const { clock, host, s } = setup();
    const a = await s.submit(job('canvasReprint', 'a'));
    await clock.advance(100);
    const b = await s.submit(job('canvasDevelop', 'b'));
    await clock.advance(100);
    const c = await s.submit(job('canvasReprint', 'c'));
    expect(await s.outcome(a)).toMatchObject({ status: 'cancelled', superseded: true, supersededBy: b });
    expect(await s.outcome(b)).toMatchObject({ status: 'cancelled', supersededBy: c });
    await clock.advance(180);
    expect(host.calls).toEqual(['render_view:c']);
    // A develop folded into a reprint still develops.
    expect(s.peek(c)!.job.kind).toBe('canvasDevelop');
    await host.finishNext();
    expect((await s.outcome(c)).status).toBe('done');
  });

  it('a running render finishes but is marked superseded; the newest renders next', async () => {
    const { clock, host, s } = setup();
    const a = await s.submit(job('canvasDevelop', 'a'));
    await clock.advance(180);
    const b = await s.submit(job('canvasDevelop', 'b'));
    await host.finishNext();
    const oa = await s.outcome(a);
    expect(oa).toMatchObject({ status: 'done', superseded: true, supersededBy: b });
    await clock.advance(180);
    expect(host.calls).toEqual(['render_view:a', 'render_view:b']);
    await host.finishNext();
    expect((await s.outcome(b)).superseded).toBe(false);
  });

  it('runs one job at a time, the canvas before an export before a thumbnail', async () => {
    const { clock, host, s } = setup();
    await s.submit(job('thumbnail', 't', '/b.arw'));
    await flush();
    expect(host.calls).toEqual(['render_view:t']);
    const e = await s.submit(job('export', 'e'));
    await s.submit(job('thumbnail', 't2', '/c.arw'));
    const c = await s.submit(job('canvasDevelop', 'c'));
    expect(s.peek(e)!.state).toEqual({ state: 'waiting', reason: 'queued' });
    await host.finishNext(); // t
    // The canvas job is still settling: nothing less urgent starts in front of it.
    expect(host.calls).toEqual(['render_view:t']);
    await clock.advance(180);
    expect(host.calls).toEqual(['render_view:t', 'render_view:c']);
    await host.finishNext();
    await host.finishNext();
    await host.finishNext();
    expect(host.calls).toEqual(['render_view:t', 'render_view:c', 'render_view:e', 'render_view:t2']);
    expect((await s.outcome(c)).status).toBe('done');
  });

  it('a failed job reports its reason and the queue goes on', async () => {
    const { host, s } = setup();
    s.setSettle({ canvasDevelop: 0 });
    const a = await s.submit(job('canvasDevelop', 'a'));
    const t = await s.submit(job('thumbnail', 't', '/b.arw'));
    await flush();
    await host.failNext('The graphics device stopped responding.');
    expect(await s.outcome(a)).toMatchObject({ status: 'failed', error: { message: 'The graphics device stopped responding.', code: 'internal' } });
    expect(s.peek(a)!.state).toMatchObject({ state: 'failed', message: 'The graphics device stopped responding.' });
    await host.finishNext();
    expect((await s.outcome(t)).status).toBe('done');
  });

  it('cancel takes a waiting job out; a running one ends cancelled after its step', async () => {
    const { clock, host, s } = setup();
    const a = await s.submit({ ...job('export', 'a'), steps: [{ method: 'render', params: { tag: '1' } }, { method: 'write', params: { tag: '2' } }] });
    const b = await s.submit(job('export', 'b', '/b.arw'));
    await flush();
    await s.cancel(b);
    expect((await s.outcome(b)).status).toBe('cancelled');
    await s.cancel(a);
    await host.finishNext();
    expect(await s.outcome(a)).toMatchObject({ status: 'cancelled', results: [{ result: { tag: '1' } }] });
    expect(host.calls).toEqual(['render:1']);
    await clock.advance(1000);
    expect(host.calls).toEqual(['render:1']);
  });

  it('cancelFrame cancels one frame’s jobs of the kinds named', async () => {
    const { s } = setup();
    const c = await s.submit(job('canvasDevelop', 'c'));
    const f = await s.submit(job('fullView', 'f'));
    const o = await s.submit(job('fullView', 'o', '/other.arw'));
    await s.cancelFrame('/a.arw', ['canvasDevelop']);
    expect((await s.outcome(c)).status).toBe('cancelled');
    expect(s.peek(f)!.state.state).not.toBe('cancelled');
    expect(s.peek(o)!.state.state).not.toBe('cancelled');
  });

  it('a file dialog holds canvas jobs with the reason, and they run when it closes', async () => {
    const { clock, host, s } = setup();
    await s.frontendState({ visiblePage: 'edit', openFrame: '/a.arw', foreground: true, interaction: 'idle', dialogOpen: true });
    const a = await s.submit(job('canvasDevelop', 'a'));
    await clock.advance(500);
    expect(s.peek(a)!.state).toEqual({ state: 'waiting', reason: 'dialog' });
    expect(host.calls).toEqual([]);
    await s.frontendState({ visiblePage: 'edit', openFrame: '/a.arw', foreground: true, interaction: 'idle', dialogOpen: false });
    await flush();
    expect(host.calls).toEqual(['render_view:a']);
  });

  it('stock previews fold by slot', async () => {
    const { s } = setup();
    const a = await s.submit(job('stockPreview', 'a', '/a.arw', { slot: 'film:portra' }));
    const b = await s.submit(job('stockPreview', 'b', '/a.arw', { slot: 'film:gold' }));
    const c = await s.submit(job('stockPreview', 'c', '/a.arw', { slot: 'film:portra' }));
    // a started at once (nothing else queued), so it is superseded rather than cancelled.
    expect((await s.peek(a))!.superseded).toBe(true);
    expect(s.peek(b)!.state.state).not.toBe('cancelled');
    expect(s.peek(c)!.state.state).not.toBe('cancelled');
  });

  it('reports a budget reading with what it holds', async () => {
    const clock = new VirtualClock();
    const s = new LocalScheduler(fakeHost().exec, { clock, budget: () => ({ device: 'GPU', backend: 'Vulkan', budgetBytes: null, inUseBytes: null }) });
    await s.submit(job('export', 'e'));
    await s.submit(job('export', 'f', '/b.arw'));
    expect(await s.budget()).toEqual({ device: 'GPU', backend: 'Vulkan', budgetBytes: null, inUseBytes: null, running: 1, queued: 1 });
  });
});
