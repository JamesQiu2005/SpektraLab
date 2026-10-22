import { describe, expect, it, vi } from 'vitest';
import { PreviewQueue, type PreviewJob } from './previewQueue';

const jobs = (...paths: string[]): PreviewJob[] => paths.map((path) => ({ path, key: `${path}:v1` }));
const turn = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
function deferred() {
  let resolve!: () => void;
  const promise = new Promise<void>((done) => { resolve = done; });
  return { promise, resolve };
}

describe('background preview scheduling', () => {
  it('prioritises the current photo and its neighbours before the import order', async () => {
    const paths: string[] = [];
    const queue = new PreviewQueue(async (job) => { paths.push(job.path); });
    queue.setPaused(true);
    queue.replace(jobs('a', 'b', 'c', 'd', 'e'), 'c');
    await turn();
    expect(paths).toEqual([]);
    queue.setPaused(false);
    await turn();
    expect(paths).toEqual(['c', 'd', 'b', 'a', 'e']);
    expect(queue.getSnapshot()).toMatchObject({ total: 5, completed: 5, pending: 0, current: null });
  });

  it('deduplicates paths and uses the newest source/snapshot key', async () => {
    const run = vi.fn(async (_job: PreviewJob) => {});
    const queue = new PreviewQueue(run);
    queue.replace([...jobs('a', 'b'), { path: 'a', key: 'a:v2' }]);
    await turn();
    expect(run.mock.calls.map(([job]) => job)).toEqual([{ path: 'a', key: 'a:v2' }, { path: 'b', key: 'b:v1' }]);
    expect(queue.getSnapshot().total).toBe(2);
  });

  it('keeps an aborted promise in the single running slot until it actually settles', async () => {
    const first = deferred();
    const calls: { job: PreviewJob; signal: AbortSignal }[] = [];
    let concurrent = 0, peak = 0;
    const queue = new PreviewQueue(async (job, signal) => {
      calls.push({ job, signal });
      peak = Math.max(peak, ++concurrent);
      if (calls.length === 1) await first.promise;
      concurrent--;
    });
    queue.replace(jobs('a', 'b'));
    await turn();
    queue.setForegroundBusy(true);
    expect(calls[0]!.signal.aborted).toBe(true);
    queue.setCurrent('b');
    queue.setForegroundBusy(false);
    await turn();
    expect(calls).toHaveLength(1);
    first.resolve();
    await turn();
    expect(calls.map(({ job }) => job.path)).toEqual(['a', 'b', 'a']);
    expect(peak).toBe(1);
    expect(queue.getSnapshot()).toMatchObject({ completed: 2, failed: 0 });
  });

  it('pauses user-requested work and resumes the interrupted photo without treating cancellation as failure', async () => {
    const first = deferred();
    const run = vi.fn(async (_job: PreviewJob, _signal: AbortSignal) => { if (run.mock.calls.length === 1) await first.promise; });
    const queue = new PreviewQueue(run);
    queue.replace(jobs('a'));
    await turn();
    queue.setPaused(true);
    first.resolve();
    await queue.whenIdle();
    expect(queue.getSnapshot()).toMatchObject({ paused: true, pending: 1, completed: 0, failed: 0 });
    queue.setPaused(false);
    await turn();
    expect(run).toHaveBeenCalledTimes(2);
    expect(queue.getSnapshot().completed).toBe(1);
  });

  it('rejects stale completion after a source or edit snapshot changes', async () => {
    const first = deferred();
    const run = vi.fn(async (_job: PreviewJob) => { if (run.mock.calls.length === 1) await first.promise; });
    const queue = new PreviewQueue(run);
    queue.replace(jobs('a'));
    await turn();
    queue.replace([{ path: 'a', key: 'a:changed-file-or-edits' }]);
    await turn();
    expect(run).toHaveBeenCalledTimes(1);
    first.resolve();
    await turn();
    expect(run.mock.calls.map(([job]) => job.key)).toEqual(['a:v1', 'a:changed-file-or-edits']);
    expect(queue.getSnapshot()).toMatchObject({ total: 1, completed: 1 });
    queue.invalidate('a');
    await turn();
    expect(run).toHaveBeenCalledTimes(3);
  });

  it('skips failed files, then retries them on reimport without repeating valid completed keys', async () => {
    let fail = true;
    const run = vi.fn(async (job: PreviewJob) => {
      if (job.path === 'a' && fail) throw new Error('unsupported RAW');
    });
    const queue = new PreviewQueue(run);
    queue.replace(jobs('a', 'b'));
    await turn();
    expect(queue.getSnapshot()).toMatchObject({ failed: 1, completed: 1, pending: 0 });
    fail = false;
    queue.replace(jobs('a', 'b'));
    await turn();
    expect(run.mock.calls.map(([job]) => job.path)).toEqual(['a', 'b', 'a']);
    expect(queue.getSnapshot()).toMatchObject({ failed: 0, completed: 2 });
  });

  it('reports deliberate skips separately from successful previews and failures', async () => {
    const queue = new PreviewQueue(async (job) => job.path === 'a' ? 'skipped' : undefined);
    queue.replace(jobs('a', 'b'));
    await turn();
    expect(queue.getSnapshot()).toMatchObject({ completed: 1, skipped: 1, failed: 0, pending: 0 });
  });

  it('cancels queued work and waits for its active task before starting another import', async () => {
    const first = deferred();
    const run = vi.fn(async (_job: PreviewJob) => { if (run.mock.calls.length === 1) await first.promise; });
    const queue = new PreviewQueue(run);
    queue.replace(jobs('a', 'b'));
    await turn();
    queue.cancel();
    queue.replace(jobs('c'));
    await turn();
    expect(run).toHaveBeenCalledTimes(1);
    first.resolve();
    await turn();
    expect(run.mock.calls.map(([job]) => job.path)).toEqual(['a', 'c']);
    expect(queue.getSnapshot()).toMatchObject({ total: 1, completed: 1 });
  });

  it('provides stable snapshots and stops notifying unsubscribed listeners', async () => {
    const queue = new PreviewQueue(async () => {});
    const listener = vi.fn();
    const unsubscribe = queue.subscribe(listener);
    const snapshot = queue.getSnapshot();
    expect(queue.getSnapshot()).toBe(snapshot);
    queue.setPaused(true);
    expect(queue.getSnapshot()).not.toBe(snapshot);
    unsubscribe();
    const count = listener.mock.calls.length;
    queue.replace(jobs('a'));
    expect(listener).toHaveBeenCalledTimes(count);
    queue.dispose();
    queue.setPaused(false);
    await turn();
    expect(queue.getSnapshot().total).toBe(0);
  });
});
