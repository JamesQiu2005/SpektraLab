// types.ts — the words the webview and the scheduler speak: WIRE.md
// (`desktop/crates/spk-scheduler/WIRE.md`, `src/wire.rs`), which is the
// contract the Rust scheduler serves through Tauri (`src-tauri/src/scheduler.rs`)
// and the in-page mock (`localScheduler.ts`) serves in the browser. camelCase,
// the Swift names where a Swift type exists. `wire.test.ts` holds both to
// WIRE.md's own examples.
//
// A job is DATA: what it is for, which frame, how big, and the host calls it
// consists of (`request`). The engine — Rust's `HostEngine`, or the mock's
// `MockEngine` — owns every session: the webview names frames, never sessions,
// except the editing session handle `editingOpen` gives it for the calls that
// are not jobs (WIRE.md, "Sessions").

export type JobKind = 'canvasReprint' | 'canvasDevelop' | 'shot' | 'importDevelop' | 'export' | 'fullView' | 'thumbnail' | 'stockPreview';

/** Who asked decides the order (WIRE.md, `kind`): lower runs first. */
export const JOB_PRIORITY: Record<JobKind, number> = {
  canvasReprint: 1, canvasDevelop: 1, shot: 2, export: 3, fullView: 3, stockPreview: 4, importDevelop: 5, thumbnail: 6,
};

export const isCanvas = (k: JobKind) => k === 'canvasReprint' || k === 'canvasDevelop';

export type Tier = 'live' | 'preview' | 'full';
export type ParamLayer = 'shoot' | 'print';
export interface PixelSize { width: number; height: number }

/** What a session is opened from: `open {path, decode?, params?}`, or `open_pair` when `pair` is set. */
export interface SourceSpec {
  path: string;
  decode?: Record<string, unknown>;
  params?: Record<string, unknown>;
  pair?: unknown;
}

/** The host calls a job is made of. `params` never carry `session` or `progress_id`: the engine adds them. */
export interface JobRequest {
  source?: SourceSpec;
  setParams?: Record<string, unknown>;
  /** `render_view`, `render`, `export_frame`, `export_cineon`, `render_proof`, `export_image`, `preview_stock_lut`, `render_source`, `thumbnail`. */
  method: string;
  params: Record<string, unknown>;
}

/** `scheduler_submit(job)` (WIRE.md, "JobSpec"). */
export interface JobSpec {
  frameId: string;
  kind: JobKind;
  tier: Tier;
  canvas: PixelSize;
  layers?: ParamLayer[];
  what?: string;
  decodesOriginal?: boolean;
  bandable?: boolean;
  original?: PixelSize;
  printLayers?: number;
  /** The frame the engine opens when larger than the canvas: below Full, the decoded size (WIRE.md's tip for the v1 host). */
  opens?: PixelSize;
  slot?: string;
  gainMap?: boolean;
  gainMaps?: number;
  hdrRendition?: boolean;
  rawDecode?: boolean;
  request: JobRequest;
}

/** The wire's reasons, and the page's own two (held in the client before a job is submitted). */
export type WaitReason = 'memory' | 'camera' | 'capture' | 'background' | 'queued' | 'settling' | 'dialog';
export type RenderStage = 'Decode' | 'Film' | 'Print' | 'Scan' | 'Save';

export type JobStateWire =
  | { state: 'queued' }
  | { state: 'waiting'; reason: WaitReason; text: string }
  | { state: 'running'; stage: RenderStage; fraction: number; band: number; bandCount: number }
  | { state: 'done' }
  | { state: 'cancelled' }
  | { state: 'failed'; message: string };

/** `scheduler_snapshot` rows and the `scheduler://job` event (flat: the state's fields beside the job's). */
export type JobSnapshotWire = {
  jobId: string;
  frameId: string;
  kind: JobKind;
  tier: Tier;
  canvas: PixelSize;
  what: string;
  /** "Developing" or "Printing". */
  verb: string;
  slot?: string;
  /** The plan's mode ("whole", "bands(1008)", "wait(memory)"); null before it is planned. */
  mode: string | null;
} & JobStateWire;

export interface ResultWire {
  seconds: number;
  reprint: boolean;
  size: PixelSize;
  method?: string;
  /** The host reply's `result`, verbatim. */
  hostResult?: Record<string, unknown>;
  payloadBytes: number;
}

/** `scheduler_outcome(jobId)`'s header; the payload travels beside it (delivered once). */
export interface OutcomeWire {
  jobId: string;
  outcome: 'finished' | 'cancelled' | 'failed';
  message?: string;
  result?: ResultWire;
}

