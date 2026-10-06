// session.ts — the one session (the Mac's `Model/Session.swift`, reduced to
// what this port carries): the library, the open frame and its edits, the
// engine session behind it, undo, the clipboard and the view.
//
// Three kinds of edit, three costs (ARCHITECTURE.md §7.1):
//   params      → a `set_params` delta and a render (reprint if print-only)
//   adjustments → Layer 2 in the canvas shader, no host call
//   geometry    → applied when the canvas samples, no host call
//
// Pixels do not live in this store: `frames.ts` holds them, and the store
// carries a version number the canvas watches.

import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import type { HelloResult, HostState, FileMetadata, Tier } from '@shared/protocol';
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
  jsonEqual,
  clamp,
} from '@shared/params';
import { type Adjustments, ADJUSTMENTS_DEFAULT } from '@shared/adjustments';
import { type Geometry, GEOMETRY_DEFAULT, outputSize } from '@shared/geometry';
import { type Sidecar, decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import { type ClipboardGroup, type SettingsClip, CLIPBOARD_GROUPS, applyClip, clipChanges } from '@shared/clipboard';
import { EMPTY_CATALOG, type StockCatalog, loadCatalog } from '@shared/stocks';
import { HostCallError, host } from '../host/client';
import { type FileEntry, baseName, dirName, platform } from '../platform';
import { settingsStore } from './settings';
import { frameImages, makeThumbFromPrint } from './frames';
import { thumbs } from './thumbs';
import { tz } from '../i18n';

export type Tool = 'select' | 'hand' | 'crop';

export interface ViewState {
  /** Fit the output to the canvas; when false, `zoom` is native px → device px. */
  fit: boolean;
  zoom: number;
  /** Pan: the output point (0…1) at the canvas centre. */
  cx: number;
  cy: number;
}

export interface UndoEntry {
  params: FilmParams;
  adjustments: Adjustments;
  geometry: Geometry;
}

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
  engineSession: string | null;
  nativeSize: { width: number; height: number } | null;
  metadata: FileMetadata | null;
  imageVersion: number;
  badge: Tier | null;
  developing: boolean;
  status: string;
  lastError: string | null;
  // view
  tool: Tool;
  view: ViewState;
  fitZoom: number;
  /** The canvas in device px (the navigator draws the visible part from it). */
  canvasPx: { width: number; height: number };
  showingOriginal: boolean;
  comparing: boolean;
  comparePosition: number;
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
  engineSession: null,
  nativeSize: null,
  metadata: null,
  imageVersion: 0,
  badge: null,
  developing: false,
  status: '',
  lastError: null,
  tool: 'select',
  fitZoom: 1,
  canvasPx: { width: 1, height: 1 },
  view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 },
  showingOriginal: false,
  comparing: false,
  comparePosition: 0.5,
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
let wantedGen = 0;
let inFlight = false;
let fullTimer: ReturnType<typeof setTimeout> | null = null;
let saveTimer: ReturnType<typeof setTimeout> | null = null;
let lastUndoAt = 0;
let openGen = 0;
const FULL_DELAY_MS = 400;

function noteError(op: string, e: unknown) {
  const msg = e instanceof HostCallError ? `${e.message} (${e.code})` : e instanceof Error ? e.message : String(e);
  platform().log('error', `${op}: ${msg}`);
  set({ lastError: `${op}: ${msg}`, status: tz(`${op} failed: ${msg}`, `${op} 失败：${msg}`) });
}

function previewEdge() {
  return settingsStore.getState().previewLongEdge;
}

function wireParams(p: FilmParams) {
  return { ...fullDelta(p, get().gate), preview_long_edge: previewEdge() };
}

