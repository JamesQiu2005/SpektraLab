// session.ts — the one session (the Mac's `Model/Session.swift`, reduced to
// what this port carries): the library, the open frame and its edits, the
// engine session behind it, undo, the clipboard and the view.
//
// Three kinds of edit, three costs (ARCHITECTURE.md §7.1):
//   params      → a `set_params` delta and a render (reprint if print-only)
//   adjustments → a cached GPU view; never re-develops the film
//   geometry    → cached GPU view after commit; crop gestures draw locally
//
// Pixels do not live in this store: `frames.ts` holds them, and the store
// carries a version number the canvas watches.

import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import type { HelloResult, HostState, FileMetadata, PairInfo, Tier } from '@shared/protocol';
import {
  type FeatureGate,
  type FilmParams,
  type FilmSide,
  ALL_FEATURES,
  FILM_FRAME_CUSTOM,
  delta as paramsDelta,
  featureGate,
  filmFormatMM,
  filmFrameNamed,
  fullDelta,
  normalizeStockPair,
  SCENE_LATITUDE_DEFAULT,
  jsonEqual,
  clamp,
} from '@shared/params';
import { type Adjustments, ADJUSTMENTS_DEFAULT } from '@shared/adjustments';
import { type Geometry, GEOMETRY_DEFAULT, outputSize } from '@shared/geometry';
import { canvasGeometryFor, edgeEffective, gateFramed, geometryInNegative, resolveFilmEdgeParams, sourceGeometryFor } from '@shared/filmEdge';
import { type HalfFramePair, type PairHole, type PairLayer, type PairPlacement, type PairSide, PAIR_SIDES,
  decodePair, encodePair, isPairPath, newHole, newPair, pairFilmFormat, pairRects, pairFitRegion, pairSnapshotFor, pairWithMeterReadings, printTrim, resolvePairParams } from '@shared/pair';
import { type DecodeSettings, type Sidecar, decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import { decodeWire, isRawPath, modeOf } from '@shared/whiteBalance';
import { type ClipboardGroup, type SettingsClip, CLIPBOARD_GROUPS, applyClip, clipChanges } from '@shared/clipboard';
import { EMPTY_CATALOG, type StockCatalog, loadCatalog } from '@shared/stocks';
import { type LatitudeReply, type PlacementIssue, type PlacementSide, type PlacementWindow,
  applyLatitudeFit, fitPlacement, latitudeRequest, measuredFromReply, placementIntent, placementLanding, placementWindow } from '@shared/latitude';
import { HostCallError, host } from '../host/client';
import { type FileEntry, baseName, dirName, platform } from '../platform';
import { settingsStore } from './settings';
import { frameImages, makeThumbFromPrint, THUMB_EDGE } from './frames';
import { thumbs } from './thumbs';
import { frameOrder } from './frameOrder';
import { displayCacheKey, forgetDisplayMemoryCache, peekDisplayCache, readDisplayCache, writeDisplayCache, type DisplayCacheDescriptor } from './displayCache';
import { PreviewQueue } from './previewQueue';
import { tz } from '../i18n';
import { clampZoom, steppedZoom } from '../canvas/zoom';

export type Tool = 'select' | 'hand' | 'crop' | 'neutral';

export interface ViewState {
  /** Fit the output to the canvas; when false, `zoom` is native px → device px. */
  fit: boolean;
  zoom: number;
  /** Pan: the output point (0…1) at the canvas centre. */
  cx: number;
  cy: number;
}

export interface UndoEntry {
  noFilm?: boolean;
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
  heldCrop?: Geometry | null;
  pair?: HalfFramePair | null;
  decode: DecodeSettings;
  placementNeedsFit?: boolean;
}

export interface LatitudeState {
  reply: LatitudeReply | null;
  session: string | null;
  frame: string | null;
  stamp: string | null;
  failure: string | null;
  refusal: PlacementIssue | null;
}
const EMPTY_LATITUDE: LatitudeState = { reply: null, session: null, frame: null, stamp: null, failure: null, refusal: null };

export interface SessionState {
  // host
  hostState: HostState;
  hello: HelloResult | null;
  gate: FeatureGate;
  unsupported: string[];
  catalog: StockCatalog;
  // library
  folder: string | null;
  frames: FileEntry[];
  selection: string | null;
  picked: string[];
  savedGeometry: Record<string, Geometry>;
  thumbVersion: number;
  // the open frame
  sidecar: Sidecar;
  pair: HalfFramePair | null;
  pairInfo: PairInfo | null;
  pairLayer: PairLayer;
  pairPlacing: boolean;
  engineSession: string | null;
  nativeSize: { width: number; height: number } | null;
  metadata: FileMetadata | null;
  /** The open frame's kind as the host decoded it (`raw`, `tiff`, …); null until it lands. */
  frameKind: string | null;
  /** A decode-setting change (white balance) is being re-decoded. */
  redecoding: boolean;
  imageVersion: number;
  badge: Tier | null;
  developing: boolean;
  status: string;
  lastError: string | null;
  /** Disk edits never silently replace unsaved edits in the current editor. */
  externalEditConflict: boolean;
  latitude: LatitudeState;
  // view
  tool: Tool;
  view: ViewState;
  fitZoom: number;
  /** The canvas in device px (the navigator draws the visible part from it). */
  canvasPx: { width: number; height: number };
  showingOriginal: boolean;
  comparing: boolean;
  comparePosition: number;
  displaySpace: 'srgb' | 'display-p3';
  /** Actual WebGL limit; null until the canvas has created its context. */
  maxTextureSize: number | null;
  // edits
  undo: UndoEntry[];
  redo: UndoEntry[];
  clipboard: SettingsClip | null;
  clipboardGroups: ClipboardGroup[];
  // pages
  exportOpen: boolean;
  settingsOpen: boolean;
  aboutOpen: boolean;
  batchExporting: boolean;
}

const INITIAL: SessionState = {
  hostState: { phase: 'starting' },
  hello: null,
  gate: ALL_FEATURES,
  unsupported: [],
  catalog: EMPTY_CATALOG,
  folder: null,
  frames: [],
  selection: null,
  picked: [],
  savedGeometry: {},
  thumbVersion: 0,
  sidecar: newSidecar(),
  pair: null,
  pairInfo: null,
  pairLayer: 'film',
  pairPlacing: false,
  engineSession: null,
  nativeSize: null,
  metadata: null,
  frameKind: null,
  redecoding: false,
  imageVersion: 0,
  badge: null,
  developing: false,
  status: '',
  lastError: null,
  externalEditConflict: false,
  latitude: EMPTY_LATITUDE,
  tool: 'select',
  fitZoom: 1,
  canvasPx: { width: 1, height: 1 },
  view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 },
  showingOriginal: false,
  comparing: false,
  comparePosition: 0.5,
  displaySpace: 'srgb',
  maxTextureSize: null,
  undo: [],
  redo: [],
  clipboard: null,
  clipboardGroups: [...CLIPBOARD_GROUPS],
  exportOpen: false,
  settingsOpen: false,
  aboutOpen: false,
  batchExporting: false,
};

export const sessionStore = createStore<SessionState>(() => INITIAL);
export const useSession = <T>(sel: (s: SessionState) => T): T => useStore(sessionStore, sel);
const get = () => sessionStore.getState();
const set = (p: Partial<SessionState>) => sessionStore.setState(p);

// ------------------------------------------------------------ the scheduler
//
// "Sent vs wanted" (`RenderScheduler.swift`): one render in flight; edits
// made while it runs only move what is wanted, and the loop catches up with
// the newest state when it lands. The original-resolution render starts
// 400 ms after the last edit and is dropped if anything moved meanwhile.

let sentParams: FilmParams | null = null;
let sentPair: string | null = null;
let savedPair: { path: string; value: string } | null = null;
const pairHoleGeneration = { left: 0, right: 0 };
let pairDecodeSave: Promise<void> = Promise.resolve();
let openingTask: Promise<void> = Promise.resolve();
let liveDisplayKey: { session: string; key: string } | null = null;
let previewIdleTimer: ReturnType<typeof setTimeout> | null = null;

const cameraDescriptor = (path: string): DisplayCacheDescriptor => ({ kind: 'original', sources: [path],
  configuration: { version: 1, embeddedCameraPreview: true, longEdge: 2048, display: 'srgb', format: 'rgba8' } });

/** Import previews never open an engine session or fall back to RAW decode. */
export const importPreviews = new PreviewQueue(async ({ path }, signal) => {
  if (!get().hello?.thumbnail_options?.includes('embedded-only')) return 'skipped';
  const key = await displayCacheKey(cameraDescriptor(path));
  if (signal.aborted) return;
  if (!key) return 'skipped'; // Persistent prebuilding requires the native file-identity key.
  const paths = get().frames.map((f) => f.path), index = paths.indexOf(get().selection ?? '');
  const near = Math.abs(paths.indexOf(path) - index) <= 1;
  // Neighbour film pictures are display-only too; prime at most two, never
  // decode a second RAW or create another GPU session for prefetching. Prefer
  // an existing full picture before letting its camera JPEG consume RAM too.
  let fullReady = false;
  if (near && !signal.aborted) {
    const raw = path === get().selection ? null : await platform().sidecarLoad(path).catch(() => null);
    const sidecar = path === get().selection ? get().sidecar : raw ? filmStageSidecar(decodeSidecar(raw)) : null;
    if (sidecar?.params.filmEdge.seeded && !signal.aborted) {
      const snapshot = { ...get(), selection: path, pair: null, sidecar, tool: 'select' as const, view: { ...get().view, fit: true } };
      const desc = cachedDisplayDescriptor('print', snapshot);
      if (desc) {
        const printKey = await displayCacheKey(desc);
        if (!signal.aborted) {
          forgetDisplayMemoryCache(key);
          fullReady = !!await readDisplayCache(printKey);
        }
      }
    }
  }
  if (signal.aborted) return;
  const retain = near && !fullReady;
  const found = await readDisplayCache(key, { retain });
  if (signal.aborted) return;
  if (!found) {
    const image = await host().thumbnail(path, 2048, true);
    if (signal.aborted) return;
    if (!await writeDisplayCache(key, image, { retain })) return 'skipped';
  }
});
importPreviews.setForegroundBusy(true);

function foregroundWork() {
  if (previewIdleTimer) clearTimeout(previewIdleTimer);
  previewIdleTimer = null;
  importPreviews.setForegroundBusy(true);
}
function resumePreviewsWhenIdle() {
  if (previewIdleTimer) clearTimeout(previewIdleTimer);
  previewIdleTimer = setTimeout(() => {
    previewIdleTimer = null;
    const s = get();
    if (!s.developing && !s.redecoding && !s.batchExporting && !s.exportOpen && !inFlight && !originalInFlight
      && s.hostState.phase === 'ready') importPreviews.setForegroundBusy(false);
  }, 1200);
}
function queueImportPreviews() {
  const s = get();
  importPreviews.replace(s.hello?.thumbnail_options?.includes('embedded-only')
    ? s.frames.filter((f) => isRawPath(f.path)).map((f) => ({ path: f.path, key: JSON.stringify([f.path, f.size, f.mtime_ms]) })) : [], s.selection ?? undefined);
}
let wantedGen = 0;
let inFlight = false;
let fullTimer: ReturnType<typeof setTimeout> | null = null;
let latitudeTimer: ReturnType<typeof setTimeout> | null = null;
let latitudeGeneration = 0;
let placementTask: number | null = null;
let placementTaskGeneration = 0;
let saveTimer: ReturnType<typeof setTimeout> | null = null;
let savePending = false;
let saveRevision = 0;
let saveTask: Promise<void> | null = null;
let agentRevision: string | undefined;
let agentPolling = false;
let agentPollTimer: ReturnType<typeof setInterval> | null = null;
const pendingExternalPaths = new Set<string>();
let savedDocument: { path: string; content: string } | null = null;
const pairSourceSidecars = new Map<string, Sidecar>();
let pairTimer: ReturnType<typeof setTimeout> | null = null;
let lastUndoAt = 0;
let openGen = 0;
let originalGeneration = 0;
let originalInFlight = false;
let lastOriginalKey: string | null = null;
let neutralPickGeneration = 0;
let neutralPairSide: PairSide | null = null;
let neutralPreviousOriginal: boolean | null = null;
const FULL_DELAY_MS = 400;
interface OpenTrace {
  generation: number; path: string; origin: 'select' | 'develop'; started: number;
  developStarted?: number; openCallMs?: number; originalMs?: number;
  session?: string; committedAt?: number; drawn?: boolean;
  visibleAt?: number; visibleSource?: string; visibleDrawn?: boolean;
}
let openTrace: OpenTrace | null = null;
const elapsed = (start: number) => Math.round((performance.now() - start) * 10) / 10;

function noteVisible(source: string) {
  const trace = openTrace;
  if (!trace || trace.generation !== openGen || trace.visibleAt !== undefined) return;
  trace.visibleAt = performance.now(); trace.visibleSource = source;
  platform().log('info', `session: preview_visible ${JSON.stringify({ event: 'committed', source, total_ms: elapsed(trace.started) })}`);
}

function noteFirstViewCommitted(sid: string, width: number, height: number, renderMs: number) {
  noteVisible('engine');
  const trace = openTrace;
  if (!trace || trace.generation !== openGen || trace.session !== sid || trace.committedAt !== undefined) return;
  trace.committedAt = performance.now();
  platform().log('info', `session: first_view ${JSON.stringify({ event: 'committed', origin: trace.origin,
    total_ms: elapsed(trace.started), develop_ms: trace.developStarted === undefined ? null : elapsed(trace.developStarted),
    open_call_ms: trace.openCallMs, render_call_ms: Math.round(renderMs * 10) / 10,
    original_thumbnail_ms: trace.originalMs ?? null, original_thumbnail_pending: trace.originalMs === undefined,
    width, height, display: get().displaySpace })}`);
}

