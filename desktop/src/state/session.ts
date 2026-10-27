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

import type { RenderReply } from '../host/client';
import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import type { HelloResult, HostState, FileMetadata, PairInfo, Tier } from '@shared/protocol';
import { type PairDocument, type PairSide, type PairLayer, type PairHole, type PrintTrim, decodePair, encodePair, pairHole, pairParams, isPairPath } from '@shared/pairs';
import {pairHasPresentation,presentationRects,filmPrint,samePairDecode} from '@shared/pairPresentation';
import {mergePairMeter} from '@shared/pairMeter';
import type {Placement,PlacementDraft} from '@shared/pairPlacement';
import {selectedFilm,selectedPaper} from '@shared/stocks';
import {presentPair} from '../canvas/pairPresenter';
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
import { engineGeometry, hasFilmFrame, geometryInNegative, cutsFrame, gateGeometry, frameProjection, pairProjection, dateProjection, type FrameLayout } from '@shared/filmFrame';
import { resolveImprints } from '@shared/imprints';
import { seedFilmEdge } from '@shared/filmSeeds';
import { type DecodeSettings, type Sidecar, decodeSidecar, encodeSidecar, newSidecar } from '@shared/sidecar';
import { decodeWire, isRawPath, modeOf } from '@shared/whiteBalance';
import { type ClipboardGroup, type SettingsClip, CLIPBOARD_GROUPS, applyClip, clipChanges } from '@shared/clipboard';
import { EMPTY_CATALOG, type StockCatalog, loadCatalog } from '@shared/stocks';
import { HostCallError, host } from '../host/client';
import { type FileEntry, baseName, dirName, platform } from '../platform';
import { settingsStore, filmEdgeBodySeed } from './settings';
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
  decode: DecodeSettings;
  pair?: PairDocument|null;
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
  /** The open frame's kind as the host decoded it (`raw`, `tiff`, …); null until it lands. */
  frameKind: string | null;
  pairDocument: PairDocument|null;
  pairInfo: PairInfo|null;
  pairSide: PairSide;
  pairLayer:PairLayer;
  pairPlacing:boolean;
  pairPlacementDraft:PlacementDraft|null;
  pairUpdating: boolean;
  pairSaveError: string|null;
  /** A decode-setting change (white balance) is being re-decoded. */
  redecoding: boolean;
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
  frameKind: null,
  pairDocument:null,
  pairInfo:null,
  pairSide:'left',
  pairLayer:'film',
  pairPlacing:false,
  pairPlacementDraft:null,
  pairUpdating:false,
  pairSaveError:null,
  redecoding: false,
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
let sentGeometry = '';
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
  const s = get();
  const resolved = s.pairDocument?pairParams(p,s.pairInfo,s.pairDocument):resolveImprints(p, s.metadata, aspectOf(), s.sidecar.geometry, s.nativeSize);
  return { ...fullDelta(resolved, s.gate), ...engineGeometry(resolved, s.sidecar.geometry, s.nativeSize, s.gate), preview_long_edge: previewEdge() };
}

/** The open frame's derived imprint/camera state, without changing its sidecar. */
export function resolvedParams(): FilmParams {
  const s = get();
  return s.pairDocument?pairParams(s.sidecar.params,s.pairInfo,s.pairDocument):resolveImprints(s.sidecar.params, s.metadata, aspectOf(), s.sidecar.geometry, s.nativeSize);
}

