// Canvas.tsx — the picture: WebGL2 draw, fit / 100 % / zoom / pan, the crop
// tool's overlay, the before/after split, the histogram and the tier badge.
//
// Gestures (Capture One's, as the Mac app has them): wheel zooms about the
// pointer; drag pans with the Hand tool (H), with the middle button, or with
// the Select tool while zoomed in; Space held shows the original. Zoom is in
// *native* pixels per device pixel, so "100 %" is the frame's own pixels
// whatever tier is on the canvas (§7.3: zoom selects no tier).

import { useCallback, useEffect, useRef, useState } from 'react';
import { openDialog, openFilesDialog } from '../windows/actions';
import {
  type Geometry,
  type Point,
  GEOMETRY_DEFAULT,
  centre,
  handleAt,
  moved,
  outputPoint,
  outputSize,
  resized,
  sourcePoint,
  type CropHandle,
  handlePosition,
  CROP_HANDLES,
  isCorner,
  rotated,
  straightened,
  straightenAngle,
} from '@shared/geometry';
import { clamp } from '@shared/params';
import { canvasGeometryFor, geometryInNegative, sourceGeometryFor } from '@shared/filmEdge';
import { draggedPlacement, pairAspect, pairRects, PAIR_SIDES, PLACEMENT_DEFAULT, zoomedPlacement, type PairPlacement, type PairRect, type PairSide } from '@shared/pair';
import { GLRenderer, type DrawState } from './glRenderer';
import { frameImages } from '../state/frames';
import {
  beginGesture,
  choosePairHole,
  click,
  commitPairPlacement,
  pairCanvasRects,
  setPairHole,
  setPairLayer,
  setPairPlacement,
  togglePairPlacing,
  noteFitZoom,
  noteCanvasPx,
  noteDisplaySpace,
  noteTextureLimit,
  notePreviewDrawn,
  pickNeutralAt,
  sessionStore,
  setComparePosition,
  setGeometry,
  setOriginal,
  setView,
  useSession,
} from '../state/session';
import { HistogramOverlay, histogramOf, type Histogram } from './histogram';
import { publishOutput } from './output';
import { useI18n } from '../i18n';
import { useSettings } from '../state/settings';
import { resolveDisplaySpace } from './colorSpace';
import { inTauri } from '../host/transport';
import { onFrameDrop } from '../windows/frameDrag';
import { clampZoom } from './zoom';

const SURROUND = 0x5f / 255;

export interface Layout {
  viewport: { width: number; height: number };
  offset: { x: number; y: number };
  outSize: { width: number; height: number };
  out: { width: number; height: number };
  zoom: number;
  fitZoom: number;
  display: Geometry;
  native: { width: number; height: number };
}

export function displayGeometry(g: Geometry, cropping: boolean): Geometry {
  return cropping ? { ...GEOMETRY_DEFAULT, quarterTurns: g.quarterTurns, flipH: g.flipH, flipV: g.flipV } : g;
}

export function computeLayout(
  viewport: { width: number; height: number },
  native: { width: number; height: number },
  g: Geometry,
  cropping: boolean,
  view: { fit: boolean; zoom: number; cx: number; cy: number },
  margin: number,
): Layout {
  const display = displayGeometry(g, cropping);
  const out = outputSize(display, native);
  const fitZoom = Math.min((viewport.width - 2 * margin) / out.width, (viewport.height - 2 * margin) / out.height);
  const zoom = view.fit || cropping ? fitZoom : view.zoom;
  const outSize = { width: out.width * zoom, height: out.height * zoom };
  const cx = view.fit || cropping ? 0.5 : view.cx;
  const cy = view.fit || cropping ? 0.5 : view.cy;
  let ox = viewport.width / 2 - cx * outSize.width;
  let oy = viewport.height / 2 - cy * outSize.height;
  // Smaller than the canvas: centred on that axis.
  if (outSize.width <= viewport.width) ox = (viewport.width - outSize.width) / 2;
  if (outSize.height <= viewport.height) oy = (viewport.height - outSize.height) / 2;
  return { viewport, offset: { x: ox, y: oy }, outSize, out, zoom, fitZoom, display, native };
}

