// Filmstrip.tsx — one cell per frame (`Panels/Filmstrip.swift`). Each shows
// the **whole** photograph, turned and flipped, with the outside of the crop
// under an 82 % mask (Capture One's behaviour; ARCHITECTURE §7.7): the live
// geometry for the open frame, the saved one for the rest.
//
// Click opens (and collapses the picked set); Ctrl/Cmd-click toggles one
// frame in the set and leaves the canvas where it is.

import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { ChevronLeft, ChevronRight } from '../controls/icons';
import { click, moveFrame, saveFrameOrder, selectRelative, sessionStore, useSession } from '../state/session';
import { installFrameDrag } from './frameDrag';
import { thumbs } from '../state/thumbs';
import { type Geometry, GEOMETRY_DEFAULT } from '@shared/geometry';
import { thumbnailGeometryPlan } from '@shared/surfaces';
import { t } from '../i18n';

export function Filmstrip() {
  const frames = useSession((s) => s.frames);
  const selection = useSession((s) => s.selection);
  const picked = useSession((s) => s.picked);
  const live = useSession((s) => s.sidecar.geometry);
  const saved = useSession((s) => s.savedGeometry);
  const batch = useSession((s) => s.batchExporting);
  const strip = useRef<HTMLDivElement>(null);
  const [, visibleChanged] = useState(0);
  useEffect(() => {
    const root = strip.current;
    if (!root) return;
    const wheel = (event: WheelEvent) => {
      if (event.ctrlKey) return; // Leave touchpad pinch gestures alone.
      const delta = Math.abs(event.deltaX) > Math.abs(event.deltaY) ? event.deltaX : event.deltaY;
      if (!delta) return;
      const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? root.clientWidth : 1;
      // Browse the roll without opening a frame or letting the page scroll.
      event.preventDefault();
      event.stopPropagation();
      root.scrollLeft += delta * unit;
    };
    root.addEventListener('wheel', wheel, { passive: false });
    return () => root.removeEventListener('wheel', wheel);
  }, []);
  useEffect(() => strip.current ? installFrameDrag(strip.current, {
    enabled: () => !sessionStore.getState().batchExporting,
    reorder: moveFrame,
    save: saveFrameOrder,
  }) : undefined, []);
  useEffect(() => {
    const root = strip.current;
    if (!root) return;
    const nearby = new Set<string>();
    let active = true;
    const publish = () => {
      if (!active) return;
      thumbs.setFilmstripPaths(nearby);
      visibleChanged((value) => value + 1);
    };
    const cells = Array.from(root.querySelectorAll<HTMLElement>('.thumb[data-path]'));
    // Keep only the visible strip and a few neighbouring cells eligible. A
    // folder with thousands of frames must not fill the host's FIFO on import.
    if (typeof IntersectionObserver !== 'undefined') {
      const observer = new IntersectionObserver((entries) => {
        let changed = false;
        for (const entry of entries) {
          const path = (entry.target as HTMLElement).dataset.path!;
          if (entry.isIntersecting) {
            if (!nearby.has(path)) { nearby.add(path); changed = true; }
          } else if (nearby.delete(path)) changed = true;
        }
        if (changed) publish();
      }, { root, rootMargin: '0px 320px', threshold: 0 });
      cells.forEach((cell) => observer.observe(cell));
      return () => { active = false; observer.disconnect(); thumbs.setFilmstripPaths([]); };
    }
    // Older embedded browsers still load only nearby cells. Hidden/zero-sized
    // strips defer requests until the next scroll or resize gives them a size.
    const update = () => {
      const bounds = root.getBoundingClientRect();
      const next = cells.filter((cell) => {
        const rect = cell.getBoundingClientRect();
        return bounds.width > 0 && bounds.height > 0 && rect.right >= bounds.left - 320 && rect.left <= bounds.right + 320;
      }).map((cell) => cell.dataset.path!);
      if (next.length === nearby.size && next.every((path) => nearby.has(path))) return;
      nearby.clear(); next.forEach((path) => nearby.add(path)); publish();
    };
    update();
    root.addEventListener('scroll', update, { passive: true });
    window.addEventListener('resize', update);
    const resize = typeof ResizeObserver !== 'undefined' ? new ResizeObserver(update) : null;
    resize?.observe(root);
    return () => {
      active = false; root.removeEventListener('scroll', update); window.removeEventListener('resize', update);
      resize?.disconnect(); thumbs.setFilmstripPaths([]);
    };
  }, [frames]);
  useEffect(() => {
    const el = strip.current?.querySelector('.thumb.open');
    el?.scrollIntoView({ block: 'nearest', inline: 'nearest' });
  }, [selection]);
  return (
    <div className="filmstrip" data-testid="filmstrip">
      <button className="strip-chevron" onClick={() => selectRelative(-1)} disabled={batch} aria-label="Previous">
        <ChevronLeft />
      </button>
      <div className="filmstrip-cells" ref={strip}>
        {frames.length === 0 && <span className="caption">{t('statusEmptyFilmstrip').replace('⌘O', 'Ctrl+O')}</span>}
        {frames.map((f) => (
          <div
            key={f.path}
            className={'thumb' + (f.path === selection ? ' open' : '') + (picked.includes(f.path) ? ' picked' : '')}
            onClick={(e) => click(f.path, e.ctrlKey || e.metaKey)}
            draggable={false}
            style={{ touchAction: 'none' }}
            title={f.name}
            data-path={f.path}
          >
            <Thumb path={f.path} geometry={f.path === selection ? live : (saved[f.path] ?? GEOMETRY_DEFAULT)} source="filmstrip" />
            <span className="thumb-name">{f.name}</span>
          </div>
        ))}
      </div>
      <button className="strip-chevron" onClick={() => selectRelative(1)} disabled={batch} aria-label="Next">
        <ChevronRight />
      </button>
    </div>
  );
}

