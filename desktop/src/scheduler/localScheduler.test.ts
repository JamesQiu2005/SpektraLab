// The in-page scheduler's rules on a virtual clock (no timing assertions on a
// real one): settle, fold, the order of who asked, waiting reasons, cancel, a
// failure that does not stop the queue — and that it speaks WIRE.md's shapes.

import { describe, expect, it } from 'vitest';
import { LocalScheduler, type Clock } from './localScheduler';
import type { Engine, EngineRun } from './mockEngine';
import type { JobSnapshotWire, JobSpec } from './types';

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

/** An engine whose jobs finish only when the test says so. */
function fakeEngine() {
  const calls: string[] = [];
  const cancels: string[] = [];
  const pending: { tag: string; resolve: (r: EngineRun) => void; reject: (e: Error) => void }[] = [];
  const engine: Engine = {
    run: (job) => new Promise((resolve, reject) => {
      const tag = String(job.request.params.tag ?? '');
      calls.push(`${job.request.method}:${tag}`);
      pending.push({ tag, resolve, reject });
    }),
    cancel: (id) => { cancels.push(id); },
    open: async () => ({ result: {}, payload: new Uint8Array(0) }),
    call: async () => ({ result: {}, payload: new Uint8Array(0) }),
    closeEditing: async () => {},
  };
  const done = (tag: string): EngineRun => ({ method: 'render_view', result: { tag, image: { width: 4, height: 2 } }, payload: new Uint8Array(32), reprint: false });
  return { calls, cancels, pending, engine,
    finishNext: async () => { const p = pending.shift()!; p.resolve(done(p.tag)); await flush(); },
    failNext: async (m: string) => { pending.shift()!.reject(new Error(m)); await flush(); },
    cancelNext: async () => { pending.shift()!.reject(Object.assign(new Error('cancelled: operation cancelled'), { code: 'cancelled' })); await flush(); } };
}
const job = (kind: JobSpec['kind'], tag: string, frameId = '/a.arw', extra: Partial<JobSpec> = {}): JobSpec =>
  ({ kind, frameId, what: tag, tier: kind === 'fullView' || kind === 'export' ? 'full' : 'live', canvas: { width: 4, height: 2 },
    request: { method: 'render_view', params: { tag } }, ...extra });

function setup() {
  const clock = new VirtualClock();
  const host = fakeEngine();
  const s = new LocalScheduler(host.engine, { clock });
  const seen: JobSnapshotWire[] = [];
  s.onJob((x) => seen.push(x));
  return { clock, host, s, seen };
}