/** Called after WebGL accepts the first draw. This is submission, not a
 * monitor presentation timestamp; it includes host/transport and UI delays.
 */
export function notePreviewDrawn() {
  const trace = openTrace;
  if (trace && trace.generation === openGen && trace.visibleAt !== undefined && !trace.visibleDrawn) {
    trace.visibleDrawn = true;
    platform().log('info', `session: preview_visible ${JSON.stringify({ event: 'draw_submitted', source: trace.visibleSource,
      total_ms: elapsed(trace.started), commit_to_draw_ms: elapsed(trace.visibleAt) })}`);
  }
  if (!frameImages.print || !trace || trace.generation !== openGen || trace.session !== get().engineSession
    || trace.committedAt === undefined || trace.drawn) return;
  trace.drawn = true;
  platform().log('info', `session: first_view ${JSON.stringify({ event: 'draw_submitted', origin: trace.origin,
    total_ms: elapsed(trace.started), commit_to_draw_ms: elapsed(trace.committedAt) })}`);
}

function noteError(op: string, e: unknown) {
  const msg = e instanceof HostCallError ? `${e.message} (${e.code})` : e instanceof Error ? e.message : String(e);
  platform().log('error', `${op}: ${msg}`);
  set({ lastError: `${op}: ${msg}`, status: tz(`${op} failed: ${msg}`, `${op} 失败：${msg}`) });
}

function previewEdge() {
  return settingsStore.getState().previewLongEdge;
}

function wireParams(p: FilmParams) {
  return { ...fullDelta(p, get().gate, get().catalog), preview_long_edge: previewEdge() };
}

export function hostViews(): boolean { return !!get().hello?.methods?.includes('render_view'); }

/** Only bounded fit pictures go to disk. Their exact render snapshot is part
 * of the key; they can warm the display but can never satisfy engine work. */
function cachedDisplayDescriptor(kind: 'print' | 'original', s: SessionState, tier: 'full' | 'live' = 'full'): DisplayCacheDescriptor | null {
  if (!s.selection || s.batchExporting || !s.view.fit || s.tool === 'crop' || s.pairPlacing || s.sidecar.placementNeedsFit) return null;
  if (kind === 'print' && s.sidecar.noFilm && !s.gate.noFilm) return null;
  const canonicalDecode = (d: DecodeSettings) => modeOf(d) === 'As Shot' ? { ...d, temperature: 0, tint: 0 } : d;
  const pair = s.pair ? { ...pairSnapshotFor(s.pair, s.sidecar.params),
    left: s.pair.left ? { ...s.pair.left, decode: canonicalDecode(s.pair.left.decode) } : null,
    right: s.pair.right ? { ...s.pair.right, decode: canonicalDecode(s.pair.right.decode) } : null } : null;
  const longEdge = Math.min(Math.max(previewEdge(), s.canvasPx.width, s.canvasPx.height), s.maxTextureSize ?? 16384);
  return { kind, sources: [s.selection, ...(s.pair ? PAIR_SIDES.flatMap((side) => s.pair![side] ? [s.pair![side]!.path] : []) : [])],
    configuration: { version: 3, decode: canonicalDecode(s.sidecar.decode), pair, display: s.displaySpace,
      format: s.hello?.view_formats?.includes('rgba16') && kind === 'print' ? 'rgba16' : 'rgba8', longEdge,
      ...(kind === 'print' || pair ? { params: wireParams(s.sidecar.params) } : {}),
      ...(kind === 'print' ? { tier, noFilm: s.sidecar.noFilm, adjustments: s.sidecar.adjustments,
        geometry: canvasGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm),
        sourceGeometry: sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm) ?? GEOMETRY_DEFAULT } : {}),
    } };
}
function cacheDisplay(key: string | null, image: Parameters<typeof writeDisplayCache>[1], sourceSize: SessionState['nativeSize'], retain = true) {
  if (!key) return;
  // The film canvas may include an edge or an upstream source cut. Retain the
  // decoded source dimensions separately for editing before native open lands.
  const cachedImage = { ...image, cachedSourceSize: sourceSize };
  void writeDisplayCache(key, cachedImage, { retain }).catch(() => {});
}
async function warmDisplayFromCache(path: string, generation: number) {
  const s = get();
  await Promise.all((['print', 'original'] as const).map(async (kind) => {
    const descriptor = cachedDisplayDescriptor(kind, s); if (!descriptor) return;
    const stamp = JSON.stringify(descriptor);
    let image = await readDisplayCache(await displayCacheKey(descriptor), { retain: kind === 'print' });
    let tier: 'full' | 'live' = 'full';
    if (!image && kind === 'print') {
      const live = cachedDisplayDescriptor(kind, s, 'live');
      if (live) image = await readDisplayCache(await displayCacheKey(live));
      tier = 'live';
    }
    if (!image && kind === 'original' && !s.pair)
      image = await readDisplayCache(await displayCacheKey(cameraDescriptor(path)), { retain: false });
    if (!image || generation !== openGen || get().selection !== path || JSON.stringify(cachedDisplayDescriptor(kind, get())) !== stamp) return;
    if (kind === 'print') {
      if (frameImages.print) return;
      frameImages.print = { ...image, tier, reprinted: false, ms: 0 };
      noteVisible('film-cache');
      const source = (image as typeof image & { cachedSourceSize?: SessionState['nativeSize'] }).cachedSourceSize;
      set({ imageVersion: get().imageVersion + 1, nativeSize: get().nativeSize ?? source ?? image.nativeSize ?? null,
        status: tz('Showing cached preview while the engine opens this photograph…', '正在显示缓存预览，引擎继续载入照片…') });
    } else if (lastOriginalKey === null) {
      if (!frameImages.print) noteVisible('source-cache');
      frameImages.original = image; set({ imageVersion: get().imageVersion + 1 });
    }
  }));
}

/** Bound readback by the displayed detail, independently of the film tier.
 * Full-source film/grain still runs at native resolution after the idle delay.
 * 0 requests native output; nonzero is a GPU resize before CPU readback.
 */
export function viewLongEdge(s: Pick<SessionState, 'nativeSize' | 'sidecar' | 'tool' | 'view' | 'canvasPx' | 'maxTextureSize'>, preview = previewEdge()): number {
  const geometry = s.tool === 'crop' ? GEOMETRY_DEFAULT : s.sidecar.geometry;
  const out = s.nativeSize ? outputSize(geometry, s.nativeSize) : null;
  const nativeEdge = out ? Math.max(out.width, out.height) : Infinity;
  const fit = s.view.fit || s.tool === 'crop';
  const wanted = fit ? Math.max(preview, s.canvasPx.width, s.canvasPx.height)
    : Math.max(preview, Math.ceil(nativeEdge * Math.min(s.view.zoom, 1)));
  const edge = Math.max(1, Math.min(Math.ceil(wanted), s.maxTextureSize ?? 16384));
  return nativeEdge <= edge ? 0 : edge;
}

export function noteTextureLimit(maxTextureSize: number) {
  const before = viewLongEdge(get());
  if (get().maxTextureSize === maxTextureSize) return;
  set({ maxTextureSize });
  if (hostViews() && before !== viewLongEdge(get()) && !get().batchExporting) void requestPrint();
  void refreshOriginal();
}

export function noteDisplaySpace(displaySpace: 'srgb' | 'display-p3') {
  if (get().displaySpace === displaySpace) return;
  set({ displaySpace });
  if (hostViews() && !get().batchExporting) void requestPrint();
  void refreshOriginal();
}

async function renderForView(sid: string, tier: 'live' | 'full', gen: number, reprint = false) {
  const s = get();
  if (s.sidecar.noFilm && (s.pair || !s.gate.noFilm || !hostViews()))
    throw new Error(tz('This engine or half-frame pair cannot bypass film simulation.', '此引擎或半格拼接不支持不应用胶片模拟。'));
  if (!hostViews()) return host().render(sid, tier, { reprint });
  if (tier === 'full' && s.pair) await flushSave();
  const descriptor = cachedDisplayDescriptor('print', s, tier);
  const keyTask = descriptor ? displayCacheKey(descriptor) : Promise.resolve(null);
  const fullDescriptor = tier === 'live' ? cachedDisplayDescriptor('print', s) : null;
  const [cacheKey, fullKey, cameraKey] = await Promise.all([keyTask,
    fullDescriptor ? displayCacheKey(fullDescriptor) : keyTask,
    tier === 'full' && !s.pair && s.selection ? displayCacheKey(cameraDescriptor(s.selection)) : null]);
  if (gen !== wantedGen || get().engineSession !== sid) throw new Error('Superseded display request');
  const image = await host().renderView(sid, tier, { adjustments: s.sidecar.adjustments,
    ...(s.sidecar.noFilm ? { no_film: true } : {}),
    geometry: s.tool === 'crop' ? GEOMETRY_DEFAULT : canvasGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm),
    source_geometry: sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm) ?? GEOMETRY_DEFAULT,
    display: s.displaySpace, generation: gen, long_edge: viewLongEdge(s) });
  if (gen === wantedGen && get().engineSession === sid && image.pairInfo) set({ pairInfo: image.pairInfo });
  if (gen === wantedGen && get().engineSession === sid) {
    if (tier === 'full' && liveDisplayKey?.session === sid) { forgetDisplayMemoryCache(liveDisplayKey.key); liveDisplayKey = null; }
    if (tier === 'full') forgetDisplayMemoryCache(cameraKey);
    if (tier === 'live' && cacheKey) liveDisplayKey = { session: sid, key: cacheKey };
    // A resident full image with this exact edit/source/display key already
    // covers a revisit. A different edited snapshot still needs its live view.
    cacheDisplay(cacheKey, image, s.nativeSize, tier === 'full' || !peekDisplayCache(fullKey));
  }
  return image;
}

/**
 * As Shot keeps the camera's pair in the sidecar too, once a decode reported
 * it (the Mac does the same when the decode lands). Derived: no undo step.
 */
function noteAsShot() {
  const s = get();
  const shot = s.metadata?.as_shot;
  const d = s.sidecar.decode;
  if (!shot || modeOf(d) !== 'As Shot') return;
  if (d.temperature === shot.temperature_k && d.tint === shot.tint) return;
  set({ sidecar: { ...s.sidecar, decode: { ...d, temperature: shot.temperature_k, tint: shot.tint } } });
  scheduleSave();
}

export async function requestPrint(): Promise<void> {
  wantedGen++;
  if (fullTimer) clearTimeout(fullTimer);
  if (get().tool === 'crop' && geometryInNegative(get().sidecar.params, get().gate, get().sidecar.noFilm)) return;
  if (inFlight) return;
  const sid = get().engineSession;
  if (!sid) return;
  foregroundWork();
  inFlight = true;
  let attemptedGen = wantedGen;
  try {
    for (;;) {
      const gen = wantedGen;
      attemptedGen = gen;
      resolveCurrentFilmEdge();
      const s = get();
      if (s.engineSession !== sid) return;
      if (s.tool === 'crop' && geometryInNegative(s.sidecar.params, s.gate, s.sidecar.noFilm)) return;
      const want = s.sidecar.params;
      if (s.pair && JSON.stringify(pairSnapshotFor(s.pair, want)) !== sentPair) {
        const snapshot = pairSnapshotFor(s.pair, want);
        const result = await host().updatePair(sid, snapshot, wireParams(want));
        if (get().engineSession !== sid) return;
        sentPair = JSON.stringify(pairWithMeterReadings(snapshot, snapshot, result.pair_info, want.autoExposureMethod));
        adoptPairMeterReadings(snapshot, result.pair_info, want.autoExposureMethod);
        sentParams = want;
        if (gen !== wantedGen) continue;
        set({ nativeSize: { width: result.width, height: result.height }, pairInfo: result.pair_info ?? null, metadata: result.metadata });
        lastOriginalKey = null;
        void refreshOriginal();
      }
      const d = sentParams ? paramsDelta(want, sentParams, s.gate, s.catalog) : { delta: wireParams(want), layers: new Set(['shoot']) };
      if (Object.keys(d.delta).length) {
        await host().setParams(sid, d.delta);
        sentParams = want;
      }
      const reprint = d.layers.size === 1 && d.layers.has('print');
      const r = await renderForView(sid, 'live', gen, reprint);
      if (get().engineSession !== sid) return;
      if (gen === wantedGen) {
        frameImages.print = r;
        set({ imageVersion: get().imageVersion + 1, badge: 'preview', status: '' });
        noteFirstViewCommitted(sid, r.width, r.height, r.ms);
      }
      if (gen === wantedGen) break;
    }
  } catch (e) {
    if (get().engineSession === sid && attemptedGen === wantedGen) noteError(tz('Render', '渲染'), e);
  } finally {
    inFlight = false;
    resumePreviewsWhenIdle();
    // An obsolete failure must neither overwrite the new frame's status nor
    // lose an edit which arrived while that failed request was in flight.
    if ((attemptedGen !== wantedGen || get().engineSession !== sid) && get().engineSession && !get().batchExporting)
      void requestPrint();
  }
  if (await resolvePendingPlacement()) return;
  scheduleFull();
}

function scheduleFull() {
  if (fullTimer) clearTimeout(fullTimer);
  // An export run renders the frame itself, at the file's own resolution.
  if (get().batchExporting) return;
  const gen = wantedGen;
  fullTimer = setTimeout(() => void renderFull(gen), FULL_DELAY_MS);
}

