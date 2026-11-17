// types.ts — the words the webview and the scheduler speak (PRD-W0 §5.2).
//
// The names follow the Mac scheduler's (`Sources/Scheduler/SchedulerTypes.swift`:
// `JobKind`, `WaitReason`, `RenderStage`, `JobSnapshot`), camelCase, so a job
// log reads the same on every platform. A job is DATA: what it is for, which
// frame, and the host requests it consists of. Nothing here is a closure, so
// in phase 2 the same object crosses into Rust (`scheduler_submit`) and the
// Rust scheduler runs the steps against the one host process; in phase 1 the
// in-page `LocalScheduler` runs them against the v1 host client.

export type JobKind = 'canvasReprint' | 'canvasDevelop' | 'fullView' | 'export' | 'thumbnail' | 'stockPreview';

/** Who asked decides the order (the Mac's `JobKind.priority`): lower runs first. */
export const JOB_PRIORITY: Record<JobKind, number> = {
  canvasReprint: 1,
  canvasDevelop: 1,
  export: 3,
  fullView: 3,
  stockPreview: 4,
  thumbnail: 6,
};

export const isCanvas = (k: JobKind) => k === 'canvasReprint' || k === 'canvasDevelop';

/** Why a job is not running, in the words the page shows. */
export type WaitReason =
  /** An edit is settling (README §7: 180 ms with no further change). */
  | 'settling'
  /** Something more urgent is running. */
  | 'queued'
  /** Nothing fits in what the host can spare. */
  | 'memory'
  /** The window is in the background. */
  | 'background'
  /** A file dialog is open: pending edits wait (README §7). */
  | 'dialog';

export type RenderStage = 'Decode' | 'Film' | 'Print' | 'Scan' | 'Save';

/** One request to the host, as HOST-PROTOCOL §3 names it. */
export interface HostStep {
  method: string;
  params: Record<string, unknown>;
  /** Pixels uploaded with the request (write_image). */
  payload?: Uint8Array;
}

export type ParamLayer = 'shoot' | 'film' | 'print' | 'post' | 'decode' | 'geometry';

export interface JobRequest {
  kind: JobKind;
  /** The frame's path (a pair: its key). */
  frameId: string;
  /** The page's words for it: the stock, the control, the file (`Developing · Gold 200`). */
  what: string;
  tier: 'live' | 'preview' | 'full';
  layers?: ParamLayer[];
  /** Coalescing key for stock previews (one card = one slot). */
  slot?: string;
  steps: HostStep[];
}

export type JobState =
  | { state: 'queued' }
  | { state: 'waiting'; reason: WaitReason }
  | { state: 'running'; stage: RenderStage | null; fraction: number | null; step: number; steps: number }
  | { state: 'done' }
  | { state: 'cancelled'; supersededBy?: string }
  | { state: 'failed'; message: string; code?: string };

export interface JobSnapshot {
  id: string;
  job: Omit<JobRequest, 'steps'> & { submitted: number };
  state: JobState;
  /** When it started running and ended, on the scheduler's clock (ms). */
  startedAt?: number;
  endedAt?: number;
  /** A newer job of the same frame and kind was submitted while this one ran: its result is not shown. */
  superseded?: boolean;
}

export interface StepResult {
  result: unknown;
  payload?: Uint8Array;
}

export interface JobOutcome {
  id: string;
  status: 'done' | 'cancelled' | 'failed';
  superseded: boolean;
  supersededBy?: string;
  error?: { message: string; code?: string };
  /** One per step that ran, in order. */
  results: StepResult[];
}

/** What Settings › Engine shows of the scheduler (README §6.5). */
export interface BudgetReading {
  device: string | null;
  backend: string | null;
  /** Bytes the scheduler plans against, and holds now; null where the host reports none. */
  budgetBytes: number | null;
  inUseBytes: number | null;
  running: number;
  queued: number;
}

export interface FrontendState {
  visiblePage: 'library' | 'edit' | 'lightTable' | 'contactSheet' | 'export' | 'settings';
  openFrame: string | null;
  foreground: boolean;
  interaction: 'idle' | 'dragging';
  dialogOpen: boolean;
}

/** The scheduler, as the webview sees it. Phase 1: `LocalScheduler`; phase 2: the Tauri commands. */
export interface SchedulerClient {
  submit(job: JobRequest): Promise<string>;
  cancel(jobId: string): Promise<void>;
  cancelFrame(frameId: string, kinds?: JobKind[]): Promise<void>;
  /** Resolves when the job ends (done, cancelled or failed); never rejects. */
  outcome(jobId: string): Promise<JobOutcome>;
  snapshot(frameId?: string): Promise<JobSnapshot[]>;
  budget(): Promise<BudgetReading>;
  frontendState(state: FrontendState): Promise<void>;
  /** `scheduler://job`: a job's snapshot whenever it changes. */
  onJob(listener: (s: JobSnapshot) => void): () => void;
}