export async function requestPrint(): Promise<void> {
  wantedGen++;
  if (fullTimer) clearTimeout(fullTimer);
  if (inFlight) return;
  const sid = get().engineSession;
  if (!sid) return;
  inFlight = true;
  try {
    for (;;) {
      const gen = wantedGen;
      const s = get();
      if (s.engineSession !== sid) return;
      const want = s.sidecar.params;
      const d = sentParams ? paramsDelta(want, sentParams, s.gate) : { delta: wireParams(want), layers: new Set(['shoot']) };
      if (Object.keys(d.delta).length) {
        await host().setParams(sid, d.delta);
        sentParams = want;
      }
      const reprint = d.layers.size === 1 && d.layers.has('print');
      const r = await host().render(sid, 'live', { reprint });
      if (get().engineSession !== sid) return;
      frameImages.print = r;
      set({ imageVersion: get().imageVersion + 1, badge: 'preview', status: '' });
      if (gen === wantedGen) break;
    }
  } catch (e) {
    noteError(tz('Render', '渲染'), e);
  } finally {
    inFlight = false;
  }
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
  if (!sid || inFlight || gen !== wantedGen) return;
  const native = s.nativeSize;
  // A frame no larger than the preview edge is already at its own size.
  if (native && Math.max(native.width, native.height) <= previewEdge()) {
    set({ badge: 'full' });
    await refreshThumb();
    return;
  }
  inFlight = true;
  try {
    const t0 = performance.now();
    const r = await host().render(sid, 'full');
    // Dropped when the generation, selection or session moved (ARCHITECTURE §7.3).
    if (gen !== wantedGen || get().engineSession !== sid) return;
    frameImages.print = r;
    platform().log('info', `session: full render ${r.width}x${r.height} landed in ${Math.round(performance.now() - t0)} ms`);
    set({ imageVersion: get().imageVersion + 1, badge: 'full' });
    await refreshThumb();
  } catch (e) {
    noteError(tz('Full render', '全尺寸渲染'), e);
  } finally {
    inFlight = false;
    if (gen !== wantedGen) void requestPrint();
  }
}

async function refreshThumb() {
  const s = get();
  if (!s.selection || !frameImages.print) return;
  const url = await makeThumbFromPrint(frameImages.print);
  if (url && get().selection === s.selection) {
    thumbs.setPrint(s.selection, url);
    set({ thumbVersion: get().thumbVersion + 1 });
  }
}

// -------------------------------------------------------------- persistence

function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void flushSave(), 500);
}

export async function flushSave(): Promise<void> {
  if (saveTimer) {
    clearTimeout(saveTimer);
    saveTimer = null;
  } else return;
  const s = get();
  if (!s.selection) return;
  try {
    await platform().sidecarSave(s.selection, encodeSidecar(s.sidecar));
    set({ savedGeometry: { ...get().savedGeometry, [s.selection]: s.sidecar.geometry } });
  } catch (e) {
    noteError(tz('Saving settings', '保存设置'), e);
  }
}

function pushUndo() {
  const now = performance.now();
  if (now - lastUndoAt < 500) return;
  lastUndoAt = now;
  const sc = get().sidecar;
  const undo = [...get().undo, { params: sc.params, adjustments: sc.adjustments, geometry: sc.geometry }].slice(-60);
  set({ undo, redo: [] });
}

/** The single door for a Layer 1 edit. */
export function setParams(fn: (p: FilmParams) => FilmParams) {
  const s = get();
  if (s.batchExporting) return;
  const next = fn(s.sidecar.params);
  if (jsonEqual(next, s.sidecar.params)) return;
  pushUndo();
  set({ sidecar: { ...get().sidecar, params: next, state: get().sidecar.state === 'processed' ? 'stale' : get().sidecar.state } });
  scheduleSave();
  void requestPrint();
}

/** A Layer 2 edit: one draw. */
export function setAdjustments(fn: (a: Adjustments) => Adjustments) {
  const s = get();
  const next = fn(s.sidecar.adjustments);
  if (jsonEqual(next, s.sidecar.adjustments)) return;
  pushUndo();
  set({ sidecar: { ...s.sidecar, adjustments: next } });
  scheduleSave();
}

/** A geometry edit: one draw (and the film format, when a crop re-maps it). */
export function setGeometry(fn: (g: Geometry) => Geometry, opts: { coalesce?: boolean } = {}) {
  const s = get();
  const next = fn(s.sidecar.geometry);
  if (jsonEqual(next, s.sidecar.geometry)) return;
  if (!opts.coalesce) pushUndo();
  set({ sidecar: { ...s.sidecar, geometry: next }, savedGeometry: s.selection ? { ...s.savedGeometry, [s.selection]: next } : s.savedGeometry });
  scheduleSave();
  if (settingsStore.getState().recalculateEffectsAfterCrop) recomputeFilmFormat();
}

export function beginGesture() {
  pushUndo();
  lastUndoAt = performance.now();
}

function restore(e: UndoEntry) {
  const s = get();
  set({ sidecar: { ...s.sidecar, params: e.params, adjustments: e.adjustments, geometry: e.geometry } });
  scheduleSave();
  void requestPrint();
}

export function undo() {
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const prev = s.undo[s.undo.length - 1];
  if (!prev) return;
  const cur = { params: s.sidecar.params, adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry };
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
  const cur = { params: s.sidecar.params, adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry };
  set({ redo: s.redo.slice(0, -1), undo: [...s.undo, cur] });
  lastUndoAt = 0;
  restore(next);
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
  return filmFormatMM(side, mm, aspectOf(), cropScale());
}