export interface Outcome {
  outcome: OutcomeWire;
  payload: Uint8Array;
}

export interface BudgetSidesWire {
  bytes: number; appSide: number; phoneSide: number; appBytes: number; phoneBytes: number;
  gpuSide?: number; gpuBytes?: number; cameraReserve: number; binding: 'allowance' | 'phone' | 'gpu';
}

/** `scheduler_budget()` (Settings › Engine). */
export interface BudgetReadingWire {
  budget: BudgetSidesWire;
  asked: BudgetSidesWire;
  reading: { appAvailable: number; free: number; inactive: number; purgeable: number; wired: number; compressed: number; footprint: number; gpuAvailable?: number };
  frontend: string;
  engine: { name: string; makesPictures: boolean; effectVersions: string };
  policy: { device: string; developCapMegapixels: number; previewLongEdge: number; previewEdges: number[]; timeRatio: number; unmeasured: string[] };
  jobs: number;
}

/** `scheduler_frontend_state(state)`. */
export interface FrontendStateMsg {
  visiblePage?: string;
  openFrame?: string;
  foreground: boolean;
  scene: 'active' | 'inactive' | 'background';
  interaction?: { dragging: ParamLayer } | null;
  thermal?: 'nominal' | 'fair' | 'serious' | 'critical';
  lowPower?: boolean;
}

/** What the window is doing, as the page knows it; the client sends the wire's part and keeps `dialogOpen` (README §7). */
export interface FrontendState {
  visiblePage: 'library' | 'edit' | 'lightTable' | 'contactSheet' | 'export' | 'settings';
  openFrame: string | null;
  foreground: boolean;
  interaction: 'idle' | 'dragging';
  dialogOpen: boolean;
}

export function frontendMsg(s: FrontendState): FrontendStateMsg {
  return {
    visiblePage: s.visiblePage === 'edit' ? 'develop' : s.visiblePage,
    ...(s.openFrame ? { openFrame: s.openFrame } : {}),
    foreground: s.foreground,
    // A desktop keeps rendering behind other windows (WIRE.md): the gate stays open.
    scene: 'active',
    interaction: s.interaction === 'dragging' ? { dragging: 'print' } : null,
  };
}

/** A host reply as `host_request` frames it: the result and the payload, or the host's error. */
export interface HostReply { result: Record<string, unknown>; payload: Uint8Array }

/** The scheduler, as the webview sees it: the Tauri commands (`tauriScheduler.ts`), or the in-page mock. */
export interface SchedulerClient {
  submit(job: JobSpec): Promise<string>;
  cancel(jobId: string): Promise<void>;
  cancelFrame(frameId: string, kinds?: JobKind[]): Promise<void>;
  /** Resolves when the job ends (finished, cancelled or failed); never rejects. Pixels are handed over once. */
  outcome(jobId: string): Promise<Outcome>;
  snapshot(frameId?: string): Promise<JobSnapshotWire[]>;
  budget(): Promise<BudgetReadingWire>;
  frontendState(state: FrontendState): Promise<void>;
  memoryPressure(level: 'warning' | 'critical'): Promise<void>;
  /** `scheduler://job`: a job's snapshot whenever it changes. */
  onJob(listener: (s: JobSnapshotWire) => void): () => void;
  /** The frame opened in the engine's editing session: the host's `open` / `open_pair` reply (its `session` is the handle). */
  editingOpen(frameId: string, source: SourceSpec): Promise<HostReply>;
  /** A call that is not a job on the frame's editing session (`set_params`, `solve`, `scene_latitude`, `pick_neutral`, …). */
  editingCall(frameId: string, session: string, method: string, params: Record<string, unknown>): Promise<HostReply>;
}

/** The words of a waiting job (WIRE.md's `text`; the page's own for its own two reasons). */
export function waitText(reason: WaitReason): string {
  switch (reason) {
    case 'memory': return 'Waiting for memory';
    case 'camera': return 'Waiting for the camera to free memory';
    case 'capture': return 'Waiting for the photo to land';
    case 'background': return 'Paused — app in the background';
    case 'queued': return 'Waiting its turn';
    case 'settling': return 'Settling';
    case 'dialog': return 'Waiting for the dialog';
  }
}

export const verbOf = (kind: JobKind) => (kind === 'canvasReprint' ? 'Printing' : 'Developing');
export const isLive = (s: JobSnapshotWire) => s.state === 'queued' || s.state === 'waiting' || s.state === 'running';