async function frameMetadata(r: RenderReply, sid: string, s: SessionState) {
  const p = s.pairDocument?pairParams(s.sidecar.params,s.pairInfo,s.pairDocument):resolveImprints(s.sidecar.params, s.metadata, aspectOf(), s.sidecar.geometry, s.nativeSize);
  if (!s.nativeSize || (!s.pairDocument&&!cutsFrame(p, s.sidecar.geometry, s.gate))) return;
  if (!hasFilmFrame(p, s.gate)) {
    r.frame = dateProjection(s.nativeSize, s.sidecar.geometry);
    if(s.pairInfo)r.pairRects=presentationRects(null,s.pairInfo.rects);
    return;
  }
  const reply = await host().transport.request('overscan_geometry', { session: sid });
  const scale = r.tier === 'full' ? 1 : Math.max(1, Math.max(s.nativeSize.width, s.nativeSize.height) / previewEdge());
  if(s.pairDocument&&s.pairInfo) {
    r.pairRects=presentationRects(reply.result as unknown as FrameLayout,s.pairInfo.rects);
    r.frame=pairProjection(reply.result as unknown as FrameLayout,s.pairInfo.rects,
      {width:Math.round(r.width*scale),height:Math.round(r.height*scale)})??undefined;
    return;
  }
  r.frame = frameProjection(reply.result as unknown as FrameLayout, s.nativeSize,
    gateGeometry(s.sidecar.params, s.sidecar.geometry, s.nativeSize),
    { width: Math.round(r.width * scale), height: Math.round(r.height * scale) }) ?? undefined;
}
async function finishRender(r:RenderReply,sid:string,s:SessionState) {
  await frameMetadata(r,sid,s);
  if(s.pairDocument&&pairHasPresentation(s.pairDocument,s.sidecar.params,s.sidecar.adjustments)) {
    if(!s.hello?.methods?.includes('render_layer')||!r.pairRects)throw new Error('This host cannot present per-hole print/grade layers');
    Object.assign(r,await presentPair(r,s.pairDocument,s.sidecar.params,s.sidecar.adjustments,r.pairRects,
      delta=>host().renderLayer(sid,r.tier,delta)));
    platform().log('info',`session: composed per-hole prints/grades ${r.width}x${r.height} (${r.tier})`);
  }
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
  if (inFlight) return;
  const sid = get().engineSession;
  if (!sid) return;
  inFlight = true;
  try {
    for (;;) {
      const gen = wantedGen;
      const s = get();
      if (s.engineSession !== sid) return;
      const want = s.pairDocument?pairParams(s.sidecar.params,s.pairInfo,s.pairDocument):resolveImprints(s.sidecar.params, s.metadata, aspectOf(), s.sidecar.geometry, s.nativeSize);
      const d = sentParams ? paramsDelta(want, sentParams, s.gate) : { delta: wireParams(want), layers: new Set(['shoot']) };
      const gd = engineGeometry(want, s.sidecar.geometry, s.nativeSize, s.gate);
      const geometryKey = JSON.stringify(gd);
      if (geometryKey !== sentGeometry) { Object.assign(d.delta, gd); d.layers.add('shoot'); }
      if (Object.keys(d.delta).length) {
        await host().setParams(sid, d.delta);
        if(s.pairDocument) {
          const info=await host().transport.request('pair_info',{session:sid});
          if(get().engineSession===sid) {
            const pairInfo=info.result as unknown as PairInfo;
            set({pairInfo});if(pairInfo&&s.pairDocument)retainPairReadings(pairInfo,s.pairDocument);
          }
        }
        sentParams = want;
        sentGeometry = geometryKey;
      }
      const reprint = d.layers.size === 1 && d.layers.has('print');
      const r = await host().render(sid, 'live', { reprint });
      await finishRender(r, sid, s);
      if (get().engineSession !== sid) return;
      frameImages.print = r;
      placementLanded(s);
      set({ imageVersion: get().imageVersion + 1, badge: 'preview', status: '',lastError:null });
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
    await finishRender(r, sid, s);
    // Dropped when the generation, selection or session moved (ARCHITECTURE §7.3).
    if (gen !== wantedGen || get().engineSession !== sid) return;
    frameImages.print = r;
    placementLanded(s);
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
  const image = frameImages.print;
  if (!s.selection || !image) return;
  const url = await makeThumbFromPrint(image);
  if (url && get().selection === s.selection && frameImages.print === image) {
    thumbs.setPrint(s.selection, url, !!image.frame);
    set({ thumbVersion: get().thumbVersion + 1 });
  } else if (url) URL.revokeObjectURL(url);
}

// -------------------------------------------------------------- persistence

function scheduleSave() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => void flushSave(), 500);
}

export async function flushSave(strict=false): Promise<void> {
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
    if(strict){scheduleSave();throw e;}
  }
}

