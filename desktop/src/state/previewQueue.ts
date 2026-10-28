// Background work owns one promise, including while that promise is being
// cancelled. Aborting a RAW request must never make room for a second decode
// before the host has actually released the first one.

export interface PreviewJob {
  readonly path: string;
  /** Includes source identity and every setting that changes the cached image. */
  readonly key: string;
}

export interface PreviewQueueSnapshot {
  readonly total: number;
  readonly completed: number;
  readonly skipped: number;
  readonly failed: number;
  readonly pending: number;
  readonly current: PreviewJob | null;
  readonly paused: boolean;
  readonly foregroundBusy: boolean;
}

export type PreviewJobResult = void | 'skipped';
/** Check signal after each host await and before publishing/writing a result. */
export type PreviewRunner = (job: PreviewJob, signal: AbortSignal) => Promise<PreviewJobResult>;
type State = 'pending' | 'completed' | 'skipped' | 'failed';
interface Entry { job: PreviewJob; state: State }
interface Active { job: PreviewJob; controller: AbortController }

export class PreviewQueue {
  private entries = new Map<string, Entry>();
  private active: Active | null = null;
  private currentPath: string | null = null;
  private paused = false;
  private foregroundBusy = false;
  private disposed = false;
  private scheduled = false;
  private listeners = new Set<() => void>();
  private idleWaiters = new Set<() => void>();
  private snapshot: PreviewQueueSnapshot = Object.freeze({
    total: 0, completed: 0, skipped: 0, failed: 0, pending: 0,
    current: null, paused: false, foregroundBusy: false,
  });

  constructor(private readonly run: PreviewRunner) {}

  getSnapshot = (): PreviewQueueSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    if (!this.disposed) this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  };

  /** A new import retries failures. Only completed, identical versions survive. */
  replace(jobs: readonly PreviewJob[], currentPath: string | null = this.currentPath): void {
    if (this.disposed) return;
    const next = new Map<string, Entry>();
    for (const job of jobs) {
      const old = this.entries.get(job.path);
      next.set(job.path, {
        job: Object.freeze({ path: job.path, key: job.key }),
        state: old?.job.key === job.key && old.state === 'completed' ? 'completed' : 'pending',
      });
    }
    this.entries = next;
    this.currentPath = currentPath;
    const active = this.active;
    if (active && next.get(active.job.path)?.job.key !== active.job.key) active.controller.abort();
    this.changed();
  }

  /** Reprioritise queued work; an in-progress task may finish unless foreground work interrupts it. */
  setCurrent(path: string | null): void {
    if (this.disposed || this.currentPath === path) return;
    this.currentPath = path;
    this.changed();
  }

  setPaused(paused: boolean): void {
    if (this.disposed || this.paused === paused) return;
    this.paused = paused;
    if (paused) this.active?.controller.abort();
    this.changed();
  }

  setForegroundBusy(busy: boolean): void {
    if (this.disposed || this.foregroundBusy === busy) return;
    this.foregroundBusy = busy;
    if (busy) this.active?.controller.abort();
    this.changed();
  }

  /** The caller also invalidates the corresponding image cache. */
  invalidate(path: string): void {
    if (this.disposed) return;
    const entry = this.entries.get(path);
    if (!entry) return;
    entry.state = 'pending';
    if (this.active?.job.path === path) this.active.controller.abort();
    this.changed();
  }

  cancel(): void {
    this.entries.clear();
    this.active?.controller.abort();
    this.changed();
  }

  /** Set foreground busy first, then wait for the active task to release resources. */
  whenIdle(): Promise<void> {
    if (!this.active) return Promise.resolve();
    return new Promise((resolve) => { this.idleWaiters.add(resolve); });
  }

  dispose(): void {
    this.disposed = true;
    this.cancel();
    this.listeners.clear();
  }

  private changed(): void {
    let completed = 0, skipped = 0, failed = 0, pending = 0;
    for (const entry of this.entries.values()) {
      switch (entry.state) {
        case 'completed': completed++; break;
        case 'skipped': skipped++; break;
        case 'failed': failed++; break;
        case 'pending':
          if (entry.job.path !== this.active?.job.path || entry.job.key !== this.active.job.key) pending++;
          break;
      }
    }
    this.snapshot = Object.freeze({
      total: this.entries.size, completed, skipped, failed, pending,
      current: this.active?.job ?? null, paused: this.paused, foregroundBusy: this.foregroundBusy,
    });
    for (const listener of this.listeners) listener();
    this.schedule();
  }

  private schedule(): void {
    if (this.scheduled || this.disposed || this.active || this.paused || this.foregroundBusy) return;
    this.scheduled = true;
    queueMicrotask(() => {
      this.scheduled = false;
      if (this.disposed || this.active || this.paused || this.foregroundBusy) return;
      const entries = [...this.entries.values()];
      const index = entries.findIndex((entry) => entry.job.path === this.currentPath);
      const preferred = index < 0 ? [] : [entries[index], entries[index + 1], entries[index - 1]];
      const next = [...preferred, ...entries].find((entry) => entry?.state === 'pending');
      if (!next) return;
      const active: Active = { job: next.job, controller: new AbortController() };
      this.active = active;
      this.changed();
      void this.execute(active);
    });
  }

  private async execute(active: Active): Promise<void> {
    let state: State = 'completed';
    try {
      if (await this.run(active.job, active.controller.signal) === 'skipped') state = 'skipped';
    } catch {
      state = 'failed';
    } finally {
      const entry = this.entries.get(active.job.path);
      // Some host operations cannot stop mid-decode. A late successful result
      // after abort is still obsolete and must not complete the replacement job.
      if (!active.controller.signal.aborted && entry?.job.key === active.job.key) entry.state = state;
      this.active = null;
      for (const resolve of this.idleWaiters) resolve();
      this.idleWaiters.clear();
      this.changed();
    }
  }
}
