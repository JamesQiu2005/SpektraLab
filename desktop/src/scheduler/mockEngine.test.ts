// mockEngine.test.ts — the in-page engine places a full view as the Rust `HostEngine` does
// (`crates/spk-scheduler/tests/host_engine.rs`, "the requests each job kind makes"): a full view of
// the frame being edited, from its source, borrows the editing session; any other is one-shot.

import { describe, expect, it } from 'vitest';
import { MockEngine, type HostCaller } from './mockEngine';
import type { JobSpec, SourceSpec } from './types';

function scripted() {
  const calls: [string, Record<string, unknown>][] = [];
  let n = 0;
  const caller: HostCaller = async (method, params) => {
    calls.push([method, params]);
    if (method === 'open') return { result: { session: `s${++n}`, width: 6, height: 4 }, payload: new Uint8Array() };
    return { result: { image: { width: 6, height: 4 } }, payload: new Uint8Array(96) };
  };
  return { calls, methods: () => calls.map(([m]) => m), clear: () => { calls.length = 0; }, engine: new MockEngine(caller) };
}

const view = { tier: 'live', display: 'srgb', format: 'rgba8', generation: 1, adjustments: {}, geometry: {} };
const job = (kind: JobSpec['kind'], frameId: string, source: SourceSpec, extra: Partial<JobSpec> = {}): JobSpec => ({
  kind, frameId, tier: kind === 'fullView' ? 'full' : 'live', canvas: { width: 6, height: 4 },
  request: { source, method: 'render_view', params: { ...view, tier: kind === 'fullView' ? 'full' : 'live' } }, ...extra });

describe('MockEngine — the full view and the editing session', () => {
  it('borrows the editing session for its own frame and source, and is one-shot otherwise', async () => {
    const { engine, methods, calls, clear } = scripted();
    const a = { path: '/a.ARW', decode: { raw_mode: 'headroom' } };
    const run = (j: JobSpec) => engine.run(j, `job-${Math.random()}`, () => {});
    await run(job('canvasDevelop', '/a.ARW', a));
    expect(methods()).toEqual(['open', 'render_view']);
    clear();
    await run(job('fullView', '/a.ARW', a, { request: { source: a, setParams: { film_stock: 'x' }, method: 'render_view', params: { ...view, tier: 'full' } } }));
    expect(methods()).toEqual(['set_params', 'render_view']);
    expect(calls.map(([, p]) => p.session)).toEqual(['s1', 's1']);
    clear();
    await run(job('fullView', '/a.ARW', a));
    expect(methods()).toEqual(['render_view']);
    clear();
    // The same frame from other pixels, and another frame: their own sessions, closed.
    await run(job('fullView', '/a.ARW', { path: '/a.ARW' }));
    expect(methods()).toEqual(['open', 'render_view', 'close']);
    clear();
    await run(job('fullView', '/b.ARW', { path: '/b.ARW' }));
    expect(methods()).toEqual(['open', 'render_view', 'close']);
    expect(calls[1]![1].session).toBe('s3');
    clear();
    // The editing session is as it was: the canvas's next reprint needs no open.
    await run(job('canvasReprint', '/a.ARW', a, { layers: ['print'] }));
    expect(methods()).toEqual(['render_view']);
  });
});