export function Canvas() {
  const { tz } = useI18n();
  const wrap = useRef<HTMLDivElement>(null);
  const canvas = useRef<HTMLCanvasElement>(null);
  const gl = useRef<GLRenderer | null>(null);
  const [size, setSize] = useState({ width: 0, height: 0, dpr: 1 });
  const [glError, setGlError] = useState<string | null>(null);
  const [histogram, setHistogram] = useState<Histogram | null>(null);
  const [straightenLine, setStraightenLine] = useState<{ from: Point; to: Point } | null>(null);
  const [pairMenu, setPairMenu] = useState<{ x: number; y: number; side: PairSide } | null>(null);
  const uploaded = useRef({ print: null as unknown, original: null as unknown });

  const imageVersion = useSession((s) => s.imageVersion);
  const geometry = useSession((s) => s.sidecar.geometry);
  const params = useSession((s) => s.sidecar.params);
  const noFilm = useSession((s) => s.sidecar.noFilm);
  const gate = useSession((s) => s.gate);
  const adjustments = useSession((s) => s.sidecar.adjustments);
  const nativeSize = useSession((s) => s.nativeSize);
  const view = useSession((s) => s.view);
  const tool = useSession((s) => s.tool);
  const comparing = useSession((s) => s.comparing);
  const comparePosition = useSession((s) => s.comparePosition);
  const showingOriginal = useSession((s) => s.showingOriginal);
  const badge = useSession((s) => s.badge);
  const developing = useSession((s) => s.developing);
  const lastError = useSession((s) => s.lastError);
  const selection = useSession((s) => s.selection);
  const batch = useSession((s) => s.batchExporting);
  const exportOpen = useSession((s) => s.exportOpen);
  const displaySpace = useSession((s) => s.displaySpace);
  const maxTextureSize = useSession((s) => s.maxTextureSize);
  const previewGamut = useSettings((s) => s.previewGamut);
  const originalFallback = !frameImages.print && !!frameImages.original;
  const cropping = tool === 'crop' && !originalFallback;
  const pair = useSession((s) => s.pair), pairLayer = useSession((s) => s.pairLayer), pairPlacing = useSession((s) => s.pairPlacing), pairInfo = useSession((s) => s.pairInfo);
  const pairGates = showingOriginal && pair ? pairRects(pair) : pairCanvasRects();
  const framing = cropping && geometryInNegative(params, gate, noFilm);
  const filmCanvas = !originalFallback && !cropping && !showingOriginal && !!sourceGeometryFor(params, geometry, gate, noFilm);
  const canvasGeometry = originalFallback ? GEOMETRY_DEFAULT : filmCanvas ? canvasGeometryFor(params, geometry, gate, noFilm) : geometry;

  useEffect(() => {
    if (!canvas.current) return;
    try {
      gl.current = new GLRenderer(canvas.current);
      noteTextureLimit(gl.current.maxTexture);
    } catch (e) {
      setGlError((e as Error).message);
    }
  }, []);

  // The browser owns the final monitor ICC conversion. Re-evaluate when the
  // window moves between displays; a requested P3 mode is used only when the
  // actual WebGL drawing buffer accepts it. Auto also requires a wide display.
  useEffect(() => {
    const renderer = gl.current;
    if (!renderer) return;
    const gamut = window.matchMedia('(color-gamut: p3)');
    const p3 = renderer.supportsP3();
    const refresh = () => {
      noteDisplaySpace(renderer.setDisplaySpace(resolveDisplaySpace(previewGamut, p3, gamut.matches)));
      const rect = wrap.current?.getBoundingClientRect();
      if (rect) setSize((old) => {
        const dpr = window.devicePixelRatio || 1;
        return old.width === rect.width && old.height === rect.height && old.dpr === dpr ? old
          : { width: rect.width, height: rect.height, dpr };
      });
    };
    refresh();
    gamut.addEventListener('change', refresh);
    window.addEventListener('focus', refresh);
    window.addEventListener('resize', refresh);
    let active = true;
    const unlisten: (() => void)[] = [];
    if (inTauri()) void import('@tauri-apps/api/window').then(async ({ getCurrentWindow }) => {
      const win = getCurrentWindow();
      for (const subscribe of [() => win.onMoved(refresh), () => win.onScaleChanged(refresh)]) {
        const off = await subscribe();
        if (active) unlisten.push(off);
        else off();
      }
    }).catch(() => { /* Media, focus and resize remain available on older hosts. */ });
    return () => {
      active = false;
      gamut.removeEventListener('change', refresh);
      window.removeEventListener('focus', refresh);
      window.removeEventListener('resize', refresh);
      for (const off of unlisten) off();
    };
  }, [previewGamut]);

  useEffect(() => {
    const el = wrap.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const r = el.getBoundingClientRect();
      setSize({ width: r.width, height: r.height, dpr: window.devicePixelRatio || 1 });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const native = originalFallback ? (frameImages.original!.nativeSize ?? { width: frameImages.original!.width, height: frameImages.original!.height })
    : (filmCanvas ? frameImages.print?.nativeSize : nativeSize) ?? (frameImages.print ? { width: frameImages.print.width, height: frameImages.print.height } : null);
  const layout =
    native && size.width > 0
      ? computeLayout(
          { width: Math.round(size.width * size.dpr), height: Math.round(size.height * size.dpr) },
          native,
          canvasGeometry,
          cropping,
          view,
          cropping ? 24 * size.dpr : 0,
        )
      : null;
  useEffect(() => {
    if (layout) {
      noteFitZoom(layout.fitZoom);
      noteCanvasPx(layout.viewport.width, layout.viewport.height);
    }
  });

  // The frame's textures, uploaded once per image. Both the draw and the
  // output (navigator, histogram) need them; the output must not depend on the
  // draw having run first, which it has not while the canvas is unmeasured --
  // a histogram computed from no image then never came back.
  const ensureUploaded = (r: GLRenderer) => {
    if (uploaded.current.print !== frameImages.print) {
      r.setImage(frameImages.print);
      uploaded.current.print = frameImages.print;
    }
    if (uploaded.current.original !== frameImages.original) {
      r.setOriginal(frameImages.original);
      uploaded.current.original = frameImages.original;
    }
  };

  // Draw.
  useEffect(() => {
    const r = gl.current;
    const c = canvas.current;
    if (!r || !c || size.width === 0) return;
    const vw = Math.round(size.width * size.dpr);
    const vh = Math.round(size.height * size.dpr);
    if (c.width !== vw || c.height !== vh) {
      c.width = vw;
      c.height = vh;
    }
    ensureUploaded(r);
    if (!layout) {
      const g = r.gl;
      g.viewport(0, 0, vw, vh);
      g.clearColor(SURROUND, SURROUND, SURROUND, 1);
      g.clear(g.COLOR_BUFFER_BIT);
      return;
    }
    const state: DrawState = {
      viewport: layout.viewport,
      offset: layout.offset,
      outSize: layout.outSize,
      display: layout.display,
      editingCrop: cropping ? geometry : null,
      sourceSize: layout.native,
      adjustments,
      compare: originalFallback || framing || showingOriginal ? 2 : comparing ? 1 : 0,
      split: comparePosition,
      surround: SURROUND,
    };
    r.draw(state);
    notePreviewDrawn();
  }, [imageVersion, displaySpace, layout?.zoom, layout?.offset.x, layout?.offset.y, size, geometry, adjustments, cropping, framing, comparing, comparePosition, showingOriginal, originalFallback, layout]);

  // The output, small: navigator and histogram (the canvas's frame, trap 33).
  useEffect(() => {
    const r = gl.current;
    if (!r || !native || (!frameImages.print && !originalFallback)) {
      publishOutput(null);
      setHistogram(null);
      return;
    }
    const t = setTimeout(() => {
      const outputGeometry = framing ? geometry : canvasGeometry;
      const out = outputSize(outputGeometry, native);
      // Small for the navigator and the histogram; larger while the export
      // page shows it as the proof.
      const k = (sessionStore.getState().exportOpen ? 1400 : 256) / Math.max(out.width, out.height);
      const w = Math.max(1, Math.round(out.width * k));
      const h = Math.max(1, Math.round(out.height * k));
      const state: DrawState = {
        viewport: { width: w, height: h },
        offset: { x: 0, y: 0 },
        outSize: { width: w, height: h },
        display: outputGeometry,
        editingCrop: null,
        sourceSize: native,
        adjustments,
        compare: originalFallback || framing ? 2 : 0,
        split: 0.5,
        surround: SURROUND,
      };
      ensureUploaded(r);
      const px = r.renderOutput(state, w, h);
      publishOutput(px ? { width: w, height: h, data: px, colorSpace: r.displaySpace } : null);
      if (px) void histogramOf(px).then(setHistogram);
      else setHistogram(null);
      // `renderOutput` leaves the default framebuffer bound but the canvas
      // must be redrawn with its own viewport.
      if (layout)
        r.draw({
          viewport: layout.viewport,
          offset: layout.offset,
          outSize: layout.outSize,
          display: layout.display,
          editingCrop: cropping ? geometry : null,
          sourceSize: layout.native,
          adjustments,
          compare: originalFallback || framing || showingOriginal ? 2 : comparing ? 1 : 0,
          split: comparePosition,
          surround: SURROUND,
        });
    }, 60);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [imageVersion, displaySpace, geometry, adjustments, native?.width, native?.height, exportOpen, framing, filmCanvas]);

  // ---- pointer
  const drag = useRef<
    | null
    | { kind: 'pan'; x: number; y: number; cx: number; cy: number }
    | { kind: 'crop'; handle: CropHandle; start: Point; g: Geometry }
    | { kind: 'straighten'; start: Point; g: Geometry }
    | { kind: 'pair'; start: Point; side: PairSide; placement: PairPlacement; source: { width: number; height: number }; rect: PairRect }
    | { kind: 'split' }
  >(null);
  useEffect(() => { drag.current = null; setStraightenLine(null); setPairMenu(null); }, [tool, selection]);

  const toSource = useCallback(
    (clientX: number, clientY: number): Point | null => {
      if (!layout || !wrap.current) return null;
      const rect = wrap.current.getBoundingClientRect();
      const px = (clientX - rect.left) * size.dpr;
      const py = (clientY - rect.top) * size.dpr;
      const ouv = { x: (px - layout.offset.x) / layout.outSize.width, y: (py - layout.offset.y) / layout.outSize.height };
      return sourcePoint(layout.display, ouv, layout.native);
    },
    [layout, size.dpr],
  );

  useEffect(() => wrap.current ? onFrameDrop(wrap.current, ({ path, clientX, clientY }) => {
    if (!pair || !pairGates || !path || batch) return false;
    const point = toSource(clientX, clientY);
    const side = point && PAIR_SIDES.find((s) => { const r = pairGates[s]; return point.x >= r.x && point.y >= r.y && point.x <= r.x + r.width && point.y <= r.y + r.height; });
    if (!side) return false;
    void setPairHole(side, path);
    return true;
  }) : undefined, [pair, pairGates, batch, toSource]);

  const onPointerDown = (e: React.PointerEvent) => {
    if (!layout || batch) return;
    setPairMenu(null);
    if (tool === 'neutral' && e.button === 0) {
      const p = toSource(e.clientX, e.clientY);
      if (p && p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1) void pickNeutralAt(p.x, p.y);
      return;
    }
    (e.target as Element).setPointerCapture?.(e.pointerId);
    if (pair && pairGates && e.button === 0 && tool === 'select') {
      const point = toSource(e.clientX, e.clientY);
      const hit = point && PAIR_SIDES.find((side) => { const r = pairGates[side]; return point.x >= r.x && point.y >= r.y && point.x <= r.x + r.width && point.y <= r.y + r.height; });
      if (!hit) setPairLayer('film');
      else {
        const hole = pair[hit], info = pairInfo?.[hit];
        if (pairPlacing && pairLayer === hit && hole && info?.available) {
          beginGesture(); drag.current = { kind: 'pair', start: point!, side: hit, placement: hole.placement, source: outputSize(hole.geometry, info), rect: pairGates[hit] }; return;
        }
        setPairLayer(hit);
        if (!hole) { void choosePairHole(hit); return; }
      }
    }
    if (cropping && e.button === 0) {
      const s = toSource(e.clientX, e.clientY);
      if (!s) return;
      if (e.ctrlKey || e.metaKey) {
        e.preventDefault();
        drag.current = { kind: 'straighten', start: s, g: geometry };
        setStraightenLine({ from: s, to: s });
        return;
      }
      const tol = (12 * size.dpr) / layout.zoom;
      const h = handleAt(geometry, s, layout.native, tol);
      if (h) {
        beginGesture();
        drag.current = { kind: 'crop', handle: h, start: s, g: geometry };
      }
      return;
    }
    const zoomedIn = layout.outSize.width > layout.viewport.width + 1 || layout.outSize.height > layout.viewport.height + 1;
    if (e.button === 1 || tool === 'hand' || (tool === 'select' && zoomedIn)) {
      const s = sessionStore.getState().view;
      const cx = s.fit ? 0.5 : s.cx;
      const cy = s.fit ? 0.5 : s.cy;
      if (s.fit) setView({ fit: false, zoom: layout.zoom, cx, cy });
      drag.current = { kind: 'pan', x: e.clientX, y: e.clientY, cx, cy };
    }
  };

  const onPointerMove = (e: React.PointerEvent) => {
    const d = drag.current;
    if (!d || !layout) return;
    if (d.kind === 'pair') {
      const point = toSource(e.clientX, e.clientY);
      if (point && pair) setPairPlacement(d.side, () => draggedPlacement(d.placement,
        { x: (point.x - d.start.x) / d.rect.width, y: (point.y - d.start.y) / d.rect.height }, d.source, pairAspect(pair)), true, true);
    } else if (d.kind === 'pan') {
      const dx = ((e.clientX - d.x) * size.dpr) / layout.outSize.width;
      const dy = ((e.clientY - d.y) * size.dpr) / layout.outSize.height;
      setView({ cx: clamp(d.cx - dx, 0, 1), cy: clamp(d.cy - dy, 0, 1) });
    } else if (d.kind === 'straighten') {
      const to = toSource(e.clientX, e.clientY);
      if (to) setStraightenLine({ from: d.start, to });
    } else if (d.kind === 'crop') {
      const s = toSource(e.clientX, e.clientY);
      if (!s) return;
      if (d.handle === 'body') {
        setGeometry(() => moved(d.g, { x: s.x - d.start.x, y: s.y - d.start.y }, layout.native), { coalesce: true });
      } else {
        setGeometry(() => resized(d.g, d.handle, s, layout.native), { coalesce: true });
      }
    } else if (d.kind === 'split' && wrap.current) {
      const rect = wrap.current.getBoundingClientRect();
      const px = (e.clientX - rect.left) * size.dpr;
      setComparePosition((px - layout.offset.x) / layout.outSize.width);
    }
  };

  const onPointerUp = (e: React.PointerEvent) => {
    const d = drag.current;
    if (d?.kind === 'pair') commitPairPlacement();
    if (d?.kind === 'straighten' && layout) {
      const to = toSource(e.clientX, e.clientY);
      // This crop view displays the unrotated source with a rotated crop
      // overlay. Source-space endpoints solve an absolute angle; adding the
      // old angle (as in Mac's rotating edit-space view) would double it.
      const angle = to ? straightenAngle(d.start, to, layout.native) : null;
      if (angle !== null) {
        beginGesture();
        setGeometry(() => straightened(d.g, angle, layout.native), { coalesce: true });
      }
    }
    drag.current = null;
    setStraightenLine(null);
  };

  const onWheel = (e: React.WheelEvent) => {
    if (!layout || cropping || !wrap.current) return;
    if (pair && pairPlacing && pairLayer !== 'film' && pairGates) {
      const hole = pair[pairLayer], info = pairInfo?.[pairLayer], point = toSource(e.clientX, e.clientY), r = pairGates[pairLayer];
      if (hole && info?.available) setPairPlacement(pairLayer, (p) => zoomedPlacement(p, Math.exp(-e.deltaY * (e.ctrlKey ? .01 : .0015)),
        point && point.x >= r.x && point.x <= r.x + r.width && point.y >= r.y && point.y <= r.y + r.height
          ? { x: (point.x - r.x) / r.width, y: (point.y - r.y) / r.height } : { x: .5, y: .5 }, outputSize(hole.geometry, info), pairAspect(pair)));
      return;
    }
    const rect = wrap.current.getBoundingClientRect();
    const px = (e.clientX - rect.left) * size.dpr;
    const py = (e.clientY - rect.top) * size.dpr;
    const ou = { x: (px - layout.offset.x) / layout.outSize.width, y: (py - layout.offset.y) / layout.outSize.height };
    const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015));
    const zoom = clampZoom(layout.zoom * factor, layout.fitZoom);
    const outW = layout.out.width * zoom;
    const outH = layout.out.height * zoom;
    // Keep the output point under the pointer where it is.
    const cx = clamp(ou.x - (px - layout.viewport.width / 2) / outW, 0, 1);
    const cy = clamp(ou.y - (py - layout.viewport.height / 2) / outH, 0, 1);
    setView({ fit: false, zoom, cx, cy });
  };

  // Space held: the original (one draw).
  useEffect(() => {
    const down = (e: KeyboardEvent) => {
      if (e.code === 'Space' && !e.repeat && !isTyping(e.target)) {
        e.preventDefault();
        setOriginal(true);
      }
    };
    const up = (e: KeyboardEvent) => {
      if (e.code === 'Space') setOriginal(false);
    };
    window.addEventListener('keydown', down);
    window.addEventListener('keyup', up);
    return () => {
      window.removeEventListener('keydown', down);
      window.removeEventListener('keyup', up);
    };
  }, []);

  const cursor = cropping || tool === 'neutral' ? 'crosshair' : tool === 'hand' || pairPlacing ? 'grab' : 'default';
  const css = (v: number) => v / size.dpr;
  const textureLimited = maxTextureSize !== null && layout && !view.fit && !cropping && view.zoom >= 1
    && Math.max(layout.out.width, layout.out.height) > maxTextureSize;

  return (
    <div
      ref={wrap}
      className="canvas-wrap"
      style={{ cursor }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={() => { drag.current = null; setStraightenLine(null); }}
      onWheel={onWheel}
      onContextMenu={(e) => {
        if (!pair || !pairGates || batch) return;
        const point = toSource(e.clientX, e.clientY), r = wrap.current?.getBoundingClientRect();
        const side = point && PAIR_SIDES.find((s) => { const g = pairGates[s]; return point.x >= g.x && point.y >= g.y && point.x <= g.x + g.width && point.y <= g.y + g.height; });
        if (!side || !r) return;
        e.preventDefault(); setPairLayer(side); setPairMenu({ side, x: e.clientX - r.left, y: e.clientY - r.top });
      }}
      data-testid="canvas"
    >
      <canvas ref={canvas} className="canvas-gl" />
      {pair && pairGates && layout && <svg className="crop-overlay" width="100%" height="100%" data-testid="pair-overlay">
        {PAIR_SIDES.map((side) => {
          const r = pairGates[side], x = css(layout.offset.x + r.x * layout.outSize.width), y = css(layout.offset.y + r.y * layout.outSize.height);
          const width = css(r.width * layout.outSize.width), height = css(r.height * layout.outSize.height);
          return <g key={side}><rect x={x} y={y} width={width} height={height} fill="none" stroke={side === pairLayer ? 'var(--accent)' : 'transparent'} strokeWidth={pairPlacing ? 2 : 1} />
            {!pair[side] && <text x={x + width / 2} y={y + height / 2} fill="var(--text)" fontSize={36} textAnchor="middle">+</text>}</g>;
        })}
      </svg>}
      {pairMenu && pair && <div role="menu" className="menu pair-context" style={{ left: pairMenu.x, top: pairMenu.y }} onPointerDown={(e) => e.stopPropagation()}>
        <button role="menuitem" onClick={() => { void choosePairHole(pairMenu.side); setPairMenu(null); }}>{tz('Replace frame…', '替换照片…')}</button>
        {pair[pairMenu.side] && <>
          <button role="menuitem" onClick={() => { togglePairPlacing(); setPairMenu(null); }}>{tz('Crop this frame', '裁剪这一格')}</button>
          <button role="menuitem" onClick={() => { setPairPlacement(pairMenu.side, () => ({ ...PLACEMENT_DEFAULT }), false); setPairMenu(null); }}>{tz('Reset crop', '重置裁剪')}</button>
          <button role="menuitem" onClick={() => { click(pair[pairMenu.side]!.path); setPairMenu(null); }}>{tz('Open frame alone', '单独打开照片')}</button>
          <button role="menuitem" onClick={() => { void setPairHole(pairMenu.side, null); setPairMenu(null); }}>{tz('Remove frame', '移除照片')}</button>
        </>}
      </div>}
      {glError && <div className="canvas-message">{tz('This display cannot draw the picture (WebGL2): ', '此显示无法绘制画面（WebGL2）：') + glError}</div>}
      {!selection && !glError && <div className="canvas-message canvas-empty" data-testid="canvas-empty">
        <div className="canvas-empty-actions" onPointerDown={(e) => e.stopPropagation()}
          onKeyDown={(e) => { if (e.code === 'Space') e.stopPropagation(); }}>
          <button className="btn primary" disabled={batch} onClick={() => void openDialog()} title="Ctrl+O">
            {tz('Open folder…', '打开文件夹…')}
          </button>
          <button className="btn" disabled={batch} onClick={() => void openFilesDialog()} title="Ctrl+Shift+O">
            {tz('Open photographs…', '打开图片…')}
          </button>
        </div>
        <span>{tz('You can also drag photographs or a folder here.', '也可以将图片或文件夹拖到这里。')}</span>
      </div>}
      {layout && cropping && <CropOverlay layout={layout} geometry={geometry} dpr={size.dpr} line={straightenLine} />}
      {layout && comparing && !cropping && (
        <div
          className="compare-line"
          style={{ left: css(layout.offset.x + layout.outSize.width * comparePosition), top: Math.max(0, css(layout.offset.y)), height: Math.min(size.height, css(layout.outSize.height)) }}
          onPointerDown={(e) => {
            e.stopPropagation();
            (e.target as Element).setPointerCapture?.(e.pointerId);
            drag.current = { kind: 'split' };
          }}
        >
          <span className="compare-label left">{tz('Before', '之前')}</span>
          <span className="compare-label right">{tz('After', '之后')}</span>
          <span className="compare-handle" />
        </div>
      )}
      <div className="canvas-corner">
        {histogram && <HistogramOverlay h={histogram} />}
        {textureLimited && <span className="caption" data-testid="preview-limit" style={{ maxWidth: 280 }}>
          {tz(`Display detail is limited to ${maxTextureSize} pixels. Export keeps the chosen resolution.`,
            `当前显示最多 ${maxTextureSize} 像素；导出仍使用所选分辨率。`)}
        </span>}
        {originalFallback && selection && <span className="tier-badge preview" data-testid="camera-preview-badge">
          {developing ? tz('Camera preview · loading film effect', '原图预览 · 正在加载胶片效果')
            : lastError ? tz('Camera preview · film effect failed to load', '原图预览 · 胶片效果加载失败')
              : tz('Camera preview', '原图预览')}
        </span>}
        {!originalFallback && badge && selection && (
          <span className={'tier-badge ' + badge} data-testid="tier-badge" title={badge === 'full' ? tz('Rendered from the full-resolution source; display detail follows zoom', '已完成原尺寸渲染；显示精细度随缩放调整') : tz('Preview resolution — the frame’s own is on its way', '预览分辨率——全尺寸正在渲染')}>
            {badge === 'full' ? 'full' : 'preview'}
          </span>
        )}
      </div>
    </div>
  );
}

export function isTyping(t: EventTarget | null): boolean {
  const el = t as HTMLElement | null;
  if (!el || !el.tagName) return false;
  if (el.isContentEditable) return true;
  if (el.tagName === 'TEXTAREA') return true;
  if (el.tagName === 'INPUT') {
    const type = (el as HTMLInputElement).type;
    return !['checkbox', 'radio', 'button', 'range', 'submit'].includes(type);
  }
  return false;
}

function CropOverlay({ layout, geometry, dpr, line }: { layout: Layout; geometry: Geometry; dpr: number; line: { from: Point; to: Point } | null }) {
  const toView = (s: Point) => {
    const o = outputPoint(layout.display, s, layout.native);
    return { x: (layout.offset.x + o.x * layout.outSize.width) / dpr, y: (layout.offset.y + o.y * layout.outSize.height) / dpr };
  };
  const g = geometry;
  const at = (fx: number, fy: number) => toView(rotated(g, { x: g.crop.x + g.crop.width * fx, y: g.crop.y + g.crop.height * fy }, layout.native));
  const corners = [at(0, 0), at(1, 0), at(1, 1), at(0, 1)];
  const lines: [Point, Point][] = [];
  for (const t of [1 / 3, 2 / 3]) {
    lines.push([at(t, 0), at(t, 1)], [at(0, t), at(1, t)]);
  }
  void centre;
  const guide = line ? [toView(line.from), toView(line.to)] as const : null;
  return (
    <svg className="crop-overlay" width="100%" height="100%">
      <polygon points={corners.map((p) => `${p.x},${p.y}`).join(' ')} fill="none" stroke="var(--selection-frame)" strokeWidth={1} />
      {lines.map(([a, b], i) => (
        <line key={i} x1={a.x} y1={a.y} x2={b.x} y2={b.y} stroke="var(--selection-frame)" strokeOpacity={0.35} strokeWidth={0.5} />
      ))}
      {CROP_HANDLES.map((h) => {
        const pos = handlePosition(h);
        const p = at(pos.x, pos.y);
        const horiz = pos.y !== 0.5 && !isCorner(h);
        const w = isCorner(h) ? 11 : horiz ? 22 : 4;
        const hh = isCorner(h) ? 11 : horiz ? 4 : 22;
        return <rect key={h} x={p.x - w / 2} y={p.y - hh / 2} width={w} height={hh} fill="var(--selection-frame)" />;
      })}
      {guide && <g data-testid="straighten-line" stroke="var(--accent)" strokeWidth={1.5}>
        <line x1={guide[0].x} y1={guide[0].y} x2={guide[1].x} y2={guide[1].y} />
        {guide.map((p, i) => <circle key={i} cx={p.x} cy={p.y} r={3} fill="var(--card)" />)}
      </g>}
    </svg>
  );
}