describe('LocalScheduler', () => {
  it('an edit settles 180 ms before it renders, saying so', async () => {
    const { clock, host, s } = setup();
    const id = await s.submit(job('canvasDevelop', 'a'));
    await flush();
    expect(host.calls).toEqual([]);
    expect(s.peek(id)).toMatchObject({ state: 'waiting', reason: 'settling' });
    await clock.advance(179);
    expect(host.calls).toEqual([]);
    await clock.advance(1);
    expect(host.calls).toEqual(['render_view:a']);
    expect(s.peek(id)!.state).toBe('running');
    await host.finishNext();
    expect((await s.outcome(id)).outcome.outcome).toBe('finished');
  });

  it('newer edits fold into the newest job while it waits', async () => {
    const { clock, host, s } = setup();
    const a = await s.submit(job('canvasReprint', 'a'));
    await clock.advance(100);
    const b = await s.submit(job('canvasDevelop', 'b'));
    await clock.advance(100);
    const c = await s.submit(job('canvasReprint', 'c'));
    expect((await s.outcome(a)).outcome.outcome).toBe('cancelled');
    expect((await s.outcome(b)).outcome.outcome).toBe('cancelled');
    await clock.advance(180);
    expect(host.calls).toEqual(['render_view:c']);
    // A develop folded into a reprint still develops.
    expect(s.peek(c)!.kind).toBe('canvasDevelop');
    await host.finishNext();
    expect((await s.outcome(c)).outcome.outcome).toBe('finished');
  });

  it('a running render finishes; the newest renders next', async () => {
    const { clock, host, s } = setup();
    const a = await s.submit(job('canvasDevelop', 'a'));
    await clock.advance(180);
    const b = await s.submit(job('canvasDevelop', 'b'));
    await host.finishNext();
    expect((await s.outcome(a)).outcome.outcome).toBe('finished');
    await clock.advance(180);
    expect(host.calls).toEqual(['render_view:a', 'render_view:b']);
    await host.finishNext();
    expect((await s.outcome(b)).outcome.outcome).toBe('finished');
  });

  it('runs one render at a time, the canvas before an export before a stock preview', async () => {
    const { clock, host, s } = setup();
    await s.submit(job('fullView', 'f', '/b.arw'));
    await flush();
    expect(host.calls).toEqual(['render_view:f']);
    const e = await s.submit(job('export', 'e'));
    await s.submit(job('stockPreview', 'p', '/c.arw', { slot: 'film:gold' }));
    const c = await s.submit(job('canvasDevelop', 'c'));
    expect(s.peek(e)).toMatchObject({ state: 'waiting', reason: 'queued' });
    await host.finishNext(); // f
    // The canvas job is still settling: nothing less urgent starts in front of it.
    expect(host.calls).toEqual(['render_view:f']);
    await clock.advance(180);
    expect(host.calls).toEqual(['render_view:f', 'render_view:c']);
    await host.finishNext();
    await host.finishNext();
    await host.finishNext();
    expect(host.calls).toEqual(['render_view:f', 'render_view:c', 'render_view:e', 'render_view:p']);
    expect((await s.outcome(c)).outcome.outcome).toBe('finished');
  });

  it('thumbnails run beside the renders, two at a time, and never hold an edit back', async () => {
    const { clock, host, s } = setup();
    const t1 = await s.submit(job('thumbnail', 't1', '/b.arw'));
    await s.submit(job('thumbnail', 't2', '/c.arw'));
    const t3 = await s.submit(job('thumbnail', 't3', '/d.arw'));
    await flush();
    expect(host.calls).toEqual(['render_view:t1', 'render_view:t2']);
    expect(s.peek(t3)).toMatchObject({ state: 'waiting', reason: 'queued' });
    const c = await s.submit(job('canvasDevelop', 'c'));
    await clock.advance(180);
    // The edit renders although two thumbnails are still decoding.
    expect(host.calls).toEqual(['render_view:t1', 'render_view:t2', 'render_view:c']);
    expect(s.peek(c)!.state).toBe('running');
    await host.finishNext(); // t1
    expect(host.calls.at(-1)).toBe('render_view:t3');
    expect((await s.outcome(t1)).outcome.outcome).toBe('finished');
    expect((await s.budget()).jobs).toBe(3);
  });

  it('a failed job reports its reason and the queue goes on', async () => {
    const { host, s } = setup();
    s.setSettle({ canvasDevelop: 0 });
    const a = await s.submit(job('canvasDevelop', 'a'));
    const t = await s.submit(job('thumbnail', 't', '/b.arw'));
    await flush();
    await host.failNext('engine_error: The graphics device stopped responding.');
    expect((await s.outcome(a)).outcome).toEqual({ jobId: a, outcome: 'failed', message: 'engine_error: The graphics device stopped responding.' });
    expect(s.peek(a)).toMatchObject({ state: 'failed', message: 'engine_error: The graphics device stopped responding.' });
    await host.finishNext();
    expect((await s.outcome(t)).outcome.outcome).toBe('finished');
  });

  it('cancel takes a waiting job out; a running one is cancelled on the engine', async () => {
    const { host, s } = setup();
    const a = await s.submit(job('export', 'a'));
    const b = await s.submit(job('export', 'b', '/b.arw'));
    await flush();
    await s.cancel(b);
    expect((await s.outcome(b)).outcome.outcome).toBe('cancelled');
    await s.cancel(a);
    expect(host.cancels).toEqual([a]);
    await host.cancelNext();
    expect((await s.outcome(a)).outcome.outcome).toBe('cancelled');
    expect(host.calls).toEqual(['render_view:a']);
  });

  it('pixels are handed over once', async () => {
    const { host, s } = setup();
    const a = await s.submit(job('export', 'a'));
    await flush();
    await host.finishNext();
    const first = await s.outcome(a);
    expect(first.payload.byteLength).toBe(32);
    expect(first.outcome.result).toMatchObject({ payloadBytes: 32, size: { width: 4, height: 2 }, method: 'render_view', hostResult: { tag: 'a' } });
    const again = await s.outcome(a);
    expect(again.payload.byteLength).toBe(0);
    expect(again.outcome.result!.payloadBytes).toBe(0);
  });

  it('cancelFrame cancels one frame’s jobs of the kinds named', async () => {
    const { s } = setup();
    const c = await s.submit(job('canvasDevelop', 'c'));
    const f = await s.submit(job('fullView', 'f'));
    const o = await s.submit(job('fullView', 'o', '/other.arw'));
    await s.cancelFrame('/a.arw', ['canvasDevelop']);
    expect((await s.outcome(c)).outcome.outcome).toBe('cancelled');
    expect(s.peek(f)!.state).not.toBe('cancelled');
    expect(s.peek(o)!.state).not.toBe('cancelled');
  });

  it('a file dialog holds canvas jobs with the reason, and they run when it closes', async () => {
    const { clock, host, s } = setup();
    await s.frontendState({ visiblePage: 'edit', openFrame: '/a.arw', foreground: true, interaction: 'idle', dialogOpen: true });
    const a = await s.submit(job('canvasDevelop', 'a'));
    await clock.advance(500);
    expect(s.peek(a)).toMatchObject({ state: 'waiting', reason: 'dialog' });
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
    expect(s.peek(a)!.state).toBe('running');
    expect(s.peek(b)!.state).not.toBe('cancelled');
    expect(s.peek(c)!.state).not.toBe('cancelled');
  });

  it('refuses what the Rust scheduler refuses', async () => {
    const { s } = setup();
    await expect(s.submit({ ...job('export', 'e'), frameId: '' })).rejects.toThrow('frameId is empty');
    await expect(s.submit({ ...job('export', 'e'), canvas: { width: 0, height: 2 } })).rejects.toThrow('not a picture');
  });

  it('a budget reading in WIRE’s shape, with what it holds', async () => {
    const clock = new VirtualClock();
    const s = new LocalScheduler(fakeEngine().engine, { clock, engineName: 'mock host' });
    await s.submit(job('export', 'e'));
    await s.submit(job('export', 'f', '/b.arw'));
    const b = await s.budget();
    expect(b.jobs).toBe(2);
    expect(b.engine.name).toBe('mock host');
  });
});
