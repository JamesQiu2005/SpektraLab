// Canvas.tsx — the picture: WebGL2 draw, fit / 100 % / zoom / pan, the crop
// tool's overlay, the before/after split, the histogram and the tier badge.
//
// Gestures (Capture One's, as the Mac app has them): wheel zooms about the
// pointer; drag pans with the Hand tool (H), with the middle button, or with
// the Select tool while zoomed in; Space held shows the original. Zoom is in
// *native* pixels per device pixel, so "100 %" is the frame's own pixels
// whatever tier is on the canvas (§7.3: zoom selects no tier).

import { useCallback, useEffect, useRef, useState } from 'react';
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
} from '@shared/geometry';
import { clamp } from '@shared/params';
import { GLRenderer, type DrawState } from './glRenderer';
import { frameImages } from '../state/frames';
import {
  beginGesture,
  noteFitZoom,
  noteCanvasPx,
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
  const uploaded = useRef({ print: null as unknown, original: null as unknown });

  const imageVersion = useSession((s) => s.imageVersion);
  const geometry = useSession((s) => s.sidecar.geometry);
  const adjustments = useSession((s) => s.sidecar.adjustments);
  const nativeSize = useSession((s) => s.nativeSize);
  const view = useSession((s) => s.view);
  const tool = useSession((s) => s.tool);
  const comparing = useSession((s) => s.comparing);
  const comparePosition = useSession((s) => s.comparePosition);
  const showingOriginal = useSession((s) => s.showingOriginal);
  const badge = useSession((s) => s.badge);
  const selection = useSession((s) => s.selection);
  const batch = useSession((s) => s.batchExporting);
  const cropping = tool === 'crop';

  useEffect(() => {
    if (!canvas.current) return;
    try {
      gl.current = new GLRenderer(canvas.current);
    } catch (e) {
      setGlError((e as Error).message);
    }
  }, []);

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

  const native = nativeSize ?? (frameImages.print ? { width: frameImages.print.width, height: frameImages.print.height } : null);
  const layout =
    native && size.width > 0
      ? computeLayout(
          { width: Math.round(size.width * size.dpr), height: Math.round(size.height * size.dpr) },
          native,
          geometry,
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
    if (uploaded.current.print !== frameImages.print) {
      r.setImage(frameImages.print);
      uploaded.current.print = frameImages.print;
    }
    if (uploaded.current.original !== frameImages.original) {
      r.setOriginal(frameImages.original);
      uploaded.current.original = frameImages.original;
    }
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
      compare: showingOriginal ? 2 : comparing ? 1 : 0,
      split: comparePosition,
      surround: SURROUND,
    };
    r.draw(state);
  }, [imageVersion, layout?.zoom, layout?.offset.x, layout?.offset.y, size, geometry, adjustments, cropping, comparing, comparePosition, showingOriginal, layout]);

  // The output, small: navigator and histogram (the canvas's frame, trap 33).
  useEffect(() => {
    const r = gl.current;
    if (!r || !native || !frameImages.print) {
      publishOutput(null);
      setHistogram(null);
      return;
    }
    const t = setTimeout(() => {
      const out = outputSize(geometry, native);
      const k = 256 / Math.max(out.width, out.height);
      const w = Math.max(1, Math.round(out.width * k));
      const h = Math.max(1, Math.round(out.height * k));
      const state: DrawState = {
        viewport: { width: w, height: h },
        offset: { x: 0, y: 0 },
        outSize: { width: w, height: h },
        display: geometry,
        editingCrop: null,
        sourceSize: native,
        adjustments,
        compare: 0,
        split: 0.5,
        surround: SURROUND,
      };
      const px = r.renderOutput(state, w, h);
      publishOutput(px ? { width: w, height: h, data: px } : null);
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
          compare: showingOriginal ? 2 : comparing ? 1 : 0,
          split: comparePosition,
          surround: SURROUND,
        });
    }, 60);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [imageVersion, geometry, adjustments, native?.width, native?.height]);

  // ---- pointer
  const drag = useRef<
    | null
    | { kind: 'pan'; x: number; y: number; cx: number; cy: number }
    | { kind: 'crop'; handle: CropHandle; start: Point; g: Geometry }
    | { kind: 'split' }
  >(null);

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

  const onPointerDown = (e: React.PointerEvent) => {
    if (!layout || batch) return;
    (e.target as Element).setPointerCapture?.(e.pointerId);
    if (cropping && e.button === 0) {
      const s = toSource(e.clientX, e.clientY);
      if (!s) return;
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
    if (d.kind === 'pan') {
      const dx = ((e.clientX - d.x) * size.dpr) / layout.outSize.width;
      const dy = ((e.clientY - d.y) * size.dpr) / layout.outSize.height;
      setView({ cx: clamp(d.cx - dx, 0, 1), cy: clamp(d.cy - dy, 0, 1) });
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

  const onPointerUp = () => {
    drag.current = null;
  };

  const onWheel = (e: React.WheelEvent) => {
    if (!layout || cropping || !wrap.current) return;
    const rect = wrap.current.getBoundingClientRect();
    const px = (e.clientX - rect.left) * size.dpr;
    const py = (e.clientY - rect.top) * size.dpr;
    const ou = { x: (px - layout.offset.x) / layout.outSize.width, y: (py - layout.offset.y) / layout.outSize.height };
    const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.01 : 0.0015));
    const zoom = clamp(layout.zoom * factor, Math.min(layout.fitZoom, 0.05), 16);
    const outW = layout.out.width * zoom;
    const outH = layout.out.height * zoom;
    // Keep the output point under the pointer where it is.
    const cx = clamp(ou.x - (px - layout.viewport.width / 2) / outW, 0, 1);
    const cy = clamp(ou.y - (py - layout.viewport.height / 2) / outH, 0, 1);
    if (zoom <= layout.fitZoom * 1.0001 && factor < 1) setView({ fit: true, cx: 0.5, cy: 0.5 });
    else setView({ fit: false, zoom, cx, cy });
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

  const cursor = cropping ? 'crosshair' : tool === 'hand' ? 'grab' : 'default';
  const css = (v: number) => v / size.dpr;

  return (
    <div
      ref={wrap}
      className="canvas-wrap"
      style={{ cursor }}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
      onWheel={onWheel}
      data-testid="canvas"
    >
      <canvas ref={canvas} className="canvas-gl" />
      {glError && <div className="canvas-message">{tz('This display cannot draw the picture (WebGL2): ', '此显示无法绘制画面（WebGL2）：') + glError}</div>}
      {!selection && !glError && <div className="canvas-message">{tz('Open a folder or drop photographs here (Ctrl+O).', '打开文件夹或把照片拖到这里（Ctrl+O）。')}</div>}
      {layout && cropping && <CropOverlay layout={layout} geometry={geometry} dpr={size.dpr} />}
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
        {badge && selection && (
          <span className={'tier-badge ' + badge} data-testid="tier-badge" title={badge === 'full' ? tz('The frame at its own resolution', '照片自身分辨率') : tz('Preview resolution — the frame’s own is on its way', '预览分辨率——全尺寸正在渲染')}>
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

function CropOverlay({ layout, geometry, dpr }: { layout: Layout; geometry: Geometry; dpr: number }) {
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
    </svg>
  );
}