async function renderFull(gen: number) {
  const s = get();
  const sid = s.engineSession;
  if (!sid || inFlight || gen !== wantedGen || (s.tool === 'crop' && geometryInNegative(s.sidecar.params, s.gate, s.sidecar.noFilm))) return;
  const native = s.nativeSize;
  // A frame no larger than the preview edge is already at its own size.
  if (native && Math.max(native.width, native.height) <= previewEdge()) {
    set({ badge: 'full' });
    await refreshThumb();
    scheduleLatitudeRefresh();
    return;
  }
  inFlight = true;
  foregroundWork();
  try {
    const t0 = performance.now();
    const r = await renderForView(sid, 'full', gen);
    // Dropped when the generation, selection or session moved (ARCHITECTURE §7.3).
    if (gen !== wantedGen || get().engineSession !== sid) return;
    frameImages.print = r;
    platform().log('info', `session: full render ${r.width}x${r.height} landed in ${Math.round(performance.now() - t0)} ms`);
    set({ imageVersion: get().imageVersion + 1, badge: 'full' });
    await refreshThumb();
    scheduleLatitudeRefresh();
  } catch (e) {
    if (gen === wantedGen && get().engineSession === sid) noteError(tz('Full render', '全尺寸渲染'), e);
  } finally {
    inFlight = false;
    resumePreviewsWhenIdle();
    if (gen !== wantedGen) void requestPrint();
  }
}

async function refreshThumb() {
  const s = get();
  if (!s.selection || !frameImages.print) return;
  const gen = wantedGen;
  // The filmstrip expects the WHOLE photograph so it can apply orientation
  // and the crop mask once. A displayed render_view has already baked them.
  // Request a small uncropped view from the same GPU print cache instead of
  // copying/encoding a full-resolution image in the browser.
  const img = hostViews() && s.engineSession ? await host().renderView(s.engineSession, frameImages.print.tier, {
    ...(s.sidecar.noFilm ? { no_film: true } : {}),
    adjustments: s.sidecar.adjustments, geometry: GEOMETRY_DEFAULT,
    source_geometry: sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm) ?? GEOMETRY_DEFAULT,
    display: 'srgb', generation: gen, long_edge: THUMB_EDGE,
  }) : frameImages.print;
  if (gen !== wantedGen || get().selection !== s.selection) return;
  const url = await makeThumbFromPrint(img);
  if (url && gen === wantedGen && get().selection === s.selection) {
    thumbs.setPrint(s.selection, url, !!sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm));
    set({ thumbVersion: get().thumbVersion + 1 });
  } else if (url) URL.revokeObjectURL(url);
}

// -------------------------------------------------------------- persistence

function scheduleSave() {
  savePending = true;
  saveRevision++;
  if (saveTimer) clearTimeout(saveTimer);
  if (get().externalEditConflict) { saveTimer = null; return; }
  saveTimer = setTimeout(() => void flushSave(), 500);
}

export async function flushSave(): Promise<void> {
  await pairDecodeSave.catch(() => {});
  if (saveTask) await saveTask;
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  }
  if (!savePending || get().externalEditConflict) return;
  const s = get();
  if (!s.selection) return;
  const path = s.selection;
  const revision = saveRevision;
  saveTask = (async () => { try {
    await platform().sidecarSave(path, encodeSidecar(s.sidecar));
    if (get().selection === path) savedDocument = { path, content: sidecarContent(encodeSidecar(s.sidecar)) };
    if (s.pair) {
      const pair = encodePair(s.pair), value = JSON.stringify(pair);
      if (savedPair?.path !== path || savedPair.value !== value) {
        await platform().pairSave(path, pair);
        savedPair = { path, value };
      }
    }
    if (revision === saveRevision) savePending = false;
    set({ savedGeometry: { ...get().savedGeometry, [path]: s.sidecar.geometry } });
  } catch (e) {
    if (get().selection === s.selection && String(e).includes('EXTERNAL_EDIT_CONFLICT')) markExternalConflict();
    else noteError(tz('Saving settings', '保存设置'), e);
  } })();
  try { await saveTask; } finally { saveTask = null; }
}

function markExternalConflict() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = null;
  const message = tz('This photo was edited externally. Your current edits are kept; automatic saving is paused. Reload to use the saved external edits.',
    '这张照片已被外部修改。当前编辑已保留，自动保存已暂停；重新加载可使用外部保存的设置。');
  set({ externalEditConflict: true, status: message, lastError: message });
}

const journalPath = (path: string) => /^[a-z]:[\\/]/i.test(path) ? path.replaceAll('\\', '/').toLowerCase() : path.replaceAll('\\', '/');
function sidecarContent(raw: unknown): string {
  const value = encodeSidecar(decodeSidecar(raw));
  delete value._spkRevision; delete value.source;
  const sorted = (v: unknown): unknown => Array.isArray(v) ? v.map(sorted) : v && typeof v === 'object'
    ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => a.localeCompare(b)).map(([k, item]) => [k, sorted(item)])) : v;
  return JSON.stringify(sorted(value));
}
function currentHasExternalChange() {
  const s = get();
  return [s.selection, s.pair?.left?.path, s.pair?.right?.path].some((p) => p && pendingExternalPaths.has(journalPath(p)));
}

/** The journal is a notification only. Save safety comes from the revision
 * token carried by each Sidecar.raw snapshot, not from polling timing. */
export async function pollAgentChanges(): Promise<void> {
  if (agentPolling) return;
  agentPolling = true;
  try {
    const journal = await platform().agentChanges();
    if (agentRevision === undefined) { agentRevision = journal?.revision ?? ''; return; }
    if (journal && journal.revision !== agentRevision) {
      agentRevision = journal.revision;
      for (const path of journal.paths) pendingExternalPaths.add(journalPath(path));
      const s = get(), geometry = { ...s.savedGeometry };
      if (journal.all && s.selection) {
        // A burst can exceed the journal's bounded path list. Compare the
        // saved snapshots, including both pair sources, before reloading.
        const baseline = savedDocument?.path === s.selection ? savedDocument.content : sidecarContent(encodeSidecar(s.sidecar));
        const raw = await platform().sidecarLoad(s.selection);
        if (sidecarContent(raw) !== baseline) pendingExternalPaths.add(journalPath(s.selection));
        if (s.pair) {
          const diskPair = decodePair(await platform().pairLoad(s.selection));
          if (!diskPair || JSON.stringify(encodePair(diskPair)) !== savedPair?.value) pendingExternalPaths.add(journalPath(s.selection));
          for (const side of PAIR_SIDES) {
            const hole = s.pair[side]; if (!hole) continue;
            const source = pairSourceSidecars.get(hole.path);
            const disk = await platform().sidecarLoad(hole.path);
            if (!source || sidecarContent(disk) !== sidecarContent(encodeSidecar(source))) pendingExternalPaths.add(journalPath(hole.path));
          }
        }
      }
      if (get().selection !== s.selection || get().frames !== s.frames) return;
      for (const frame of s.frames) {
        // Any source change can affect an unopened pair's thumbnail.
        if (!journal.all && !pendingExternalPaths.has(journalPath(frame.path)) && !isPairPath(frame.path)) continue;
        thumbs.invalidate(frame.path); delete geometry[frame.path];
        if (frame.path !== s.selection) void platform().sidecarLoad(frame.path).then((raw) => {
          if (get().selection !== frame.path && get().frames.some((f) => f.path === frame.path) && raw)
            set({ savedGeometry: { ...get().savedGeometry, [frame.path]: decodeSidecar(raw).geometry } });
        }).catch(() => {});
      }
      set({ savedGeometry: geometry, thumbVersion: get().thumbVersion + 1 });
    }
    if (!currentHasExternalChange()) return;
    const s = get();
    if (s.externalEditConflict) return;
    if (savePending || saveTask) { markExternalConflict(); return; }
    if (!s.selection || s.batchExporting || s.developing || s.redecoding || s.exportOpen || s.tool !== 'select'
      || s.pairPlacing || inFlight || originalInFlight || decodeTimer || pairTimer || placementTask !== null) return;
    await select(s.selection, { externalReload: true });
  } catch (e) {
    platform().log('warn', `external edits: ${String(e)}`);
  } finally { agentPolling = false; }
}

export async function reloadExternalEdits(): Promise<void> {
  const s = get();
  if (!s.selection || s.batchExporting || s.developing || s.redecoding) return;
  if (s.externalEditConflict && !await platform().confirm(tz('Reload external edits', '重新加载外部编辑'),
    tz('Reload the saved version? This discards the unsaved edits currently shown for this photo.', '重新加载已保存的版本？这会丢弃这张照片当前未保存的编辑。'))) return;
  if (get().selection !== s.selection || get().sidecar !== s.sidecar || get().pair !== s.pair) return;
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = null; savePending = false;
  await select(s.selection, { externalReload: true });
}

function pushUndo() {
  const now = performance.now();
  if (now - lastUndoAt < 500) return;
  lastUndoAt = now;
  const sc = get().sidecar;
  const undo = [...get().undo, { noFilm: sc.noFilm, params: sc.params, adjustments: sc.adjustments, geometry: sc.geometry, heldCrop: sc.heldCrop, pair: get().pair, decode: sc.decode, placementNeedsFit: sc.placementNeedsFit }].slice(-60);
  set({ undo, redo: [] });
}

/**
 * A positive has no paper stage (`Session.applyFilmStageRule` on the Mac).
 * Keep the paper choice, and leave negatives alone: scanning a negative
 * without paper is an explicit option too. This is session policy, not an
 * engine restriction on experiments with positive-to-paper rendering.
 */
function filmStageParams(p: FilmParams): FilmParams {
  return normalizeStockPair(p, get().catalog);
}

/** Resolve metadata only for the currently opened source, never while loading
 * a new sidecar with the previous photo's metadata still in the store. */
function resolveCurrentFilmEdge() {
  const s = get();
  if (!s.nativeSize) return;
  let sc = s.sidecar;
  if (!s.pair && edgeEffective(sc.params.filmEdge, s.gate)) {
    const geometry = gateFramed(sc.geometry, sc.params.filmEdge, s.nativeSize);
    if (!jsonEqual(geometry, sc.geometry)) sc = { ...sc, geometry, heldCrop: sc.heldCrop ?? sc.geometry };
  }
  const params = s.pair ? resolvePairParams(sc.params, s.pair, s.pairInfo?.left?.metadata ?? s.metadata, s.pairInfo?.right?.metadata ?? null, s.catalog)
    : resolveFilmEdgeParams(sc.params, sc.geometry, s.metadata, s.catalog, s.nativeSize);
  if (!jsonEqual(params, sc.params)) sc = { ...sc, params };
  if (sc !== s.sidecar) { set({ sidecar: sc }); scheduleSave(); }
}

function edgeTransition(sc: Sidecar, next: FilmParams): Sidecar {
  const s = get(), was = edgeEffective(sc.params.filmEdge, s.gate), now = edgeEffective(next.filmEdge, s.gate);
  let geometry = sc.geometry, heldCrop = sc.heldCrop;
  if (next.filmEdge.cameraSeed !== sc.params.filmEdge.cameraSeed) settingsStore.getState().set('filmEdgeBodySeed', next.filmEdge.cameraSeed);
  if (s.pair) {
    if (s.pair.onStrip !== now) set({ pair: { ...s.pair, onStrip: now } });
    return { ...sc, params: { ...next, filmEdge: { ...next.filmEdge, format: '135_half', pair: true } }, geometry: GEOMETRY_DEFAULT, heldCrop: null };
  }
  if (!was && now) heldCrop = geometry;
  if (was && !now) { geometry = heldCrop ?? { ...geometry, lockedRatio: null }; heldCrop = null; }
  if (now && s.nativeSize && (!was || next.filmEdge.format !== sc.params.filmEdge.format)) geometry = gateFramed(geometry, next.filmEdge, s.nativeSize);
  return { ...sc, params: next, geometry, heldCrop, state: sc.state === 'processed' ? 'stale' : sc.state };
}

function randomSeed(max = 2147483647) { return (crypto.getRandomValues(new Uint32Array(1))[0]! % max) + 1; }
export function changeFilmBody() { setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, cameraSeed: randomSeed(999) } })); }
export function advanceFilm() { setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, frameSeed: randomSeed() } })); }
export function flipFilmGate() {
  const s = get();
  if (s.nativeSize && edgeEffective(s.sidecar.params.filmEdge, s.gate))
    setGeometry((g) => gateFramed(g, s.sidecar.params.filmEdge, s.nativeSize!, (g.lockedRatio ?? 1) < 1));
}
async function seedFilmEdge(path: string, gen: number) {
  if (get().sidecar.params.filmEdge.seeded) return;
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(path.replaceAll('\\', '/'))));
  if (gen !== openGen || get().selection !== path) return;
  const s = get(), f = s.sidecar.params.filmEdge;
  if (f.seeded) return;
  let body = settingsStore.getState().filmEdgeBodySeed;
  if (!body) { body = randomSeed(999); settingsStore.getState().set('filmEdgeBodySeed', body); }
  const index = s.frames.findIndex((v) => v.path === path);
  const frameSeed = new DataView(digest.buffer).getUint32(0, false) & 0x7fffffff;
  set({ sidecar: { ...s.sidecar, params: { ...s.sidecar.params, filmEdge: { ...f, seeded: true, cameraSeed: body, frameSeed, frameNumber: index < 0 ? 0 : index % 99 + 1 } } } });
  scheduleSave();
}

function filmStageSidecar(sc: Sidecar): Sidecar {
  let params = filmStageParams(sc.params);
  if (sc.placementNeedsFit) {
    const intent = placementIntent(params.sceneLatitude);
    if (!jsonEqual(intent, params.sceneLatitude)) params = { ...params, sceneLatitude: intent };
  }
  return params === sc.params ? sc : { ...sc, params, state: sc.state === 'processed' ? 'stale' : sc.state };
}

/** The single door for a Layer 1 edit. */
export function setParams(fn: (p: FilmParams) => FilmParams) {
  const s = get();
  if (s.batchExporting) return;
  const next = filmStageParams(fn(s.sidecar.params));
  if (jsonEqual(next, s.sidecar.params)) return;
  pushUndo();
  set({ sidecar: edgeTransition(get().sidecar, next) });
  resolveCurrentFilmEdge();
  if (sourceGeometryFor(get().sidecar.params, get().sidecar.geometry, s.gate, get().sidecar.noFilm)) set({ showingOriginal: false, comparing: false });
  scheduleSave();
  void requestPrint();
}