function pushUndo() {
  const now = performance.now();
  if (now - lastUndoAt < 500) return;
  lastUndoAt = now;
  const sc = get().sidecar;
  const undo = [...get().undo, { params: sc.params, adjustments: sc.adjustments, geometry: sc.geometry, decode: sc.decode,pair:get().pairDocument }].slice(-60);
  set({ undo, redo: [] });
}

/** The single door for a Layer 1 edit. */
export function setParams(fn: (p: FilmParams) => FilmParams) {
  const s = get();
  if (s.batchExporting) return;
  let next = fn(s.sidecar.params);
  if(s.pairDocument) next={...next,autoExposure:false,filmEdge:{...next.filmEdge,pair:true,format:'135_half'}};
  if (jsonEqual(next, s.sidecar.params)) return;
  pushUndo();
  set({ sidecar: { ...get().sidecar, params: next, state: get().sidecar.state === 'processed' ? 'stale' : get().sidecar.state } });
  scheduleSave();
  if(s.pairDocument&&s.pairDocument.onStrip!==next.filmEdge.active) {queuePairDocument({...s.pairDocument,onStrip:next.filmEdge.active});return;}
  void requestPrint();
}

/** Stock choices use the same pairing/stage rules from every UI entry point. */
export function selectFilmStock(id:string){setParams(p=>selectedFilm(p,id,get().catalog));}
export function selectPrintStock(id:string){setParams(p=>selectedPaper(p,id,get().catalog));}

/** Another camera body becomes the default for future frames, as on the Mac. */
export function anotherCamera() {
  if (get().batchExporting) return;
  const seed = (get().sidecar.params.filmEdge.cameraSeed + 1) % 2147483647;
  settingsStore.getState().set('filmEdgeBodySeed', seed);
  setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, cameraSeed: seed } }));
}

/** A Layer 2 edit: one draw. */
export function setAdjustments(fn: (a: Adjustments) => Adjustments) {
  const s = get();
  if (s.batchExporting) return;
  const current=editingAdjustments(s),next = fn(current);
  if (jsonEqual(next,current)) return;
  if(s.pairDocument&&s.pairLayer!=='film') {
    updatePair(p=>p[s.pairLayer as PairSide]?{...p,[s.pairLayer]:{...p[s.pairLayer as PairSide]!,adjustments:next}}:p,false);return;
  }
  pushUndo();
  set({ sidecar: { ...s.sidecar, adjustments: next } });
  scheduleSave();
  if(s.pairDocument&&(frameImages.print?.pregraded||pairHasPresentation(s.pairDocument,s.sidecar.params,next)))void requestPrint();
}
export function editingAdjustments(s:SessionState):Adjustments {
  return s.pairDocument&&s.pairLayer!=='film'?(s.pairDocument[s.pairLayer]?.adjustments??s.sidecar.adjustments):s.sidecar.adjustments;
}
export function editingPrint(s:SessionState):PrintTrim {
  return s.pairDocument&&s.pairLayer!=='film'?(s.pairDocument[s.pairLayer]?.print??filmPrint(s.sidecar.params)):filmPrint(s.sidecar.params);
}
const printKey={brightnessStops:'printBrightnessStops',yFilterShift:'yFilterShift',mFilterShift:'mFilterShift',preflashExposure:'preflashExposure'} as const;
const boundPrint=(key:keyof PrintTrim,v:number)=>clamp(v,key==='preflashExposure'?0:key==='brightnessStops'?-3:-1,key==='preflashExposure'?.03:key==='brightnessStops'?3:1);
export function setEnlarger(key:keyof PrintTrim,value:number) {
  const s=get();if(s.batchExporting)return;
  const current=editingPrint(s),v=boundPrint(key,value),moved=v-current[key];if(!moved)return;
  const film=filmPrint(s.sidecar.params),side=s.pairLayer;
  if(s.pairDocument&&side!=='film') {
    if(!s.pairDocument[side])return;
    const scope=s.pairDocument[side]!.printScope??'film';
    updatePair(p=>{
      const q={...p};for(const k of ['left','right'] as const)if(q[k]&&!q[k]!.print)q[k]={...q[k]!,print:film};
      q[side]={...q[side]!,print:{...q[side]!.print!,[key]:v}};return q;
    },false);
    if(scope==='film')setParams(p=>({...p,[printKey[key]]:boundPrint(key,film[key]+moved)}));
  } else {
    if(s.pairDocument)updatePair(p=>{
      const q={...p};for(const k of ['left','right'] as const)if(q[k]?.print)q[k]={...q[k]!,print:{...q[k]!.print!,[key]:boundPrint(key,q[k]!.print![key]+moved)}};return q;
    },false);
    setParams(p=>({...p,[printKey[key]]:v}));
  }
}
export function resetEnlarger() {
  const s=get();if(s.batchExporting)return;
  const zero:PrintTrim={brightnessStops:0,yFilterShift:0,mFilterShift:0,preflashExposure:0};
  if(s.pairDocument&&s.pairLayer!=='film'){
    const side=s.pairLayer,film=filmPrint(s.sidecar.params);
    updatePair(p=>{const q={...p};for(const k of ['left','right'] as const)if(q[k]&&!q[k]!.print)q[k]={...q[k]!,print:film};if(q[side])q[side]={...q[side]!,print:zero};return q;},false);
  } else {
    if(s.pairDocument)updatePair(p=>({...p,left:p.left?{...p.left,print:null}:null,right:p.right?{...p.right,print:null}:null}),false);
    setParams(p=>({...p,printBrightnessStops:0,yFilterShift:0,mFilterShift:0,preflashExposure:0}));
  }
}

