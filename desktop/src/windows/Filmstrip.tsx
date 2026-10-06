// Filmstrip.tsx — one cell per frame (`Panels/Filmstrip.swift`). Each shows
// the **whole** photograph, turned and flipped, with the outside of the crop
// under an 82 % mask (Capture One's behaviour; ARCHITECTURE §7.7): the live
// geometry for the open frame, the saved one for the rest.
//
// Click opens (and collapses the picked set); Ctrl/Cmd-click toggles one
// frame in the set and leaves the canvas where it is.

import { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { ChevronLeft, ChevronRight } from '../controls/icons';
import { click, selectRelative, useSession } from '../state/session';
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
  useSyncExternalStore(
    (cb) => thumbs.onChange(cb),
    () => thumbVersion(),
  );
  const strip = useRef<HTMLDivElement>(null);
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
            title={f.name}
            data-path={f.path}
          >
            <Thumb path={f.path} geometry={f.path === selection ? live : (saved[f.path] ?? GEOMETRY_DEFAULT)} />
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

function Thumb({ path, geometry }: { path: string; geometry: Geometry }) {
  const url = thumbs.get(path);
  const ref = useRef<HTMLCanvasElement>(null);
  const [img, setImg] = useState<HTMLImageElement | null>(null);
  useEffect(() => {
    if (!url) return;
    const i = new Image();
    i.onload = () => setImg(i);
    i.src = url;
  }, [url]);
  useEffect(() => {
    const c = ref.current;
    if (!c || !img) return;
    const plan = thumbnailGeometryPlan(geometry, { width: img.naturalWidth, height: img.naturalHeight }, CELL_H);
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
  }, [img, geometry]);
  if (!url) return <div className="placeholder" />;
  return <canvas ref={ref} />;
}