/** A stock pick starts its normal viewing stage: slides scan, negatives print.
 * Unlike restoring/pasting explicit settings, it must not inherit a slide's
 * scanFilm flag. Re-picking a negative also repairs an old saved direct scan.
 * Manual no-paper selection remains available until the next stock pick.
 */
export function selectFilmStock(filmStock: string) {
  const s = get();
  if (s.batchExporting) return;
  // Stock picks are discrete edits, not a slider gesture to coalesce.
  lastUndoAt = -Infinity;
  if (s.sidecar.noFilm) {
    pushUndo();
    set({ sidecar: { ...s.sidecar, noFilm: false } });
    discardModePreview();
  }
  const catalog = get().catalog;
  const target = catalog.stock(filmStock)?.targetPrint;
  setParams((p) => ({ ...p, filmStock, scanFilm: catalog.isPositive(filmStock),
    // A stock click follows its declared paper; restoring saved settings only
    // repairs incompatible pairs and preserves a user's valid custom paper.
    printStock: target && catalog.stock(target) ? target : p.printStock,
  }));
  // Re-picking the same film still exits bypass, even if its params match.
  if (s.sidecar.noFilm) { scheduleSave(); void requestPrint(); }
}

/** The source choice is a frame edit, never a copied film parameter. */
export function toggleNoFilm() {
  const s = get();
  if (!s.selection || s.batchExporting || s.pair || (!s.sidecar.noFilm && !s.gate.noFilm)) return;
  lastUndoAt = -Infinity;
  pushUndo();
  set({ sidecar: { ...s.sidecar, noFilm: !s.sidecar.noFilm } });
  discardModePreview();
  scheduleSave();
  void requestPrint();
}

function discardModePreview() {
  // A film canvas may include a baked gate/crop. Never reinterpret those
  // pixels using the bypass geometry while its replacement is in flight.
  frameImages.print = null;
  const s = get();
  if (s.selection) thumbs.invalidate(s.selection);
  clearLatitude();
  set({ imageVersion: s.imageVersion + 1, thumbVersion: s.thumbVersion + 1, badge: null,
    showingOriginal: false, comparing: false, view: { ...s.view, fit: true, cx: .5, cy: .5 } });
}

/** Guard the action as well as the paper row: shortcuts and future callers
 * cannot send a silver/colour mismatch around the disabled picker. */
export function selectPrintStock(printStock: string) {
  const { catalog, sidecar } = get();
  if (catalog.isPositive(sidecar.params.filmStock) || !catalog.canPrint(sidecar.params.filmStock, printStock)) return;
  lastUndoAt = 0;
  setParams((p) => ({ ...p, printStock, scanFilm: false, digitalIntermediate: false }));
}

/** A Layer 2 edit: reuse the GPU print cache and update the display output. */
export function setAdjustments(fn: (a: Adjustments) => Adjustments) {
  const s = get();
  if (s.pair && s.pairLayer !== 'film' && s.pair[s.pairLayer]) {
    const side = s.pairLayer, next = fn(shownAdjustments(s));
    updatePair((p) => ({ ...p, [side]: { ...p[side]!, adjustments: next } })); return;
  }
  const next = fn(s.sidecar.adjustments);
  if (jsonEqual(next, s.sidecar.adjustments)) return;
  pushUndo();
  set({ sidecar: { ...s.sidecar, adjustments: next } });
  scheduleSave();
  if (hostViews() && !s.batchExporting) void requestPrint();
}

/** Draft crop edits draw locally; committed geometry refreshes the GPU view. */
export function setGeometry(fn: (g: Geometry) => Geometry, opts: { coalesce?: boolean } = {}) {
  const s = get();
  if (s.pair) return; // a pair's holes are placed independently
  let next = fn(s.sidecar.geometry);
  if (s.nativeSize && edgeEffective(s.sidecar.params.filmEdge, s.gate)) next = gateFramed(next, s.sidecar.params.filmEdge, s.nativeSize, (next.lockedRatio ?? 1) >= 1);
  if (jsonEqual(next, s.sidecar.geometry)) return;
  if (!opts.coalesce) pushUndo();
  set({ sidecar: { ...s.sidecar, geometry: next }, savedGeometry: s.selection ? { ...s.savedGeometry, [s.selection]: next } : s.savedGeometry });
  scheduleSave();
  resolveCurrentFilmEdge();
  if (settingsStore.getState().recalculateEffectsAfterCrop) recomputeFilmFormat();
  if (hostViews() && get().tool !== 'crop' && !get().batchExporting) void requestPrint();
}

/**
 * A decode edit (camera white balance): the host decodes the file again
 * (`redecode`, R2) and the frame re-renders with the same params. Debounced:
 * a decode is the slow part of an open, so a drag decodes once it settles.
 */
export function setDecode(fn: (d: DecodeSettings) => DecodeSettings) {
  const s = get();
  if (s.batchExporting) return;
  if (s.pair) { void setPairDecode(fn); return; }
  const next = fn(s.sidecar.decode);
  if (jsonEqual(next, s.sidecar.decode)) return;
  pushUndo();
  set({ sidecar: { ...get().sidecar, decode: next, state: get().sidecar.state === 'processed' ? 'stale' : get().sidecar.state } });
  scheduleSave();
  scheduleRedecode();
}

/** Whether this host can re-decode (it lists `redecode` in `hello.methods`). */
export function hostRedecodes(methods: readonly string[] | undefined): boolean {
  return !!methods?.includes('redecode');
}

let decodeTimer: ReturnType<typeof setTimeout> | null = null;
/** The wire decode the engine session was last decoded with. */
let sentDecode: string | null = null;
const REDECODE_DELAY_MS = 350;

function scheduleRedecode() {
  foregroundWork();
  if (decodeTimer) clearTimeout(decodeTimer);
  // Whatever full render was coming would show the old decode.
  if (fullTimer) clearTimeout(fullTimer);
  wantedGen++;
  originalGeneration++;
  neutralPickGeneration++;
  decodeTimer = setTimeout(() => void redecodeNow(), REDECODE_DELAY_MS);
}

async function redecodeNow() {
  decodeTimer = null;
  const s = get();
  const sid = s.engineSession;
  if (!sid || !s.selection) { resumePreviewsWhenIdle(); return; }
  const wire = decodeWire(s.sidecar.decode, isRawFrame());
  const key = JSON.stringify(wire);
  if (!wire || key === sentDecode || !hostRedecodes(s.hello?.methods)) {
    void requestPrint();
    return;
  }
  set({ redecoding: true, status: tz('Decoding with the new white balance…', '正在以新的白平衡解码…') });
  clearLatitude();
  try {
    const r = await host().redecode(sid, wire);
    if (get().engineSession !== sid) return;
    sentDecode = key;
    set({ nativeSize: { width: r.width, height: r.height }, metadata: r.metadata ?? get().metadata, status: '' });
    lastOriginalKey = null;
    void requestPrint();
  } catch (e) {
    noteError(tz('White balance', '白平衡'), e);
  } finally {
    set({ redecoding: false });
    void refreshOriginal();
    resumePreviewsWhenIdle();
  }
}

function isRawFrame(): boolean {
  const s = get();
  if (s.frameKind) return s.frameKind === 'raw';
  return !!s.selection && isRawPath(s.selection);
}

export function beginGesture() {
  // A new drag/key action is an undo boundary even when it follows a prior
  // gesture quickly; updates within this gesture still coalesce normally.
  lastUndoAt = -Infinity;
  pushUndo();
  lastUndoAt = performance.now();
}

function restore(e: UndoEntry) {
  const s = get();
  const decodeMoved = !jsonEqual(e.decode, s.sidecar.decode);
  const noFilm = e.noFilm ?? false;
  set({ pair: e.pair ?? null, sidecar: filmStageSidecar({ ...s.sidecar, noFilm, params: e.params, adjustments: e.adjustments, geometry: e.geometry, heldCrop: e.heldCrop ?? null, decode: e.decode, placementNeedsFit: e.placementNeedsFit ?? false }) });
  if (noFilm !== s.sidecar.noFilm) discardModePreview();
  for (const side of PAIR_SIDES) {
    const hole = e.pair?.[side];
    if (hole && !jsonEqual(hole.decode, s.pair?.[side]?.decode))
      void savePairDecode(hole.path, hole.decode).catch((e) => noteError(tz('Pair white balance', '半格白平衡'), e));
  }
  scheduleSave();
  if (decodeMoved && !get().pair) scheduleRedecode();
  else void requestPrint();
}

export function undo() {
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const prev = s.undo[s.undo.length - 1];
  if (!prev) return;
  const cur = { noFilm: s.sidecar.noFilm, params: s.sidecar.params, adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry, heldCrop: s.sidecar.heldCrop, pair: s.pair, decode: s.sidecar.decode, placementNeedsFit: s.sidecar.placementNeedsFit };
  set({ undo: s.undo.slice(0, -1), redo: [...s.redo, cur] });
  lastUndoAt = 0;
  restore(prev);
  set({ status: tz(`Undo — ${get().undo.length} steps left.`, `撤销 — 还剩 ${get().undo.length} 步。`) });
}

export function redo() {
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const next = s.redo[s.redo.length - 1];
  if (!next) return;
  const cur = { noFilm: s.sidecar.noFilm, params: s.sidecar.params, adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry, heldCrop: s.sidecar.heldCrop, pair: s.pair, decode: s.sidecar.decode, placementNeedsFit: s.sidecar.placementNeedsFit };
  set({ redo: s.redo.slice(0, -1), undo: [...s.undo, cur] });
  lastUndoAt = 0;
  restore(next);
}

// -------------------------------------------------------- scene placement

/** The measured scene is independent of its applied placement. Keep it while
 * a knob moves, but never fit a new stock/exposure/decode against old data. */
function latitudeStamp(p: FilmParams): string {
  const { sceneLatitude, ...rest } = p;
  return JSON.stringify({ ...rest, norm: sceneLatitude.norm, shadowPercentile: sceneLatitude.shadowPercentile,
    highlightPercentile: sceneLatitude.highlightPercentile, decode: get().sidecar.decode,
    sourceGeometry: sourceGeometryFor(p, get().sidecar.geometry, get().gate), pair: get().pair });
}

function clearLatitude() {
  if (latitudeTimer) clearTimeout(latitudeTimer);
  latitudeTimer = null;
  latitudeGeneration++;
  placementTaskGeneration++;
  placementTask = null;
  set({ latitude: EMPTY_LATITUDE });
}

function canMeasureLatitude(): boolean {
  const s = get();
  return !s.sidecar.noFilm && !!s.engineSession && !!s.selection && !s.batchExporting && !s.redecoding && !decodeTimer && !pairTimer && !inFlight
    && !(s.tool === 'crop' && geometryInNegative(s.sidecar.params, s.gate))
    && !!s.hello?.methods?.includes('scene_latitude');
}

/** Exposed for diagnostics/tests too; refuses to let a stale RPC replace a
 * newer frame, decode or edit. A probe never commits a parameter. */
export async function refreshLatitude(): Promise<LatitudeReply | null> {
  if (!canMeasureLatitude()) return null;
  const s = get(), sid = s.engineSession!, frame = s.selection!;
  const params = JSON.stringify(s.sidecar.params), stamp = latitudeStamp(s.sidecar.params);
  const gen = ++latitudeGeneration;
  const current = () => gen === latitudeGeneration && get().engineSession === sid && get().selection === frame
    && JSON.stringify(get().sidecar.params) === params && latitudeStamp(get().sidecar.params) === stamp;
  try {
    const reply = await host().sceneLatitude(sid, { ...latitudeRequest(s.sidecar.params.sceneLatitude),
      ...(s.pair ? { region: pairFitRegion(s.pair, s.sidecar.params.placementIsRight) } : {}),
    }, {
      params: wireParams(s.sidecar.params),
      source_geometry: sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate) ?? GEOMETRY_DEFAULT,
    }) as unknown as LatitudeReply;
    if (!current()) return null;
    if (!measuredFromReply(reply) || !reply.medium || !Array.isArray(reply.scene?.histogram?.fractions))
      throw new Error(tz('The engine returned an incomplete latitude measurement.', '引擎返回的宽容度测量不完整。'));
    set({ latitude: { ...get().latitude, reply, session: sid, frame, stamp, failure: null } });
    return reply;
  } catch (e) {
    if (!current()) return null;
    const text = e instanceof Error ? e.message : String(e);
    const failure = text.includes('boundaries do not lie inside')
      ? tz('This film/paper pair has no measurable latitude inside the probe range.', '此胶片与相纸组合的宽容度超出测量范围。')
      : text.includes('no positive pixels') ? tz('This frame contains no positive light to measure.', '此照片没有可测量的正光照像素。') : text;
    set({ latitude: { ...get().latitude, reply: null, session: sid, frame, stamp, failure } });
    return null;
  }
}

function scheduleLatitudeRefresh() {
  if (latitudeTimer) clearTimeout(latitudeTimer);
  latitudeTimer = setTimeout(() => {
    latitudeTimer = null;
    void (async () => { if (!await resolvePendingPlacement()) await refreshLatitude(); })();
  }, 250);
}

export function placementReady(): boolean {
  const s = get(), l = s.latitude;
  return !s.sidecar.noFilm && !!s.gate.sceneLatitude && !s.batchExporting && !s.redecoding && !decodeTimer
    && !(s.sidecar.params.digitalIntermediate && !s.sidecar.params.scanFilm)
    && l.session === s.engineSession && l.frame === s.selection && l.stamp === latitudeStamp(s.sidecar.params)
    && measuredFromReply(l.reply) !== null;
}

export function currentPlacementWindow(side: PlacementSide): PlacementWindow | null {
  if (!placementReady()) return null;
  const s = get(), base = s.sidecar.params.sceneLatitude;
  return placementWindow(measuredFromReply(s.latitude.reply)!, side,
    side === 'highlight' ? base.shadowPullBack : base.highlightPullBack, base);
}