/** A geometry edit: one draw (and the film format, when a crop re-maps it). */
export function setGeometry(fn: (g: Geometry) => Geometry, opts: { coalesce?: boolean } = {}) {
  const s = get();
  if (s.batchExporting) return;
  if(s.pairDocument) return;
  const next = fn(s.sidecar.geometry);
  if (jsonEqual(next, s.sidecar.geometry)) return;
  if (!opts.coalesce) pushUndo();
  set({ sidecar: { ...s.sidecar, geometry: next }, savedGeometry: s.selection ? { ...s.savedGeometry, [s.selection]: next } : s.savedGeometry });
  scheduleSave();
  if (settingsStore.getState().recalculateEffectsAfterCrop) recomputeFilmFormat();
  if (geometryInNegative(resolveImprints(s.sidecar.params, s.metadata, aspectOf()), s.gate)) void requestPrint();
}

/**
 * A decode edit (camera white balance): the host decodes the file again
 * (`redecode`, R2) and the frame re-renders with the same params. Debounced:
 * a decode is the slow part of an open, so a drag decodes once it settles.
 */
export function setDecode(fn: (d: DecodeSettings) => DecodeSettings) {
  const s = get();
  if (s.batchExporting||s.pairDocument) return;
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
  if (decodeTimer) clearTimeout(decodeTimer);
  // Whatever full render was coming would show the old decode.
  if (fullTimer) clearTimeout(fullTimer);
  wantedGen++;
  decodeTimer = setTimeout(() => void redecodeNow(), REDECODE_DELAY_MS);
}

async function redecodeNow() {
  decodeTimer = null;
  const s = get();
  const sid = s.engineSession;
  if (!sid || !s.selection) return;
  const wire = decodeWire(s.sidecar.decode, isRawFrame());
  const key = JSON.stringify(wire);
  if (!wire || key === sentDecode || !hostRedecodes(s.hello?.methods)) {
    void requestPrint();
    return;
  }
  set({ redecoding: true, status: tz('Decoding with the new white balance…', '正在以新的白平衡解码…') });
  try {
    const r = await host().redecode(sid, wire);
    if (get().engineSession !== sid) return;
    sentDecode = key;
    set({ nativeSize: { width: r.width, height: r.height }, metadata: r.metadata ?? get().metadata, status: '' });
    void requestPrint();
  } catch (e) {
    noteError(tz('White balance', '白平衡'), e);
  } finally {
    set({ redecoding: false });
  }
}

function isRawFrame(): boolean {
  const s = get();
  if (s.frameKind) return s.frameKind === 'raw';
  return !!s.selection && isRawPath(s.selection);
}

export function beginGesture() {
  if (get().batchExporting) return;
  pushUndo();
  lastUndoAt = performance.now();
}