export function recomputeFilmFormat() {
  const p = get().sidecar.params;
  const mm = derived(p.filmSide, p.sideLengthMM);
  if (Math.abs(mm - p.filmFormatMM) > 0.001) setParams((q) => ({ ...q, filmFormatMM: mm }));
}

export function setFilmFrame(id: string) {
  setParams((p) => {
    const f = filmFrameNamed(id);
    const side = id === FILM_FRAME_CUSTOM.id ? p.sideLengthMM : p.filmSide === 'short' ? f.short : f.long;
    return { ...p, filmFrame: f.id, sideLengthMM: side, filmFormatMM: derived(p.filmSide, side) };
  });
}
export function setFilmSide(side: FilmSide) {
  setParams((p) => {
    const mm = p.filmFrame !== FILM_FRAME_CUSTOM.id ? (side === 'short' ? filmFrameNamed(p.filmFrame).short : filmFrameNamed(p.filmFrame).long) : p.sideLengthMM;
    return { ...p, filmSide: side, sideLengthMM: mm, filmFormatMM: derived(side, mm) };
  });
}
export function setSideLengthMM(mm: number) {
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
    await setLibrary(dir, files);
    settingsStore.getState().set('lastFolder', dir);
    if (files[0]) await select(files[0].path);
  } catch (e) {
    noteError(tz('Opening the folder', '打开文件夹'), e);
  }
}

/** One door for dropped, argv and dialog paths (`Session.dropped(files:)`). */
export async function openPaths(paths: string[]) {
  if (get().batchExporting || !paths.length) return;
  try {
    const entries = await platform().expandPaths(paths);
    if (!entries.length) {
      set({ status: tz('Nothing there SpektraLab can open.', '没有 SpektraLab 能打开的文件。') });
      return;
    }
    // One file is "edit this": its folder comes along around it.
    if (entries.length === 1 && paths.length === 1 && paths[0] === entries[0]!.path) {
      const dir = dirName(entries[0]!.path);
      const all = await platform().listImages(dir).catch(() => entries);
      await setLibrary(dir, all.length ? all : entries);
      await select(entries[0]!.path);
      return;
    }
    const known = new Set(get().frames.map((f) => f.path));
    if (entries.every((e) => known.has(e.path))) {
      await select(entries[0]!.path);
      return;
    }
    const folder = paths.length === 1 ? paths[0]! : dirName(entries[0]!.path);
    await setLibrary(folder, entries);
    await select(entries[0]!.path);
  } catch (e) {
    noteError(tz('Opening', '打开'), e);
  }
}