export function resetScenePlacement() {
  const s = get();
  if (s.batchExporting || !s.gate.sceneLatitude) return;
  if (s.sidecar.placementNeedsFit) pushUndo();
  set({ sidecar: { ...s.sidecar, placementNeedsFit: false }, latitude: { ...s.latitude, refusal: null } });
  setParams((p) => ({ ...p, sceneLatitude: { ...SCENE_LATITUDE_DEFAULT } }));
  scheduleSave();
}

export function placeScene(side: PlacementSide, value: number) {
  if (!Number.isFinite(value) || !placementReady()) return;
  const s = get(), base = s.sidecar.params.sceneLatitude;
  const landed = placementLanding(currentPlacementWindow(side)!, Math.max(0, value));
  const h = side === 'highlight' ? landed.value : base.highlightPullBack;
  const sh = side === 'shadow' ? landed.value : base.shadowPullBack;
  if (h === 0 && sh === 0) {
    resetScenePlacement();
    set({ latitude: { ...get().latitude, refusal: landed.issue } });
    return;
  }
  const result = fitPlacement(measuredFromReply(s.latitude.reply)!, h, sh, base);
  if (result.issue) { set({ latitude: { ...s.latitude, refusal: result.issue } }); return; }
  if (s.sidecar.placementNeedsFit) pushUndo();
  set({ sidecar: { ...s.sidecar, placementNeedsFit: false }, latitude: { ...s.latitude, refusal: landed.issue } });
  setParams((p) => ({ ...p, sceneLatitude: result.placed }));
}

async function resolvePendingPlacement(): Promise<boolean> {
  const s = get();
  if (!s.sidecar.placementNeedsFit || !s.gate.sceneLatitude || placementTask !== null || !canMeasureLatitude()
    || (s.sidecar.params.digitalIntermediate && !s.sidecar.params.scanFilm)) return false;
  const token = ++placementTaskGeneration;
  placementTask = token;
  const sid = s.engineSession, frame = s.selection, want = s.sidecar.params.sceneLatitude;
  const params = JSON.stringify(s.sidecar.params), stamp = latitudeStamp(s.sidecar.params);
  try {
    const reply = await refreshLatitude();
    const now = get();
    if (token !== placementTaskGeneration || now.engineSession !== sid || now.selection !== frame
      || !now.sidecar.placementNeedsFit || JSON.stringify(now.sidecar.params) !== params
      || latitudeStamp(now.sidecar.params) !== stamp) return false;
    // An obsolete probe is neither a refusal nor permission to discard intent.
    if (!reply && !now.latitude.failure) return false;
    const placed = reply ? applyLatitudeFit(want, reply.fit) : null;
    const resolved = placed ?? { ...placementIntent(want), highlightPullBack: 0, shadowPullBack: 0 };
    const refusal = placed ? null : reply?.fit.issues[0] ?? { code: 'measurement_failed', side: 'both',
      message: now.latitude.failure ?? tz('The placement could not be fitted.', '场景置位无法拟合。') };
    // This is the second half of Paste, not a new undo step. The existing undo
    // snapshot and the target's sidecar stay authoritative throughout the RPC.
    set({ sidecar: { ...now.sidecar, params: { ...now.sidecar.params, sceneLatitude: resolved }, placementNeedsFit: false },
      latitude: { ...now.latitude, refusal } });
    scheduleSave();
    void requestPrint();
    return true;
  } finally {
    if (placementTask === token) placementTask = null;
  }
}

// ------------------------------------------------------------ film format

function aspectOf(): number {
  const n = get().nativeSize;
  if (!n) return 1.5;
  const g = get().sidecar.geometry;
  if (settingsStore.getState().recalculateEffectsAfterCrop) {
    const o = outputSize(g, n);
    return Math.max(o.width, o.height) / Math.min(o.width, o.height);
  }
  return Math.max(n.width, n.height) / Math.max(1, Math.min(n.width, n.height));
}

function cropScale(): number {
  if (!settingsStore.getState().recalculateEffectsAfterCrop) return 1;
  const c = get().sidecar.geometry.crop;
  return 1 / Math.max(Math.max(c.width, c.height), 1e-3);
}

function derived(side: FilmSide, mm: number) {
  if (get().pair) return pairFilmFormat({ ...get().sidecar.params, filmSide: side, sideLengthMM: mm }, get().pair!);
  return filmFormatMM(side, mm, aspectOf(), cropScale());
}

// -------------------------------------------------------------- half frames

export function canMakePair(): boolean {
  const s = get();
  return !s.batchExporting && !!s.hello?.methods?.includes('open_pair') && !!s.hello?.methods?.includes('update_pair')
    && s.frames.some((f) => !isPairPath(f.path));
}
export async function makePair(enter = false) {
  if (!canMakePair()) return;
  await flushSave();
  if (get().externalEditConflict) return;
  const s = get(), picked = enter && s.selection ? [s.selection] : s.frames.filter((f) => s.picked.includes(f.path) && !isPairPath(f.path)).slice(0, 2).map((f) => f.path);
  const anchor = picked[0] ?? s.frames.find((f) => !isPairPath(f.path))?.path;
  if (!anchor) return;
  try {
    const hole = async (path: string) => {
      const raw = path === s.selection ? encodeSidecar(s.sidecar) : await platform().sidecarLoad(path);
      const own = raw ? decodeSidecar(raw) : newSidecar();
      return { ...newHole(path), decode: own.decode, geometry: own.geometry };
    };
    const ownRaw = anchor === s.selection ? encodeSidecar(s.sidecar) : await platform().sidecarLoad(anchor);
    const own = ownRaw ? decodeSidecar(ownRaw) : newSidecar();
    const size = anchor === s.selection ? s.nativeSize : await host().probe(anchor).then((r) => ({ width: r.width, height: r.height })).catch(() => null);
    const pair = { ...newPair(dirName(anchor)), left: picked[0] ? await hole(picked[0]) : null, right: picked[1] ? await hole(picked[1]) : null,
      turned: size ? outputSize(own.geometry, size).width > outputSize(own.geometry, size).height : false,
      onStrip: enter && edgeEffective(own.params.filmEdge, s.gate) };
    const sidecar: Sidecar = { ...newSidecar(), state: 'stale', params: { ...own.params, autoExposure: false, exposureCompensationEV: 0,
      filmFrame: FILM_FRAME_CUSTOM.id, filmSide: 'long', sideLengthMM: 24,
      filmEdge: { ...(enter ? own.params.filmEdge : newSidecar().params.filmEdge), pair: true, format: '135_half', seeded: false },
      dateBack: { ...own.params.dateBack, textB: '' }, sceneLatitude: { ...SCENE_LATITUDE_DEFAULT }, sceneLatitudeOther: { ...SCENE_LATITUDE_DEFAULT }, placementIsRight: false,
    } };
    sidecar.params = resolvePairParams(sidecar.params, pair, null, null, s.catalog);
    const entry = await platform().pairCreate(pair.folder, encodePair(pair));
    await platform().sidecarSave(entry.path, encodeSidecar(sidecar));
    if (get().selection !== s.selection || get().folder !== s.folder) return;
    const frames = [...get().frames], at = frames.findIndex((f) => f.path === anchor);
    frames.splice(at < 0 ? frames.length : at + 1, 0, entry);
    set({ frames, picked: [entry.path] }); saveFrameOrder();
    await select(entry.path);
    if (get().selection === entry.path && pair.left && !pair.right) setPairLayer('right');
  } catch (e) { noteError(tz('Creating half-frame pair', '创建半格拼接'), e); }
}

function adoptPairMeterReadings(requested: HalfFramePair, info: PairInfo | undefined, requestedMethod: FilmParams['autoExposureMethod']) {
  const s = get(); if (!s.pair) return;
  const pair = pairWithMeterReadings(s.pair, requested, info, s.sidecar.params.autoExposureMethod, requestedMethod);
  if (pair !== s.pair) { set({ pair }); scheduleSave(); }
}