function restore(e: UndoEntry) {
  const s = get();
  const decodeMoved = !jsonEqual(e.decode, s.sidecar.decode);
  set({ sidecar: { ...s.sidecar, params: e.params, adjustments: e.adjustments, geometry: e.geometry, decode: e.decode } });
  scheduleSave();
  if(e.pair&&s.pairDocument&&!jsonEqual(e.pair,s.pairDocument)) {queuePairDocument(e.pair,!samePairDecode(e.pair,s.pairDocument));return;}
  if (decodeMoved) scheduleRedecode();
  else void requestPrint();
}

export function undo() {
  if(get().batchExporting||!get().selection)return;
  commitPairPlacement();set({pairPlacementDraft:null});
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const prev = s.undo[s.undo.length - 1];
  if (!prev) return;
  const cur = { params: s.sidecar.params, adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry, decode: s.sidecar.decode,pair:s.pairDocument };
  set({ undo: s.undo.slice(0, -1), redo: [...s.redo, cur] });
  lastUndoAt = 0;
  restore(prev);
  set({ status: tz(`Undo — ${get().undo.length} steps left.`, `撤销 — 还剩 ${get().undo.length} 步。`) });
}

export function redo() {
  if(get().batchExporting||!get().selection)return;
  commitPairPlacement();set({pairPlacementDraft:null});
  const s = get();
  if (s.batchExporting || !s.selection) return;
  const next = s.redo[s.redo.length - 1];
  if (!next) return;
  const cur = { params: s.sidecar.params, adjustments: s.sidecar.adjustments, geometry: s.sidecar.geometry, decode: s.sidecar.decode,pair:s.pairDocument };
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
  const pair=get().pairDocument;
  if(pair) return clamp((36+(get().sidecar.params.filmEdge.active?1:pair.spacingMM))*filmFormatMM(side,mm,24/18)/24,4,200);
  return filmFormatMM(side, mm, aspectOf(), cropScale());
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

const pairCache=new Map<string,PairDocument>();
let pairDirty:PairDocument|null=null;
let pairDirtyDecode=false;
let pairDirtyRender=false;
let pairTimer:ReturnType<typeof setTimeout>|null=null;
let pairWork:Promise<void>=Promise.resolve();
function queuePairDocument(doc:PairDocument,redecode=true,render=true) {
  const s=get(); if(!s.selection) return;
  pairCache.set(s.selection,doc); pairDirty=doc;
  pairDirtyDecode ||= redecode;
  pairDirtyRender ||= render;
  set({pairDocument:doc,pairUpdating:true,pairSaveError:null,...(render?{badge:'preview' as const}:{})});
  if(render){wantedGen++; if(fullTimer) clearTimeout(fullTimer);}
  if(pairTimer) clearTimeout(pairTimer);
  pairTimer=setTimeout(()=>{void flushPairChanges().catch(()=>{});},300);
}
export async function flushPairChanges(render=true):Promise<void> {
  commitPairPlacement();
  if(pairTimer) {clearTimeout(pairTimer);pairTimer=null;}
  const doc=pairDirty,s=get(),path=s.selection,gen=openGen,redecode=pairDirtyDecode,shouldRender=render&&pairDirtyRender;
  if(!doc||!path) return pairWork;
  pairDirty=null;
  pairDirtyDecode=false;
  pairDirtyRender=false;
  pairWork=pairWork.catch(()=>{}).then(async()=>{
    try {
      await platform().pairSave(path,encodePair(doc));
      if(pairCache.get(path)===doc) pairCache.delete(path);
      if(!shouldRender||get().selection!==path||openGen!==gen||get().pairDocument!==doc) return;
      while(inFlight&&get().selection===path&&openGen===gen) await new Promise(r=>setTimeout(r,20));
      if(get().selection!==path||openGen!==gen||get().pairDocument!==doc) return;
      if(!redecode&&get().engineSession){await requestPrint();return;}
      await flushSave(); await closeEngineSession();
      set({developing:true});
      await develop(path,gen);
      void loadOriginal(path,gen);
    } catch(e) {
      if(get().selection===path) {set({pairSaveError:e instanceof Error?e.message:String(e)});noteError(tz('Updating the pair','更新合片'),e);}
      throw e;
    } finally {
      if(get().selection===path&&get().pairDocument===doc&&!pairDirty) set({pairUpdating:false});
    }
  });
  return pairWork;
}
export function retryPairSave() {
  const doc=get().pairDocument;
  if(doc&&!get().batchExporting) queuePairDocument(doc);
}
/** A meter reading is saved metadata, never an undo step or a new develop. */
export function retainPairReadings(info:PairInfo,opened:PairDocument) {
  const live=get().pairDocument;if(!live)return;
  const next=mergePairMeter(live,opened,info);
  if(next!==live)queuePairDocument(next,false,false);
}
/** The export lock is already held: drain the current edit and decode queues. */
export async function flushPendingEdits() {
  await flushPairChanges();
  const until=performance.now()+600_000;
  while(inFlight||decodeTimer||get().developing||get().redecoding||get().pairUpdating) {
    if(performance.now()>until)throw new Error('Timed out waiting for the current edits to finish');
    await new Promise(r=>setTimeout(r,25));
  }
}
export function setPairSide(side:PairSide) {
  if(get().batchExporting||!get().pairDocument)return;
  if(get().pairSide!==side)commitPairPlacement();
  const s=get(); if(s.pairSide===side&&s.pairLayer===side) return;
  const p=s.sidecar.params, right=side==='right';
  const params=p.placementIsRight===right?p:{...p,placementIsRight:right,sceneLatitude:p.sceneLatitudeOther,sceneLatitudeOther:p.sceneLatitude};
  set({pairSide:side,pairLayer:side,sidecar:{...s.sidecar,params}});scheduleSave();
}
export function setPairFilm(){if(!get().batchExporting){endPairPlacing();set({pairLayer:'film'});}}

export function togglePairPlacing(){
  const s=get();if(s.batchExporting||!s.pairDocument)return;
  if(s.pairPlacing){endPairPlacing();return;}
  const side=s.pairLayer!=='film'&&s.pairDocument[s.pairLayer]?s.pairLayer:s.pairDocument.left?'left':s.pairDocument.right?'right':null;
  if(!side)return;setPairSide(side);set({pairPlacing:true,tool:'select'});
}
export function endPairPlacing(){commitPairPlacement();set({pairPlacing:false});}
export function previewPairPlacement(side:PairSide,live:Placement){
  const s=get(),h=s.pairDocument?.[side];if(s.batchExporting||!s.pairPlacing||!s.selection||!h)return;
  const d=s.pairPlacementDraft;
  const before=d&&!d.settling&&d.selection===s.selection&&d.side===side?d.before:h;
  set({pairPlacementDraft:{selection:s.selection,side,before,live,settling:false}});
}
export function commitPairPlacement(){
  const s=get(),d=s.pairPlacementDraft;if(!d||d.settling)return;
  const h=s.pairDocument?.[d.side];
  if(!h||s.selection!==d.selection||h.path!==d.before.path||!jsonEqual(h.geometry,d.before.geometry)||!jsonEqual(h.decode,d.before.decode)||!jsonEqual(h.placement,d.before.placement)){
    set({pairPlacementDraft:null});return;
  }
  if(jsonEqual(h.placement,d.live)){set({pairPlacementDraft:null});return;}
  // Pending gestures also flush under the export lock. This commits existing
  // input; it does not permit a new user edit during an export.
  lastUndoAt=0;pushUndo();set({pairPlacementDraft:{...d,settling:true}});
  queuePairDocument({...s.pairDocument!,[d.side]:{...h,placement:d.live}});
}
function placementLanded(s:SessionState){
  const d=get().pairPlacementDraft;
  if(d?.settling&&d.selection===s.selection&&jsonEqual(s.pairDocument?.[d.side]?.placement,d.live))set({pairPlacementDraft:null});
}
export function setPairExposure(value:number) {
  const s=get(),side=s.pairSide,h=s.pairDocument?.[side];if(s.batchExporting||!h)return;
  const v=clamp(value,-5,5),moved=v-h.exposureEV;if(!moved)return;
  if(h.exposureScope==='film') {
    const film=filmPrint(s.sidecar.params);
    updatePair(p=>{const q={...p};for(const k of ['left','right'] as const)if(q[k]&&!q[k]!.print)q[k]={...q[k]!,print:film};q[side]={...q[side]!,exposureEV:v};return q;});
    const p=get().sidecar.params;
    set({sidecar:{...get().sidecar,params:{...p,printBrightnessStops:clamp(p.printBrightnessStops+moved,-3,3)}}});scheduleSave();
  } else updatePairHole(h=>({...h,exposureEV:v}));
}
export function updatePair(fn:(p:PairDocument)=>PairDocument,redecode=true) {
  const s=get(); if(s.batchExporting||!s.pairDocument) return;
  const next=fn(s.pairDocument); if(jsonEqual(next,s.pairDocument)) return;
  pushUndo(); queuePairDocument(next,redecode);
}
export function updatePairHole(fn:(h:PairHole)=>PairHole,redecode=true) {
  const side=get().pairSide;
  updatePair(p=>p[side]?{...p,[side]:fn(p[side])}:p,redecode);
}
export async function replacePairHole() {
  const s=get(); if(s.batchExporting||!s.pairDocument) return;
  const paths=await platform().pickFiles(tz('Choose the photograph for this hole','选择这一孔的照片'));
  const path=paths.find(p=>!isPairPath(p)); if(!path||get().selection!==s.selection||get().batchExporting) return;
  const raw=await platform().sidecarLoad(path).catch(()=>null), source=raw?decodeSidecar(raw):newSidecar();
  if(get().selection!==s.selection||get().batchExporting) return;
  updatePair(p=>({...p,[s.pairSide]:pairHole(path,source.geometry,source.decode)}));
}
export async function createPair() {
  const s=get(); if(s.batchExporting||!s.folder||s.hello?.capabilities?.backend?.pair_decode!==true) return;
  const selected=s.frames.filter(f=>s.picked.includes(f.path)&&!isPairPath(f.path)).slice(0,2);
  const make=async(path:string)=>{
    const source=path===s.selection?s.sidecar:decodeSidecar(await platform().sidecarLoad(path).catch(()=>null));
    return pairHole(path,source.geometry,source.decode);
  };
  try {
    await flushPairChanges(false); await flushSave();
    const doc:PairDocument={schemaVersion:1,folder:s.folder,left:selected[0]?await make(selected[0].path):null,
      right:selected[1]?await make(selected[1].path):null,spacingMM:1,onStrip:s.sidecar.params.filmEdge.active,turned:false};
    if(get().batchExporting||get().folder!==s.folder) return;
    const entry=await platform().pairCreate(s.folder,encodePair(doc));
    const sc={...newSidecar(),params:{...s.sidecar.params,autoExposure:false,exposureCompensationEV:0,filmFormatMM:37,filmFrame:'Custom',filmSide:'long' as const,sideLengthMM:24,
      filmEdge:{...s.sidecar.params.filmEdge,pair:true,format:'135_half',seeded:false}},adjustments:s.sidecar.adjustments};
    await platform().sidecarSave(entry.path,encodeSidecar(sc));
    set({frames:[...get().frames,entry]}); await select(entry.path);
  } catch(e) {noteError(tz('Creating a half-frame pair','创建半格配对'),e);}
}

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
      const dir = isPairPath(entries[0]!.path)?decodePair(await platform().pairLoad(entries[0]!.path)).folder:dirName(entries[0]!.path);
      const all = await platform().listImages(dir).catch(() => entries);
      await setLibrary(dir, all.some(e=>e.path===entries[0]!.path)?all:[...all,...entries]);
      await select(entries[0]!.path);
      return;
    }
    const known = new Set(get().frames.map((f) => f.path));
    if (entries.every((e) => known.has(e.path))) {
      await select(entries[0]!.path);
      return;
    }
    const folder = paths.length === 1 ? paths[0]! : dirName(entries[0]!.path);
    const files=paths.length===1?await platform().listImages(folder).catch(()=>entries):entries;
    await setLibrary(folder,files);
    await select(entries[0]!.path);
  } catch (e) {
    noteError(tz('Opening', '打开'), e);
  }
}