async function setLibrary(folder: string, files: FileEntry[]) {
  await flushSave();
  await closeEngineSession();
  thumbs.reset();
  frameImages.print = null;
  frameImages.original = null;
  set({ folder, frames: files, selection: null, picked: [], savedGeometry: {}, thumbVersion: get().thumbVersion + 1, imageVersion: get().imageVersion + 1, badge: null });
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

async function closeEngineSession() {
  const sid = get().engineSession;
  set({ engineSession: null });
  sentParams = null;
  wantedGen++;
  if (fullTimer) clearTimeout(fullTimer);
  if (sid) await host().close(sid).catch(() => {});
}

/** A plain click: picks exactly this frame and opens it (`Session.click`). */
export function click(path: string, additive = false) {
  const s = get();
  if (s.batchExporting) return;
  if (!additive) {
    set({ picked: [path] });
    void select(path);
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
export async function select(path: string): Promise<void> {
  if (path === get().selection && get().engineSession) return;
  const gen = ++openGen;
  await flushSave();
  await closeEngineSession();
  frameImages.print = null;
  frameImages.original = null;
  const raw = await platform().sidecarLoad(path).catch(() => null);
  if (gen !== openGen) return;
  const sidecar = raw ? decodeSidecar(raw) : newSidecar();
  set({
    selection: path,
    picked: get().picked.includes(path) ? get().picked : [path],
    sidecar,
    nativeSize: null,
    metadata: null,
    badge: null,
    undo: [],
    redo: [],
    imageVersion: get().imageVersion + 1,
    view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 },
    showingOriginal: false,
    status: tz(`Opening ${baseName(path)}…`, `正在打开 ${baseName(path)}…`),
  });
  void loadOriginal(path, gen);
  await develop(path, gen);
}

async function loadOriginal(path: string, gen: number) {
  try {
    const img = await host().thumbnail(path, 2048);
    if (gen !== openGen) return;
    frameImages.original = img;
    set({ imageVersion: get().imageVersion + 1 });
  } catch {
    /* no original to compare against; the print still shows */
  }
}

async function develop(path: string, gen: number) {
  if (get().hostState.phase !== 'ready') {
    set({ status: tz('Waiting for the engine…', '正在等待引擎…') });
    return;
  }
  set({ developing: true });
  try {
    const t0 = performance.now();
    const params = get().sidecar.params;
    const r = await host().open(path, wireParams(params));
    if (gen !== openGen) {
      void host().close(r.session).catch(() => {});
      return;
    }
    sentParams = params;
    set({ engineSession: r.session, nativeSize: { width: r.width, height: r.height }, metadata: r.metadata });
    platform().log(
      'info',
      `session: open path (ms): decode ${r.timings_ms?.decode ?? '?'} · open ${r.timings_ms?.open ?? '?'} · TOTAL ${Math.round(performance.now() - t0)} · core=${get().hello?.capabilities?.backend?.render_core ?? '?'}`,
    );
    recomputeFilmFormat();
    // `recomputeFilmFormat` may have queued a render already.
    if (!inFlight) await requestPrint();
    const sc = get().sidecar;
    if (sc.state === 'unprocessed') {
      set({ sidecar: { ...sc, state: 'processed' } });
      scheduleSave();
    }
  } catch (e) {
    noteError(tz(`Opening ${baseName(path)}`, `打开 ${baseName(path)}`), e);
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
  setParams((p) => ({
    ...p,
    exposureCompensationEV: 0,
    autoExposure: true,
    autoExposureMethod: 'balanced',
    printBrightnessStops: 0,
    yFilterShift: 0,
    mFilterShift: 0,
    preflashExposure: 0,
  }));
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
  if (!clipChanges(clip, target)) return false;
  const next = applyClip(clip, target);
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
  if (targets.includes(s.selection) && clipChanges(clip, get().sidecar)) {
    const next = applyClip(clip, get().sidecar);
    setParams(() => next.params);
    set({ sidecar: { ...get().sidecar, decode: next.decode, placementNeedsFit: next.placementNeedsFit } });
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

export const ZOOM_STEPS = [0.0625, 0.125, 0.25, 0.333, 0.5, 0.667, 1, 2, 3, 4, 8, 16];

export function setView(v: Partial<ViewState>) {
  set({ view: { ...get().view, ...v } });
}
export function zoomToFit() {
  setView({ fit: true, cx: 0.5, cy: 0.5 });
}
export function zoomTo(zoom: number) {
  setView({ fit: false, zoom });
}
/** `fitZoom` is the zoom the fit currently implies (the canvas knows it). */
export function zoomStep(dir: 1 | -1, fitZoom: number) {
  const cur = get().view.fit ? fitZoom : get().view.zoom;
  const next = dir > 0 ? ZOOM_STEPS.find((z) => z > cur * 1.001) : [...ZOOM_STEPS].reverse().find((z) => z < cur * 0.999);
  if (next) setView({ fit: false, zoom: next });
}
export let currentFitZoom = 1;
export function noteCanvasPx(width: number, height: number) {
  const c = get().canvasPx;
  if (c.width !== width || c.height !== height) set({ canvasPx: { width, height } });
}
export function noteFitZoom(z: number) {
  currentFitZoom = z;
  if (Math.abs(get().fitZoom - z) > 1e-4) set({ fitZoom: z });
}

export function setTool(tool: Tool) {
  set({ tool });
}
export function setOriginal(on: boolean) {
  set({ showingOriginal: on });
}
export function toggleCompare() {
  set({ comparing: !get().comparing });
}
export function setComparePosition(p: number) {
  const v = clamp(p, 0, 1);
  if (v !== get().comparePosition) set({ comparePosition: v });
}

export function setPages(p: Partial<Pick<SessionState, 'exportOpen' | 'settingsOpen' | 'aboutOpen' | 'batchExporting' | 'clipboardGroups'>>) {
  set(p);
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
      gate: featureGate(unsupported, settingsStore.getState().diBlueCompensation),
    });
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
  host().onState(takeHostState);
  void loadCatalog().then((catalog) => set({ catalog }));
  takeHostState(await host().state());
  platform().onOpenPaths((paths) => void openPaths(paths));
  platform().onDrop((paths) => void openPaths(paths));
  const launch = await platform().takeLaunchPaths();
  if (launch.length) await openPaths(launch);
  window.addEventListener('beforeunload', () => void flushSave());
}

/** For tests and the export run. */
export function _internals() {
  return { get, set };
}