export function updatePair(fn: (pair: HalfFramePair) => HalfFramePair, opts: { step?: boolean; defer?: boolean; params?: FilmParams; coalesce?: boolean } = {}) {
  const s = get(); if (!s.pair || s.batchExporting) return;
  const next = decodePair(encodePair(fn(s.pair)));
  if (!next || (jsonEqual(next, s.pair) && (!opts.params || jsonEqual(opts.params, s.sidecar.params)))) return;
  if (opts.step) lastUndoAt = 0;
  // Canvas pointer-down owns the undo boundary for the whole gesture, even
  // when its moves span more than the ordinary 500 ms edit debounce.
  if (!opts.coalesce) pushUndo();
  set({ pair: next, sidecar: { ...s.sidecar, params: opts.params ?? s.sidecar.params, state: 'stale' } });
  resolveCurrentFilmEdge(); scheduleSave();
  wantedGen++; // any older render is obsolete, including during the debounce
  if (fullTimer) clearTimeout(fullTimer);
  if (pairTimer) clearTimeout(pairTimer);
  if (opts.defer) pairTimer = setTimeout(() => { pairTimer = null; void requestPrint(); }, 280);
  else void requestPrint();
}
export function setPairLayer(pairLayer: PairLayer) {
  const s = get(); if (!s.pair || s.pairLayer === pairLayer) return;
  if (s.tool === 'neutral') setTool('select');
  set({ pairLayer, pairPlacing: false });
  if (pairLayer !== 'film' && s.sidecar.params.placementIsRight !== (pairLayer === 'right')) {
    const p = s.sidecar.params;
    set({ sidecar: { ...s.sidecar, params: { ...p, sceneLatitude: p.sceneLatitudeOther, sceneLatitudeOther: p.sceneLatitude, placementIsRight: pairLayer === 'right' } } });
    scheduleSave(); scheduleLatitudeRefresh(); // only the selected UI curve changes; the wire stays identical
  }
}
export function pairFocus(s = get()): PairSide | null {
  if (!s.pair) return null;
  const preferred = s.pairLayer === 'film' ? s.sidecar.params.placementIsRight ? 'right' : 'left' : s.pairLayer;
  return s.pair[preferred] ? preferred : PAIR_SIDES.find((side) => s.pair![side]) ?? null;
}
export function shownAdjustments(s: SessionState): Adjustments {
  return s.pair && s.pairLayer !== 'film' ? s.pair[s.pairLayer]?.adjustments ?? s.sidecar.adjustments : s.sidecar.adjustments;
}
export function shownDecode(s: SessionState): DecodeSettings {
  const side = pairFocus(s); return side ? s.pair![side]!.decode : s.sidecar.decode;
}
export function cameraParams(s: SessionState): FilmParams {
  const side = pairFocus(s), hole = side ? s.pair![side] : null;
  return hole ? { ...s.sidecar.params, exposureCompensationEV: hole.exposureEV, autoExposure: hole.autoExposure,
    autoExposureMethod: hole.meterMethod ?? s.sidecar.params.autoExposureMethod } : s.sidecar.params;
}
export function setCamera(fn: (p: FilmParams) => FilmParams) {
  const s = get(), side = pairFocus(s);
  if (!s.pair || !side) { setParams(fn); return; }
  const before = cameraParams(s), next = fn(before), hole = s.pair[side]!;
  let params = s.sidecar.params; let pair = s.pair;
  if (next.exposureCompensationEV !== hole.exposureEV && hole.exposureScope === 'film') {
    const print = printTrim(params);
    for (const other of PAIR_SIDES) if (pair[other] && !pair[other]!.print) pair = { ...pair, [other]: { ...pair[other]!, print } };
    params = { ...params, printBrightnessStops: clamp(params.printBrightnessStops + next.exposureCompensationEV - hole.exposureEV, -3, 3) };
  }
  pair = { ...pair, [side]: { ...pair[side]!, exposureEV: clamp(next.exposureCompensationEV, -5, 5), autoExposure: next.autoExposure, meterMethod: next.autoExposureMethod } };
  updatePair(() => pair, { params, defer: true });
}
export function enlargerParams(s: SessionState): FilmParams {
  const own = s.pair && s.pairLayer !== 'film' ? s.pair[s.pairLayer]?.print : null;
  return own ? { ...s.sidecar.params, printBrightnessStops: own.brightnessStops, yFilterShift: own.yFilterShift,
    mFilterShift: own.mFilterShift, preflashExposure: own.preflashExposure } : s.sidecar.params;
}
export function setEnlarger(fn: (p: FilmParams) => FilmParams) {
  const s = get(); if (!s.pair) { setParams(fn); return; }
  const before = enlargerParams(s), next = fn(before), film = printTrim(s.sidecar.params);
  const changes = (['printBrightnessStops', 'yFilterShift', 'mFilterShift', 'preflashExposure'] as const).filter((k) => next[k] !== before[k]);
  if (!changes.length) return;
  const ownKey = { printBrightnessStops: 'brightnessStops', yFilterShift: 'yFilterShift', mFilterShift: 'mFilterShift', preflashExposure: 'preflashExposure' } as const;
  const bounded = (key: typeof changes[number], value: number) => key === 'printBrightnessStops' ? clamp(value, -3, 3) : key === 'preflashExposure' ? clamp(value, 0, .03) : clamp(value, -1, 1);
  let pair = s.pair, params = s.sidecar.params;
  const side = s.pairLayer !== 'film' && pair[s.pairLayer] ? s.pairLayer : null;
  if (side) {
    for (const other of PAIR_SIDES) if (pair[other] && !pair[other]!.print) pair = { ...pair, [other]: { ...pair[other]!, print: film } };
    let print = { ...pair[side]!.print! };
    for (const key of changes) {
      print = { ...print, [ownKey[key]]: bounded(key, next[key]) };
      if (pair[side]!.printScope === 'film') params = { ...params, [key]: bounded(key, params[key] + next[key] - before[key]) };
    }
    pair = { ...pair, [side]: { ...pair[side]!, print } };
  } else {
    for (const key of changes) {
      const moved = next[key] - before[key]; params = { ...params, [key]: bounded(key, next[key]) };
      for (const other of PAIR_SIDES) if (pair[other]?.print) pair = { ...pair, [other]: { ...pair[other]!, print: { ...pair[other]!.print!, [ownKey[key]]: bounded(key, pair[other]!.print![ownKey[key]] + moved) } } };
    }
  }
  updatePair(() => pair, { params });
}
export function resetEnlarger() {
  const s = get(), neutral = { brightnessStops: 0, yFilterShift: 0, mFilterShift: 0, preflashExposure: 0 };
  if (!s.pair) { setEnlarger((p) => ({ ...p, printBrightnessStops: 0, yFilterShift: 0, mFilterShift: 0, preflashExposure: 0 })); return; }
  let pair = s.pair;
  if (s.pairLayer !== 'film' && pair[s.pairLayer]) {
    for (const side of PAIR_SIDES) if (pair[side] && !pair[side]!.print) pair = { ...pair, [side]: { ...pair[side]!, print: printTrim(s.sidecar.params) } };
    pair = { ...pair, [s.pairLayer]: { ...pair[s.pairLayer]!, print: neutral } };
    updatePair(() => pair, { step: true });
  } else {
    for (const side of PAIR_SIDES) if (pair[side]) pair = { ...pair, [side]: { ...pair[side]!, print: null } };
    updatePair(() => pair, { step: true, params: { ...s.sidecar.params, printBrightnessStops: 0, yFilterShift: 0, mFilterShift: 0, preflashExposure: 0 } });
  }
}
function savePairDecode(path: string, decode: DecodeSettings): Promise<void> {
  // One queue preserves edit/undo order even if sidecar I/O resolves slowly.
  // Keep each hole's original revision token. A fresh background read must
  // not authorize this older editing snapshot to overwrite an external edit.
  pairDecodeSave = pairDecodeSave.catch(() => {}).then(async () => {
    if (get().externalEditConflict) throw new Error('EXTERNAL_EDIT_CONFLICT: Resolve the current conflict before saving.');
    let own = pairSourceSidecars.get(path);
    if (!own) { const raw = await platform().sidecarLoad(path); own = raw ? decodeSidecar(raw) : newSidecar(); }
    const next = { ...own, decode, state: own.state === 'processed' ? 'stale' as const : own.state };
    try {
      await platform().sidecarSave(path, encodeSidecar(next));
      pairSourceSidecars.set(path, next);
    } catch (e) {
      if (String(e).includes('EXTERNAL_EDIT_CONFLICT')) markExternalConflict();
      throw e;
    }
  });
  return pairDecodeSave;
}
async function setPairDecode(fn: (d: DecodeSettings) => DecodeSettings) {
  const s = get(), side = pairFocus(s), hole = side ? s.pair?.[side] : null;
  if (!hole || !side || s.batchExporting) return;
  const next = fn(hole.decode); if (jsonEqual(next, hole.decode)) return;
  updatePair((p) => ({ ...p, [side]: { ...p[side]!, decode: next } }), { defer: true });
  try { await savePairDecode(hole.path, next); }
  catch (e) { if (get().selection === s.selection) noteError(tz('Pair white balance', '半格白平衡'), e); }
}
export function setPairPlacement(side: PairSide, fn: (p: PairPlacement) => PairPlacement, defer = true, coalesce = false) {
  updatePair((p) => p[side] ? { ...p, [side]: { ...p[side], placement: fn(p[side]!.placement) } } : p, { defer, coalesce });
}
export function commitPairPlacement() {
  if (pairTimer) { clearTimeout(pairTimer); pairTimer = null; void requestPrint(); }
}
export async function choosePairHole(side: PairSide) {
  const path = (await platform().pickFiles(tz('Choose a half-frame photograph', '选择半格照片')))[0];
  if (path) await setPairHole(side, path);
}
export function togglePairPlacing() {
  const s = get(); if (!s.pair || s.batchExporting) return;
  if (s.pairPlacing) {
    set({ pairPlacing: false });
    if (pairTimer) { clearTimeout(pairTimer); pairTimer = null; void requestPrint(); }
    return;
  }
  const side = pairFocus(); if (!side || s.pairInfo?.[side]?.available === false) return;
  setPairLayer(side); set({ pairPlacing: true, tool: 'select' });
}
export async function setPairHole(side: PairSide, path: string | null) {
  const s = get(); if (!s.pair || s.batchExporting || (path && isPairPath(path))) return;
  const generation = ++pairHoleGeneration[side];
  try {
    let hole = null;
    let sourceSidecar: Sidecar | null = null;
    if (path) {
      const raw = await platform().sidecarLoad(path); const own = raw ? decodeSidecar(raw) : newSidecar();
      sourceSidecar = own;
      hole = { ...newHole(path), decode: own.decode, geometry: own.geometry };
    }
    if (get().selection !== s.selection || generation !== pairHoleGeneration[side]) return;
    if (path && sourceSidecar) pairSourceSidecars.set(path, sourceSidecar);
    updatePair((p) => ({ ...p, [side]: hole }), { step: true });
    const sc = get().sidecar, key = (side === 'right') === sc.params.placementIsRight ? 'sceneLatitude' : 'sceneLatitudeOther';
    set({ sidecar: { ...sc, params: { ...sc.params, [key]: { ...SCENE_LATITUDE_DEFAULT } } }, pairLayer: side, pairPlacing: false });
    scheduleSave(); void requestPrint();
  } catch (e) { noteError(tz('Replacing pair frame', '替换半格照片'), e); }
}
export function swapPairHoles() {
  updatePair((p) => ({ ...p, left: p.right, right: p.left }), { step: true });
  const s = get(), p = s.sidecar.params;
  if (s.pair) { set({ sidecar: { ...s.sidecar, params: { ...p, sceneLatitude: p.sceneLatitudeOther, sceneLatitudeOther: p.sceneLatitude } } }); scheduleSave(); void requestPrint(); }
}
export function pairCanvasRects() {
  const s = get(); if (!s.pair) return null;
  if (edgeEffective(s.sidecar.params.filmEdge, s.gate)) {
    const gates = s.pairInfo?.gates;
    if (gates?.length !== 2) return null;
    const [left, right] = [...gates].sort((a, b) => s.pair!.turned ? a.y - b.y : a.x - b.x);
    return { left: left!, right: right! };
  }
  return pairRects(s.pair);
}
export function pairComplete(s = get()) {
  return !s.pair || PAIR_SIDES.every((side) => !!s.pair![side] && s.pairInfo?.[side]?.available === true);
}
export async function removePair() {
  const s = get(); if (!s.pair || !s.selection || s.batchExporting) return;
  try {
    await flushSave();
    if (get().externalEditConflict) return;
    await platform().pairDelete(s.selection); await closeEngineSession();
    const frames = get().frames.filter((f) => f.path !== s.selection);
    set({ frames, selection: null, picked: [], pair: null, pairInfo: null, pairLayer: 'film', pairPlacing: false });
    if (frames[0]) await select(frames[0].path);
  } catch (e) { noteError(tz('Removing pair', '移除半格拼接'), e); }
}

export function recomputeFilmFormat() {
  const p = get().sidecar.params;
  const mm = derived(p.filmSide, p.sideLengthMM);
  // Derived, not an edit: no undo step (the Mac writes it before the open).
  if (Math.abs(mm - p.filmFormatMM) > 0.001) {
    set({ sidecar: { ...get().sidecar, params: { ...get().sidecar.params, filmFormatMM: mm } } });
    scheduleSave();
    void requestPrint();
  }
}

export function setFilmFrame(id: string) {
  if (edgeEffective(get().sidecar.params.filmEdge, get().gate)) return;
  setParams((p) => {
    const f = filmFrameNamed(id);
    const side = id === FILM_FRAME_CUSTOM.id ? p.sideLengthMM : p.filmSide === 'short' ? f.short : f.long;
    return { ...p, filmFrame: f.id, sideLengthMM: side, filmFormatMM: derived(p.filmSide, side) };
  });
}
export function setFilmSide(side: FilmSide) {
  if (edgeEffective(get().sidecar.params.filmEdge, get().gate)) return;
  setParams((p) => {
    const mm = p.filmFrame !== FILM_FRAME_CUSTOM.id ? (side === 'short' ? filmFrameNamed(p.filmFrame).short : filmFrameNamed(p.filmFrame).long) : p.sideLengthMM;
    return { ...p, filmSide: side, sideLengthMM: mm, filmFormatMM: derived(side, mm) };
  });
}
export function setSideLengthMM(mm: number) {
  const s = get();
  // The edge owns its physical gate. Keep the user's dormant format intact;
  // a late field blur must not change it or turn a preset into Custom.
  if (edgeEffective(s.sidecar.params.filmEdge, s.gate) || s.sidecar.params.filmFrame !== FILM_FRAME_CUSTOM.id) return;
  setParams((p) => {
    const v = clamp(mm, 1, 500);
    return { ...p, filmFrame: FILM_FRAME_CUSTOM.id, sideLengthMM: v, filmFormatMM: derived(p.filmSide, v) };
  });
}

// ------------------------------------------------------------------ library

export async function openFolder(dir: string) {
  if (get().batchExporting) return;
  try {
    const files = await platform().listImages(dir);
    // An explicit folder open restores only that folder's pair recipes.
    // Single-file open below never scans the parent or revives an old roll.
    if (platform().pairList) files.push(...await platform().pairList(dir));
    await setLibrary(dir, files);
    settingsStore.getState().set('lastFolder', dir);
    const first = get().frames[0];
    if (first) await select(first.path);
  } catch (e) {
    noteError(tz('Opening the folder', '打开文件夹'), e);
  }
}

/** One door for dropped, argv and dialog paths (`Session.dropped(files:)`). */
export async function openPaths(paths: string[]) {
  if (get().batchExporting || !paths.length) return;
  try {
    let entries = await platform().expandPaths(paths);
    if (!entries.length) {
      set({ status: tz('Nothing there SpektraLab can open.', '没有 SpektraLab 能打开的文件。') });
      return;
    }
    // expandPaths expands only explicitly supplied directories. Opening a
    // file must not scan its parent (and recursively pull old rolls back in).
    // Replace the roll even when the chosen files were already in it.
    const singleFile = paths.length === 1 && entries.length === 1 && paths[0] === entries[0]!.path;
    const folder = paths.length === 1 && !singleFile ? paths[0]! : dirName(entries[0]!.path);
    // Folder launch/drop follows the same deliberate pair discovery as the
    // folder picker. A single photo never scans its parent for old pairs.
    for (const explicit of paths) if (!entries.some((f) => f.path === explicit) && typeof platform().pairList === 'function') {
      const listed = await platform().pairList(explicit);
      const known = new Set(entries.map((f) => f.path));
      entries.push(...listed.filter((f) => !known.has(f.path)));
    }
    let copiedPair = false;
    // External recipes are read-only. Import into the application's pair store
    // before editing; source files and the shared recipe remain untouched.
    entries = await Promise.all(entries.map(async (entry) => {
      if (!isPairPath(entry.path)) return entry;
      const pair = decodePair(await platform().pairLoad(entry.path));
      if (!pair) throw new Error(tz('The pair recipe is missing or invalid.', '半格拼接文件不存在或格式无效。'));
      const own = await platform().pairList(pair.folder);
      const samePath = (p: string) => p.replaceAll('\\', '/').toLocaleLowerCase();
      if (own.some((f) => samePath(f.path) === samePath(entry.path))) return entry;
      const saved = await platform().sidecarLoad(entry.path);
      const imported = await platform().pairCreate(pair.folder, encodePair(pair));
      if (saved) await platform().sidecarSave(imported.path, saved);
      copiedPair = true;
      return imported;
    }));
    await setLibrary(folder, entries);
    await select(get().frames[0]!.path);
    if (copiedPair) set({ status: tz('Imported an editable copy of the pair; the shared recipe was kept.', '已导入可编辑的半格副本，原拼接文件已保留。') });
  } catch (e) {
    noteError(tz('Opening', '打开'), e);
  }
}

async function setLibrary(folder: string, files: FileEntry[]) {
  foregroundWork();
  importPreviews.cancel();
  files = frameOrder.apply(folder, files);
  await flushSave();
  if (get().externalEditConflict) throw new Error(tz('Resolve the external edit conflict before opening another folder.', '请先处理外部编辑冲突，再打开其他文件夹。'));
  await closeEngineSession();
  thumbs.reset();
  frameImages.print = null;
  frameImages.original = null;
  set({ folder, frames: files, selection: null, picked: [], savedGeometry: {}, thumbVersion: get().thumbVersion + 1, imageVersion: get().imageVersion + 1, badge: null });
  queueImportPreviews();
  void platform().setTitle(`SpektraLab — ${baseName(folder)}`);
  // The thumbnails' crop masks come from each frame's saved geometry.
  void Promise.all(
    files.map(async (f) => {
      const raw = await platform().sidecarLoad(f.path).catch(() => null);
      return raw ? ([f.path, decodeSidecar(raw).geometry] as const) : null;
    }),
  ).then((rows) => {
    const g: Record<string, Geometry> = {};
    for (const r of rows) if (r) g[r[0]] = r[1];
    set({ savedGeometry: { ...g, ...get().savedGeometry } });
  });
}

/** Move one thumbnail into the hovered slot without touching selection,
 * editor session, parameters or the selected export set. */
export function moveFrame(path: string, target: string) {
  const s = get();
  if (s.batchExporting || path === target) return;
  const from = s.frames.findIndex((f) => f.path === path), to = s.frames.findIndex((f) => f.path === target);
  if (from < 0 || to < 0) return;
  const frames = [...s.frames], [frame] = frames.splice(from, 1);
  frames.splice(to, 0, frame!);
  set({ frames });
}

export function saveFrameOrder() {
  const s = get();
  if (!s.batchExporting && s.folder) frameOrder.save(s.folder, s.frames);
}