let version = 0;
thumbs.onChange(() => version++);
const thumbVersion = () => version;

const CELL_H = 104;

export function Thumb({ path, geometry, height = CELL_H, source = 'general' }: {
  path: string; geometry: Geometry; height?: number; source?: 'general' | 'filmstrip';
}) {
  // Export-page cells are mounted without Filmstrip, so each consumer owns its
  // subscription instead of relying on the strip to happen to re-render it.
  useSyncExternalStore((cb) => thumbs.onChange(cb), thumbVersion);
  const url = thumbs.get(path, source);
  const ref = useRef<HTMLCanvasElement>(null);
  const [img, setImg] = useState<HTMLImageElement | null>(null);
  useEffect(() => {
    if (!url) return;
    const i = new Image();
    i.onload = () => setImg(i);
    i.src = url;
    return () => { i.onload = null; };
  }, [url]);
  useEffect(() => {
    const c = ref.current;
    if (!c || !img) return;
    const plan = thumbnailGeometryPlan(thumbs.isFilmCanvas(path) ? GEOMETRY_DEFAULT : geometry, { width: img.naturalWidth, height: img.naturalHeight }, height);
    c.width = plan.width;
    c.height = plan.height;
    const ctx = c.getContext('2d')!;
    ctx.setTransform(...plan.imageTransform);
    ctx.drawImage(img, 0, 0);
    if (plan.cropPolygon) {
      // Darken outside the crop: whole cell minus the crop polygon.
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.fillStyle = 'rgba(45,45,44,0.82)';
      ctx.beginPath();
      ctx.rect(0, 0, plan.width, plan.height);
      const pts = plan.cropPolygon;
      ctx.moveTo(pts[0]!.x, pts[0]!.y);
      for (const p of pts.slice(1)) ctx.lineTo(p.x, p.y);
      ctx.closePath();
      ctx.fill('evenodd');
    }
  }, [img, geometry, height, path]);
  if (!url) return <div className="placeholder" />;
  return <canvas ref={ref} />;
}