async function setLibrary(folder: string, files: FileEntry[]) {
  await flushPairChanges(false);
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
  sentGeometry = '';
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
    void select(path).catch(e=>noteError(tz('Opening','打开'),e));
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
  await flushPairChanges(false);
  await flushSave();
  await closeEngineSession();
  frameImages.print = null;
  frameImages.original = null;
  const raw = await platform().sidecarLoad(path).catch(() => null);
  if (gen !== openGen) return;
  const loaded = raw ? decodeSidecar(raw) : newSidecar();
  const pair=isPairPath(path)?decodePair(pairCache.get(path)??await platform().pairLoad(path)):null;
  if(gen!==openGen) return;
  if(pair) {
    loaded.geometry=GEOMETRY_DEFAULT;
    if(!raw||(loaded.params.filmFrame==='135'&&loaded.params.filmSide==='short'&&loaded.params.sideLengthMM===24))
      loaded.params={...loaded.params,filmFrame:'Custom',filmSide:'long',sideLengthMM:24};
    loaded.params={...loaded.params,autoExposure:false,filmFormatMM:raw?loaded.params.filmFormatMM:24,
      filmEdge:{...loaded.params.filmEdge,pair:true,format:'135_half',active:raw?loaded.params.filmEdge.active:pair.onStrip}};
  } else loaded.params={...loaded.params,filmEdge:{...loaded.params.filmEdge,pair:false}};
  const seeded = await seedFilmEdge(loaded.params, path, get().frames.findIndex(f => f.path === path), filmEdgeBodySeed());
  if (gen !== openGen) return;
  const sidecar = seeded === loaded.params ? loaded : { ...loaded, params: seeded };
  set({
    selection: path,
    picked: get().picked.includes(path) ? get().picked : [path],
    sidecar,
    nativeSize: null,
    metadata: null,
    frameKind: null,
    pairDocument:pair,pairInfo:null,pairSide:loaded.params.placementIsRight?'right':'left',pairLayer:'film',pairPlacing:false,pairPlacementDraft:null,pairUpdating:false,pairSaveError:null,
    badge: null,
    undo: [],
    redo: [],
    imageVersion: get().imageVersion + 1,
    view: { fit: true, zoom: 1, cx: 0.5, cy: 0.5 },
    showingOriginal: false,
    status: tz(`Opening ${baseName(path)}…`, `正在打开 ${baseName(path)}…`),
    lastError:null,
  });
  void loadOriginal(path, gen);
  if (seeded !== loaded.params) scheduleSave();
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
  set({ developing: true,lastError:null });
  try {
    const t0 = performance.now();
    const params = resolvedParams();
    const decode = get().pairDocument?null:decodeWire(get().sidecar.decode, isRawPath(path));
    const measuredPair=get().pairDocument;
    let r;
    try {
      r = await host().open(path, wireParams(params), decode);
    } catch (e) {
      // A host without R2 refuses the decode key: open with the camera's own.
      if (!(decode && e instanceof HostCallError && e.code === 'unsupported')) throw e;
      r = await host().open(path, wireParams(params));
    }
    if (gen !== openGen) {
      void host().close(r.session).catch(() => {});
      return;
    }
    sentParams = params;
    sentDecode = JSON.stringify(decode);
    set({ engineSession: r.session, nativeSize: { width: r.width, height: r.height }, metadata: r.metadata, frameKind: r.kind ?? (isRawPath(path) ? 'raw' : null),pairInfo:r.pair??null });
    if(r.pair&&measuredPair)retainPairReadings(r.pair,measuredPair);
    noteAsShot();
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
    await host().solve(s.engineSession, s.pairDocument?'filter_pack':'both');
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
    const decodeMoved = !jsonEqual(next.decode, get().sidecar.decode);
    set({ sidecar: { ...get().sidecar, decode: next.decode, placementNeedsFit: next.placementNeedsFit } });
    if (decodeMoved) scheduleRedecode();
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
  if(get().pairDocument&&tool==='crop'){togglePairPlacing();return;}
  if(get().pairPlacing)endPairPlacing();
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
  window.addEventListener('beforeunload', () => {void flushPairChanges(false).catch(()=>{});void flushSave();});
}

/** For tests and the export run. */
export function _internals() {
  return { get, set };
}