async function closeEngineSession() {
  const sid = get().engineSession;
  set({ engineSession: null });
  sentParams = null;
  sentPair = null;
  savedPair = null;
  pairHoleGeneration.left++; pairHoleGeneration.right++;
  if (pairTimer) clearTimeout(pairTimer);
  pairTimer = null;
  clearLatitude();
  originalGeneration++;
  lastOriginalKey = null;
  neutralPickGeneration++;
  neutralPreviousOriginal = null;
  sentDecode = null;
  wantedGen++;
  if (fullTimer) clearTimeout(fullTimer);
  if (decodeTimer) clearTimeout(decodeTimer);
  decodeTimer = null;
  if (sid) await host().close(sid).catch(() => {});
}

/** A plain click: picks exactly this frame and opens it (`Session.click`). */
export function click(path: string, additive = false) {
  const s = get();
  if (s.batchExporting) return;
  if (!additive) {
    set({ picked: [path] });
    void select(path, { deferDecode: true });
    return;
  }
  togglePick(path);
}

export function togglePick(path: string) {
  const s = get();
  if (s.batchExporting) return;
  if (!s.picked.includes(path)) set({ picked: [...s.picked, path] });
  else if (path !== s.selection) set({ picked: s.picked.filter((p) => p !== path) });
}

export function selectAllFrames() {
  const s = get();
  if (s.batchExporting || !s.frames.length) return;
  set({ picked: s.frames.map((f) => f.path) });
  if (!s.selection) void select(s.frames[0]!.path);
}

export function selectRelative(delta: number) {
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const i = s.frames.findIndex((f) => f.path === s.selection);
  const j = clamp(i + delta, 0, s.frames.length - 1);
  if (i >= 0 && j !== i) click(s.frames[j]!.path);
}

/**
 * Put a frame on the canvas. **Not guarded by `batchExporting`**: it is the
 * export run's own door (AGENTS.md trap 34). Everything a person does goes
 * through `click`/`openPaths`, which are.
 */
export async function select(path: string, options: { externalReload?: boolean; deferDecode?: boolean } = {}): Promise<void> {
  const prior = get();
  if (!options.externalReload && path === prior.selection && prior.engineSession) return;
  const gen = ++openGen;
  foregroundWork();
  importPreviews.setCurrent(path);
  thumbs.setPaused?.(true);
  openTrace = { generation: gen, path, origin: 'select', started: performance.now() };
  let closing: Promise<void> | null = null;
  try {
  if (!options.externalReload) {
    await flushSave();
    if (gen !== openGen) return;
    if (get().externalEditConflict) { thumbs.setPaused?.(false); return; }
    closing = closeEngineSession();
    frameImages.print = null;
    frameImages.original = null;
  }
  const raw = await platform().sidecarLoad(path).catch(() => null);
  if (gen !== openGen) return;
  const loaded = raw ? decodeSidecar(raw) : newSidecar();
  let sidecar = filmStageSidecar(loaded);
  let pair: HalfFramePair | null = null;
  const sources = new Map<string, Sidecar>();
  let pairDocument: string | null = null;
  if (isPairPath(path)) {
    pair = decodePair(await platform().pairLoad(path));
    if (!pair) { noteError(tz('Opening pair', '打开半格拼接'), new Error(tz('The pair recipe is missing or invalid.', '半格拼接文件不存在或格式无效。'))); return; }
    pairDocument = JSON.stringify(encodePair(pair));
    for (const side of PAIR_SIDES) {
      const hole: PairHole | null = pair[side]; if (!hole) continue;
      const ownRaw: unknown = await platform().sidecarLoad(hole.path).catch(() => null);
      const own: Sidecar = ownRaw ? decodeSidecar(ownRaw) : newSidecar();
      sources.set(hole.path, own);
      pair = { ...pair, [side]: { ...hole, decode: own.decode, geometry: own.geometry } };
    }
    if (gen !== openGen) return;
    pair = { ...pair, onStrip: edgeEffective(sidecar.params.filmEdge, get().gate) };
    const defaults = newSidecar().params;
    if (sidecar.params.filmFrame === defaults.filmFrame && sidecar.params.filmSide === defaults.filmSide && sidecar.params.sideLengthMM === defaults.sideLengthMM)
      sidecar = { ...sidecar, params: { ...sidecar.params, filmFrame: FILM_FRAME_CUSTOM.id, filmSide: 'long', sideLengthMM: 24 } };
    sidecar = { ...sidecar, geometry: GEOMETRY_DEFAULT, heldCrop: null,
      params: { ...sidecar.params, autoExposure: false, filmEdge: { ...sidecar.params.filmEdge, pair: true, format: '135_half' } } };
  } else if (sidecar.params.filmEdge.pair) {
    sidecar = { ...sidecar, params: { ...sidecar.params, pairSplit: 0, filmEdge: { ...sidecar.params.filmEdge, pair: false } } };
  }
  if (gen !== openGen) return;
  // Read first while the old editor stays usable. An edit made during that
  // I/O wins; never close its engine or replace its snapshot with disk data.
  if (options.externalReload && (get().selection !== prior.selection || get().sidecar !== prior.sidecar || get().pair !== prior.pair || savePending)) {
    if (get().selection === prior.selection) markExternalConflict();
    return;
  }
  if (options.externalReload) closing = closeEngineSession();
  if (options.externalReload) { frameImages.print = null; frameImages.original = null; }
  savedPair = pairDocument ? { path, value: pairDocument } : null;
  savedDocument = { path, content: sidecarContent(raw) };
  pairSourceSidecars.clear(); for (const [source, own] of sources) pairSourceSidecars.set(source, own);
  savePending = false;
  pendingExternalPaths.clear();
  set({
    selection: path,
    picked: get().picked.includes(path) ? get().picked : [path],
    sidecar,
    externalEditConflict: false, lastError: null,
    pair, pairInfo: null, pairLayer: 'film', pairPlacing: false,
    nativeSize: null,
    metadata: null,
    frameKind: null,
    badge: null,
    developing: true,
    undo: [],
    redo: [],
    imageVersion: get().imageVersion + 1,
    view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 },
    showingOriginal: false,
    tool: 'select',
    status: tz(`Opening ${baseName(path)}…`, `正在打开 ${baseName(path)}…`),
  });
  if (sidecar !== loaded) scheduleSave();
  await seedFilmEdge(path, gen);
  if (gen !== openGen) return;
  const warming = warmDisplayFromCache(path, gen).catch(() => {});
  // Display cache I/O is independent of the old host job. Engine opens remain
  // serialized so a stale decode is closed before another RAW allocates.
  const dwell = options.deferDecode && !get().batchExporting
    ? new Promise<void>((r) => setTimeout(r, 120)) : Promise.resolve();
  const task = openingTask.catch(() => {}).then(async () => {
    await closing; await dwell;
    if (gen !== openGen) return;
    // Do not hold engine work hostage to a slow disk cache. Cache warmup may
    // finish later; its generation/descriptor guards still protect the view.
    void warming;
    if (!frameImages.original && !frameImages.print) void loadOriginal(path, gen);
    if (gen !== openGen) return;
    await develop(path, gen);
  });
  openingTask = task;
  await task;
  } finally {
    if (gen === openGen) { thumbs.setPaused?.(false); set({ developing: false }); resumePreviewsWhenIdle(); }
  }
}

async function loadOriginal(path: string, gen: number) {
  const started = performance.now();
  const publish = (img: Parameters<typeof writeDisplayCache>[1]) => {
    if (gen !== openGen || lastOriginalKey !== null || frameImages.original) return;
    if (openTrace?.generation === gen) openTrace.originalMs = elapsed(started);
    frameImages.original = img;
    if (!frameImages.print) noteVisible('camera-preview');
    set({ imageVersion: get().imageVersion + 1 });
  };
  try {
    const key = await displayCacheKey(cameraDescriptor(path));
    const img = await readDisplayCache(key, { retain: false });
    if (gen !== openGen || lastOriginalKey !== null || frameImages.original || frameImages.print) return;
    if (img) publish(img);
    else void host().thumbnail(path, 2048, isRawPath(path) && !!get().hello?.thumbnail_options?.includes('embedded-only'))
      .then((image) => { if (gen === openGen) { void writeDisplayCache(key, image, { retain: false }); publish(image); } }).catch(() => {});
  } catch {
    if (openTrace?.generation === gen) openTrace.originalMs = elapsed(started);
    /* no original to compare against; the print still shows */
  }
}

/** Current decode before film/post/crop. One bounded readback at a time; old
 * photo, decode, zoom and display requests never replace the latest result. */
export async function refreshOriginal(): Promise<void> {
  originalGeneration++;
  if (originalInFlight) return;
  foregroundWork();
  originalInFlight = true;
  try {
    for (;;) {
      const s = get(), sid = s.engineSession, frame = s.selection;
      if (!sid || !frame || s.batchExporting || s.redecoding || decodeTimer || !s.hello?.methods?.includes('render_source')) return;
      const gen = originalGeneration, decode = JSON.stringify(s.sidecar.decode);
      const edge = viewLongEdge({ ...s, sidecar: { ...s.sidecar, geometry: GEOMETRY_DEFAULT } });
      const key = JSON.stringify([sid, decode, edge, s.displaySpace]);
      if (lastOriginalKey === key) return;
      const current = () => get().engineSession === sid && get().selection === frame
        && JSON.stringify(get().sidecar.decode) === decode && get().displaySpace === s.displaySpace
        && !get().redecoding && !decodeTimer;
      try {
        const descriptor = cachedDisplayDescriptor('original', s);
        const cacheKey = descriptor ? await displayCacheKey(descriptor) : null;
        if (gen !== originalGeneration || !current()) continue;
        const image = await host().renderSource(sid, { long_edge: edge, display: s.displaySpace, generation: gen });
        if (gen === originalGeneration && current()) {
          frameImages.original = image;
          lastOriginalKey = key;
          set({ imageVersion: get().imageVersion + 1 });
          cacheDisplay(cacheKey, image, s.nativeSize, false);
        }
      } catch (e) {
        if (gen === originalGeneration && current())
          platform().log('warn', `session: decoded source preview unavailable: ${e instanceof Error ? e.message : String(e)}`);
      }
      if (gen === originalGeneration) return;
    }
  } finally { originalInFlight = false; resumePreviewsWhenIdle(); }
}

export function canPickNeutral(): boolean {
  const s = get();
  const side = pairFocus(s), raw = s.pair ? !!side && s.pairInfo?.[side]?.kind === 'raw' && s.pairInfo[side]?.available === true : isRawFrame();
  const sourceReady = s.pair ? !pairTimer && JSON.stringify(pairSnapshotFor(s.pair, s.sidecar.params)) === sentPair
    : !sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate, s.sidecar.noFilm);
  return sourceReady && !!s.engineSession && !!s.selection && raw && !s.batchExporting && !s.developing
    && !s.redecoding && !decodeTimer && !!s.hello?.methods?.includes('pick_neutral') && hostRedecodes(s.hello.methods);
}

export function startNeutralPick() {
  if (!canPickNeutral()) return;
  if (get().tool === 'neutral') { setTool('select'); return; }
  neutralPreviousOriginal = get().showingOriginal;
  neutralPairSide = pairFocus();
  set({ pairPlacing: false });
  setTool('neutral');
  set({ showingOriginal: true, status: tz('Click a neutral area in the original; Escape cancels.', '请在原图中点击中性灰区域；按 Esc 取消。') });
  void refreshOriginal();
}

export async function pickNeutralAt(x: number, y: number): Promise<void> {
  if (get().tool !== 'neutral' || !canPickNeutral() || ![x, y].every(Number.isFinite)
    || x < 0 || x > 1 || y < 0 || y > 1) return;
  const s = get(), sid = s.engineSession!, frame = s.selection, decode = JSON.stringify(s.sidecar.decode);
  const side = neutralPairSide, pair = JSON.stringify(s.pair);
  if (s.pair && side) {
    const rect = pairRects(s.pair)[side];
    if (x < rect.x || y < rect.y || x > rect.x + rect.width || y > rect.y + rect.height) {
      set({ status: tz('Pick a neutral area inside the selected frame.', '请在当前选中的半格内吸取中性灰。') }); return;
    }
  }
  const gen = ++neutralPickGeneration;
  const current = () => gen === neutralPickGeneration && get().engineSession === sid && get().selection === frame
    && get().tool === 'neutral' && JSON.stringify(get().sidecar.decode) === decode && JSON.stringify(get().pair) === pair && neutralPairSide === side;
  set({ status: tz('Measuring neutral white balance…', '正在测量中性白平衡…') });
  try {
    const wb = side ? await host().pickNeutral(sid, x, y, side) : await host().pickNeutral(sid, x, y);
    if (!current()) return;
    if (!Number.isFinite(wb.temperature_k) || !Number.isFinite(wb.tint)
      || wb.temperature_k < 2000 || wb.temperature_k > 50000 || Math.abs(wb.tint) > 150)
      throw new Error(tz('The neutral measurement is outside the supported white balance range.', '中性区域测量超出了白平衡支持范围。'));
    setTool('select');
    lastUndoAt = 0;
    setDecode((d) => ({ ...d, whiteBalance: 'Custom', temperature: wb.temperature_k, tint: wb.tint }));
  } catch (e) {
    if (current()) noteError(tz('Neutral white balance', '中性白平衡'), e);
  }
}

async function develop(path: string, gen: number) {
  if (get().hostState.phase !== 'ready') {
    set({ status: tz('Waiting for the engine…', '正在等待引擎…') });
    return;
  }
  set({ developing: true, lastError: null });
  try {
    const t0 = performance.now();
    if (openTrace?.generation !== gen || openTrace.path !== path)
      openTrace = { generation: gen, path, origin: 'develop', started: t0 };
    openTrace.developStarted = t0;
    // Also covers a frame selected before the catalog loaded, and host
    // restarts. Repair old sidecars before the very first open payload.
    const sidecar = filmStageSidecar(get().sidecar);
    if (sidecar !== get().sidecar) {
      set({ sidecar });
      scheduleSave();
    }
    const params = get().sidecar.params;
    const openingPair = get().pair ? pairSnapshotFor(get().pair!, params) : null;
    const decode = decodeWire(get().sidecar.decode, isRawPath(path));
    const openStarted = performance.now();
    let r;
    try {
      if (openingPair) {
        if (!get().hello?.methods?.includes('open_pair')) throw new Error(tz('This engine does not support half-frame pairs.', '此引擎不支持半格拼接。'));
        r = await host().openPair(path, wireParams(params), openingPair);
      } else r = await host().open(path, wireParams(params), decode);
    } catch (e) {
      // A host without R2 refuses the decode key: open with the camera's own.
      if (!(decode && e instanceof HostCallError && e.code === 'unsupported')) throw e;
      r = await host().open(path, wireParams(params));
    }
    if (gen !== openGen) {
      await host().close(r.session).catch(() => {});
      return;
    }
    sentParams = params;
    sentPair = openingPair ? JSON.stringify(pairWithMeterReadings(openingPair, openingPair, r.pair_info, params.autoExposureMethod)) : null;
    if (openingPair) adoptPairMeterReadings(openingPair, r.pair_info, params.autoExposureMethod);
    sentDecode = JSON.stringify(decode);
    set({ engineSession: r.session, nativeSize: { width: r.width, height: r.height }, metadata: r.metadata, pairInfo: r.pair_info ?? null, frameKind: r.kind ?? (isRawPath(path) ? 'raw' : null) });
    if (openTrace?.generation === gen) {
      openTrace.session = r.session;
      openTrace.openCallMs = elapsed(openStarted);
    }
    noteAsShot();
    resolveCurrentFilmEdge();
    platform().log(
      'info',
      `session: open ${JSON.stringify({ call_ms: elapsed(openStarted), develop_ms: elapsed(t0),
        host_decode_ms: r.timings_ms?.decode, host_upload_ms: r.timings_ms?.open, raw: r.timings_ms?.raw,
        queue_transport_ms: r.timings_ms?.decode !== undefined && r.timings_ms?.open !== undefined
          ? Math.max(0, Math.round((elapsed(openStarted) - r.timings_ms.decode - r.timings_ms.open) * 10) / 10) : null,
        original_thumbnail_ms: openTrace?.originalMs ?? null,
        core: get().hello?.capabilities?.backend?.render_core })}`,
    );
    recomputeFilmFormat();
    // `recomputeFilmFormat` may have queued a render already.
    if (!inFlight) await requestPrint();
    if (gen !== openGen) return;
    void refreshOriginal();
    const sc = get().sidecar;
    if (sc.state === 'unprocessed') {
      set({ sidecar: { ...sc, state: 'processed' } });
      scheduleSave();
    }
  } catch (e) {
    if (gen === openGen) noteError(tz(`Opening ${baseName(path)}`, `打开 ${baseName(path)}`), e);
  } finally {
    if (gen === openGen) set({ developing: false });
  }
}

/** Process: auto-exposure and the enlarger's filter pack for this paper. */
export async function solveNow() {
  const s = get();
  if (!s.engineSession || s.developing) return;
  set({ developing: true, status: tz('Solving…', '正在配光…') });
  try {
    await host().solve(s.engineSession, 'both');
    // The pack is the engine's now; the user's shifts return to neutral.
    sentParams = null;
    setParams((p) => ({ ...p, yFilterShift: 0, mFilterShift: 0 }));
    void requestPrint();
    set({ status: tz('Solved.', '配光完成。') });
  } catch (e) {
    noteError(tz('Process', '配光'), e);
  } finally {
    set({ developing: false });
  }
}

export function resetParams() {
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const defaults = newSidecar();
  lastUndoAt = 0;
  pushUndo();
  // One undo entry for the full capture setup; crop and Post-Dev stay put.
  restore({ ...s.sidecar, pair: s.pair, params: defaults.params, decode: defaults.decode, placementNeedsFit: false });
  recomputeFilmFormat();
}
export function resetAdjustments() {
  setAdjustments(() => ({ ...ADJUSTMENTS_DEFAULT }));
}
export function resetCrop() {
  setGeometry(() => GEOMETRY_DEFAULT);
}

// ---------------------------------------------------------------- clipboard

export function copySettings() {
  const s = get();
  if (!s.selection || !s.clipboardGroups.length) return;
  set({
    clipboard: { groups: s.clipboardGroups, settings: s.sidecar, sourceName: baseName(s.selection) },
    status: tz(`Copied ${s.clipboardGroups.length} groups from ${baseName(s.selection)}.`, `已从 ${baseName(s.selection)} 拷贝 ${s.clipboardGroups.length} 组设置。`),
  });
}

async function pasteOffline(clip: SettingsClip, path: string): Promise<boolean> {
  const raw = await platform().sidecarLoad(path).catch(() => null);
  const target = raw ? decodeSidecar(raw) : newSidecar();
  const applied = applyClip(clip, target);
  const next = filmStageSidecar(applied);
  if (!clipChanges(clip, target) && next === applied) return false;
  await platform().sidecarSave(path, encodeSidecar({ ...next, state: next.state === 'processed' ? 'stale' : next.state }));
  return true;
}

export async function pasteSettings() {
  const s = get();
  const clip = s.clipboard;
  if (!clip || !s.selection || s.batchExporting) return;
  const targets = s.picked.length ? s.picked : [s.selection];
  let written = 0;
  for (const p of targets) if (p !== s.selection && (await pasteOffline(clip, p))) written++;
  const applied = applyClip(clip, get().sidecar);
  const next = filmStageSidecar(applied);
  if (targets.includes(s.selection) && (clipChanges(clip, get().sidecar) || next !== applied)) {
    // Commit the target's intent and decode atomically before any render/probe.
    // Copying only white balance or a pending fit must still save and undo.
    lastUndoAt = 0;
    pushUndo();
    const decodeMoved = !jsonEqual(next.decode, get().sidecar.decode);
    set({ sidecar: { ...next, state: next.state === 'processed' ? 'stale' : next.state } });
    scheduleSave();
    if (decodeMoved && !get().pair) scheduleRedecode();
    else void requestPrint();
    written++;
  }
  set({
    status:
      written === 0
        ? tz('Nothing to paste — the frames already have these settings.', '无需粘贴——这些照片已经是这些设置。')
        : tz(`Pasted ${clip.groups.length} groups onto ${written} frames.`, `已将 ${clip.groups.length} 组设置粘贴到 ${written} 张照片。`),
  });
}

export async function syncSettings() {
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const clip = { groups: s.clipboardGroups, settings: s.sidecar, sourceName: baseName(s.selection) };
  let written = 0;
  for (const p of s.picked) if (p !== s.selection && (await pasteOffline(clip, p))) written++;
  set({ status: tz(`Synced to ${written} frames.`, `已同步到 ${written} 张照片。`) });
}

// --------------------------------------------------------------------- view

export { ZOOM_STEPS } from '../canvas/zoom';

export function setView(v: Partial<ViewState>) {
  const before = viewLongEdge(get());
  set({ view: { ...get().view, ...v } });
  // Pan never changes detail; crossing a zoom/detail threshold requests a
  // fresh cached view, and the existing generation scheduler coalesces it.
  if (hostViews() && before !== viewLongEdge(get()) && !get().batchExporting) void requestPrint();
  void refreshOriginal();
}
export function zoomToFit() {
  setView({ fit: true, cx: 0.5, cy: 0.5 });
}
export function zoomTo(zoom: number) {
  setView({ fit: false, zoom: clampZoom(zoom, currentFitZoom) });
}
/** `fitZoom` is the zoom the fit currently implies (the canvas knows it). */
export function zoomStep(dir: 1 | -1, fitZoom: number) {
  const cur = get().view.fit ? fitZoom : get().view.zoom;
  const next = steppedZoom(cur, dir, fitZoom);
  if (next !== cur) setView({ fit: false, zoom: next });
}
export let currentFitZoom = 1;
export function noteCanvasPx(width: number, height: number) {
  const c = get().canvasPx;
  if (c.width !== width || c.height !== height) {
    const before = viewLongEdge(get());
    set({ canvasPx: { width, height } });
    if (hostViews() && before !== viewLongEdge(get()) && !get().batchExporting) void requestPrint();
    void refreshOriginal();
  }
}
export function noteFitZoom(z: number) {
  currentFitZoom = z;
  if (Math.abs(get().fitZoom - z) > 1e-4) set({ fitZoom: z });
}

export function setTool(tool: Tool) {
  if (tool === 'crop' && get().pair) { togglePairPlacing(); return; }
  if (tool === 'select' && get().pairPlacing) { togglePairPlacing(); return; }
  const previous = get().tool;
  if (previous === 'neutral' && tool !== 'neutral') {
    neutralPickGeneration++;
    neutralPairSide = null;
    if (neutralPreviousOriginal !== null) set({ showingOriginal: neutralPreviousOriginal });
    neutralPreviousOriginal = null;
  }
  set({ tool });
  if (tool === 'crop') void refreshOriginal();
  if (previous !== tool && (previous === 'crop' || tool === 'crop') && hostViews() && !get().batchExporting) void requestPrint();
}
export function setOriginal(on: boolean) {
  if (on && sourceGeometryFor(get().sidecar.params, get().sidecar.geometry, get().gate, get().sidecar.noFilm)) return;
  set({ showingOriginal: on });
  if (on) void refreshOriginal();
}
export function toggleCompare() {
  if (sourceGeometryFor(get().sidecar.params, get().sidecar.geometry, get().gate, get().sidecar.noFilm)) return;
  set({ comparing: !get().comparing });
  if (get().comparing) void refreshOriginal();
}
export function setComparePosition(p: number) {
  const v = clamp(p, 0, 1);
  if (v !== get().comparePosition) set({ comparePosition: v });
}

export function setPages(p: Partial<Pick<SessionState, 'exportOpen' | 'settingsOpen' | 'aboutOpen' | 'batchExporting' | 'clipboardGroups'>>) {
  if (p.exportOpen && !pairComplete()) { set({ status: tz('Fill both frames before exporting this pair.', '请先在两格中都放入照片，再导出拼接。') }); return; }
  set(p);
  if (get().batchExporting || get().exportOpen) foregroundWork(); else resumePreviewsWhenIdle();
}
export function setStatus(status: string) {
  set({ status });
}

// --------------------------------------------------------------------- boot

let lastReadyHello: unknown = null;

function takeHostState(st: HostState) {
  // The host answers but its engine could not start (no Vulkan device): the
  // files still list and thumbnail, nothing develops. Shown as a failure with
  // the host's own words.
  if (st.phase === 'ready' && st.hello.backend?.available === false) {
    set({
      hello: st.hello,
      hostState: { phase: 'failed', reason: st.hello.backend.error || tz('The engine has no GPU device to render on.', '引擎没有可用于渲染的 GPU 设备。'), detail: st.hello.build_info },
    });
    return;
  }
  set({ hostState: st });
  if (st.phase === 'ready') {
    const unsupported = (st.hello.capabilities?.backend?.unsupported_features as string[] | undefined) ?? [];
    set({
      hello: st.hello,
      unsupported,
      gate: featureGate(unsupported, settingsStore.getState().diBlueCompensation, st.hello.view_options?.includes('no_film') ?? false),
    });
    queueImportPreviews();
    // A new host (first start or a restart): re-open the frame from its sidecar.
    if (lastReadyHello !== st.hello) {
      lastReadyHello = st.hello;
      const sel = get().selection;
      if (sel && !get().engineSession) {
        const gen = ++openGen;
        void develop(sel, gen);
      } else if (sel) {
        set({ engineSession: null });
        sentParams = null;
        const gen = ++openGen;
        void develop(sel, gen);
      }
    }
  } else if (st.phase === 'restarting' || st.phase === 'failed') {
    set({ engineSession: null, status: st.phase === 'failed' ? st.reason : tz('Restarting the engine…', '正在重启引擎…') });
    sentParams = null;
  }
}

export async function boot() {
  // Polarity must be known before a ready notification opens a sidecar.
  // An empty, still-loading catalog is not evidence that a film is negative.
  set({ catalog: await loadCatalog() });
  let stateEvents = 0;
  host().onState((st) => {
    stateEvents++;
    takeHostState(st);
  });
  try {
    const initial = await host().state();
    // Events delivered while this request was in flight are newer than its
    // snapshot. A late "starting" reply must never undo a ready notification.
    if (stateEvents === 0) takeHostState(initial);
    platform().log('info', `session: startup host state ${get().hostState.phase}`);
  } catch (error) {
    const reason = `${tz('Could not connect to the engine', '无法连接引擎')}: ${String(error)}`;
    if (stateEvents === 0) takeHostState({ phase: 'failed', reason });
    platform().log('error', reason);
  }
  platform().onOpenPaths((paths) => void openPaths(paths));
  platform().onDrop((paths) => void openPaths(paths));
  const launch = await platform().takeLaunchPaths();
  if (launch.length) await openPaths(launch);
  window.addEventListener('beforeunload', () => void flushSave());
  if (platform().kind === 'tauri' && !agentPollTimer) {
    void pollAgentChanges();
    agentPollTimer = setInterval(() => void pollAgentChanges(), 2000);
    window.addEventListener('focus', () => void pollAgentChanges());
  }
}

/** For tests and the export run. */
export function _internals() {
  return { get, set };
}

/** Upstream menu actions use the native view path and its cache invalidation. */
export const pickFilmStock = selectFilmStock;
export const noFilmShown = (s: Pick<SessionState, 'sidecar' | 'pair'>) => s.sidecar.noFilm && !s.pair;
export function setNoFilm(on: boolean) { if (get().sidecar.noFilm !== on) toggleNoFilm(); }
export function resetFilmStock() {
  if (get().batchExporting) return;
  lastUndoAt = 0;
  setParams((p) => ({ ...p, filmStock: 'kodak_portra_400' }));
}
