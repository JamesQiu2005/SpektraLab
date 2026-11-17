// rails.tsx — Develop (the left rail) and Edit (the right rail), both on
// screen (README §3, PC-E1). The controls are the Mac's, in the Mac HIG's
// sections; their bodies are v1's components wherever v1 already had them
// (Navigator, Latitude, Enlarger, Decode, Crop, Film Edge, Date Back, the
// pair), placed in the v2 order and drawn in the v2 rows.
//
// The gates (README §3.8, R7): a section whose feature the engine refuses is
// absent — no head, no dimmed tile. An Adjust tile the v1 Layer 2 has no
// maths for (HSL, Channels, Vibrance) is not shipped either ("a tile that
// does nothing is not shipped"); `ADJUST_TILES` says which and why.

import { useRef, type ReactNode } from 'react';
import { tz } from '../i18n';
import { Disclosure, Reset } from '../controls/icons';
import { ScrubSlider, ToggleRow, signed } from '../controls/controls';
import {
  setAdjustments, setParams, selectFilmStock, selectPrintStock, setFilmFrame, shownAdjustments, useSession, zoomTo, zoomToFit,
  cameraExposureTotal, setCameraExposureTotal, resetCameraExposure, beginGesture, resetAdjustments, resetEnlarger, resetCrop, resetFilmStock,
} from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { setWorkspace, toggleAdjustTile, toggleDarkroomTile, useUi, type AdjustTile, type DarkroomTile } from '../app/ui';
import { EFFECT_RANGES, EFFECTS_DEFAULT, FILM_FRAMES_STILL, clamp } from '@shared/params';
import { ADJUSTMENTS_DEFAULT, CURVES_IDENTITY } from '@shared/adjustments';
import { NavigatorSection, CropSection, EnlargerSection, FilmEdgeSection, DateBackSection } from '../panels/LeftRail';
import { CameraSection, CurveSection, ColorBalanceSection } from '../panels/RightRail';
import { PairSection } from '../panels/PairSection';
import { shortName } from './words';

// ------------------------------------------------------------------ parts

/** A rail's section head (README §3.7: ▾, title, summary, ↺); Ctrl+click opens or closes every section in the rail. */
export function V2Section({ id, title, summary, onReset, resetEnabled = true, children, testId }: {
  id: string; title: string; summary?: string; onReset?: () => void; resetEnabled?: boolean; children: ReactNode; testId?: string;
}) {
  const key = `v2.${id}`;
  const closed = useSettings((s) => !!s.collapsedSections[key]);
  const toggle = (e: React.MouseEvent) => {
    const st = settingsStore.getState();
    if (e.ctrlKey) {
      const rail = (e.currentTarget as HTMLElement).closest('.v2-rail');
      const ids = [...(rail?.querySelectorAll<HTMLElement>('[data-v2-section]') ?? [])].map((x) => `v2.${x.dataset.v2Section}`);
      const c = { ...st.collapsedSections };
      for (const k of ids) c[k] = !closed;
      st.set('collapsedSections', c);
    } else st.toggleSection(key);
  };
  return (
    <section className="v2-section" data-v2-section={id} data-testid={testId ?? `section-${id}`}>
      <div className="v2-section-head">
        <button className={'v2-disclosure' + (closed ? ' closed' : '')} aria-expanded={!closed} aria-label={title} onClick={toggle}><Disclosure /></button>
        <span className="v2-section-title" onClick={toggle}>{title}</span>
        {closed && summary && <span className="v2-section-summary">{summary}</span>}
        {!closed && summary && <span className="v2-section-summary">{summary}</span>}
        {onReset && <button className="v2-reset" title={tz('Reset', '重置')} aria-label={`${tz('Reset', '重置')} ${title}`} disabled={!resetEnabled} onClick={onReset}><Reset /></button>}
      </div>
      {!closed && <div className="v2-section-body">{children}</div>}
    </section>
  );
}

/** A v1 section's body inside a v2 place: its own head is the v2 one. */
const Host = ({ children, testId }: { children: ReactNode; testId?: string }) => <div className="v2-host" data-testid={testId}>{children}</div>;

export function Rail({ side, title, mode, children }: { side: 'left' | 'right'; title: string; mode: string; children: ReactNode }) {
  return (
    <aside className={`v2-rail ${side} ${mode}`} data-testid={`rail-${side}`} data-mode={mode} aria-label={title}>
      <div className="v2-rail-head" data-testid={`rail-${side}-head`}><span className="v2-rail-title">{title}</span></div>
      {children}
    </aside>
  );
}

export function WorkspaceSwitch() {
  const ws = useUi((s) => s.workspace);
  return (
    <div className="v2-switch" role="tablist" aria-label={tz('Workspace', '工作区')} data-testid="workspace-switch">
      {(['library', 'edit'] as const).map((w) => (
        <button key={w} role="tab" aria-selected={ws === w} className={ws === w ? 'on' : ''} data-testid={`workspace-${w}`} onClick={() => setWorkspace(w)}>
          {w === 'library' ? tz('Library', '图库') : tz('Edit', '编辑')}
        </button>
      ))}
    </div>
  );
}

// -------------------------------------------------------------- Develop

function Navigator({ fold }: { fold: 'well' | 'line' | 'hidden' }) {
  const view = useSession((s) => s.view);
  const fitZoom = useSession((s) => s.fitZoom);
  if (fold === 'hidden') return null;
  const chips = (
    <div className="v2-nav-chips" data-testid="navigator-zoom">
      <button className={view.fit ? 'on' : ''} onClick={zoomToFit}>{tz('Fit', '适合')}</button>
      <button className={!view.fit && Math.abs(view.zoom - 1) < 1e-3 ? 'on' : ''} onClick={() => zoomTo(1)}>100 %</button>
      <button className={!view.fit && Math.abs(view.zoom - 2) < 1e-3 ? 'on' : ''} onClick={() => zoomTo(2)}>200 %</button>
    </div>
  );
  void fitZoom;
  if (fold === 'line') return <div className="v2-navigator line" data-testid="navigator-line"><span className="v2-nav-word">{tz('Navigator', '导航器')}</span>{chips}</div>;
  return <div className="v2-navigator" data-testid="navigator-well"><Host><NavigatorSection /></Host>{chips}</div>;
}

type FilmFilter = 'all' | 'negative' | 'positive' | 'bw' | 'cine';

function FilmPaper() {
  const catalog = useSession((s) => s.catalog);
  const p = useSession((s) => s.sidecar.params);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  // The film filter's menu (Negative, Positive, Black & White, Cine) is not built yet: All only.
  const filter: FilmFilter = 'all' as FilmFilter;
  const positive = catalog.isPositive(p.filmStock);
  const films = catalog.films.filter((f) => filter === 'all' || (filter === 'negative' && f.type !== 'positive' && !f.monochrome));
  const papers = catalog.papers.filter((x) => x.use !== 'cine');
  const strip = useRef<HTMLDivElement>(null);
  return (
    <V2Section id="filmPaper" title={tz('Film & Paper', '胶片与相纸')} onReset={resetFilmStock} resetEnabled={editable}>
      <div className="v2-filter" data-testid="film-filter">{tz('Film', '胶片')}<span className="dim"> · {tz('All', '全部')}</span></div>
      <div className="v2-cards" role="listbox" aria-label={tz('Film', '胶片')} data-testid="film-cards">
        {films.map((f) => {
          const on = f.id === p.filmStock;
          return (
            <button key={f.id} role="option" aria-selected={on} className={'v2-card' + (on ? ' on' : '')} disabled={!editable} title={f.name}
              onClick={() => selectFilmStock(f.id)} data-stock={f.id}>
              <span className="v2-card-face" style={catalog.coverURL(f.id) ? { backgroundImage: `url("${catalog.coverURL(f.id)}")` } : undefined} />
              {f.use === 'cine' && <span className="v2-cine">CINE</span>}
              <span className="v2-card-name">{shortName(catalog, f.id)}</span>
            </button>
          );
        })}
      </div>
      <div className="v2-filter" data-testid="paper-filter">{tz('Paper', '相纸')}<span className="dim"> · {tz('All', '全部')}</span></div>
      <div className="v2-strip" ref={strip} role="listbox" aria-label={tz('Paper', '相纸')} data-testid="paper-cards"
        onWheel={(e) => { if (e.shiftKey && strip.current) strip.current.scrollLeft += e.deltaY; }}>
        <button role="option" aria-selected={positive || p.scanFilm} className={'v2-card paper' + (positive || p.scanFilm ? ' on' : '')} disabled={!editable || positive}
          onClick={() => setParams((q) => ({ ...q, scanFilm: true, digitalIntermediate: false }))} data-stock="none">
          <span className="v2-card-face none" /><span className="v2-card-name">{tz('No paper', '不印放')}</span>
        </button>
        {papers.map((x) => {
          const on = !positive && !p.scanFilm && x.id === p.printStock;
          const waits = positive || !catalog.canPrint(p.filmStock, x.id);
          return (
            <button key={x.id} role="option" aria-selected={on} className={'v2-card paper' + (on ? ' on' : '') + (waits ? ' waits' : '')} disabled={!editable || waits}
              title={waits ? (positive ? tz('A slide is scanned, never printed.', '反转片直接扫描，不印放。') : tz('Silver on silver, colour on colour.', '黑白配黑白，彩色配彩色。')) : x.name}
              aria-label={waits ? `${x.name}, ${tz('not for this film', '不适用于此胶片')}` : x.name}
              onClick={() => selectPrintStock(x.id)} data-stock={x.id}>
              <span className="v2-card-face paper" />
              <span className="v2-card-name">{shortName(catalog, x.id)}</span>
            </button>
          );
        })}
      </div>
    </V2Section>
  );
}

/** The Film Exposure dial: a tick ruler −8…+8 EV (the iPad's TickRuler), its value editable. */
export function FilmExposure() {
  const state = useSession((s) => s);
  const total = cameraExposureTotal(state);
  const value = total ?? state.sidecar.params.exposureCompensationEV;
  const ready = total !== null && !!state.selection && !state.batchExporting;
  const drag = useRef<{ x: number; v: number } | null>(null);
  const PX_PER_EV = 30;
  const set = (v: number, snap: boolean) => setCameraExposureTotal(clamp(snap ? Math.round(v * 3) / 3 : Math.round(v * 10) / 10, -8, 8));
  return (
    <div className="v2-ruler-row" data-testid="film-exposure-ruler" aria-disabled={!ready || undefined}>
      <div className="v2-row-line">
        <span className="v2-label">{tz('Film Exposure', '胶片曝光')}</span>
        <input className="v2-value" aria-label={tz('Film Exposure, value', '胶片曝光数值')} disabled={!ready} key={value}
          defaultValue={`${signed(1)(value)} EV`}
          onKeyDown={(e) => { if (e.key === 'Enter') (e.target as HTMLInputElement).blur(); if (e.key === 'Escape') { (e.target as HTMLInputElement).value = `${signed(1)(value)} EV`; (e.target as HTMLInputElement).blur(); } }}
          onBlur={(e) => { const n = Number.parseFloat(e.target.value.replace('−', '-')); if (Number.isFinite(n) && n !== value) { beginGesture(); set(n, false); } }} />
      </div>
      <div className="v2-ruler" role="slider" aria-label={tz('Film Exposure', '胶片曝光')} aria-valuemin={-8} aria-valuemax={8} aria-valuenow={value}
        aria-valuetext={`${signed(1)(value)} EV`} tabIndex={0}
        onKeyDown={(e) => {
          if (!ready) return;
          const step = e.ctrlKey ? 0.1 : e.shiftKey ? 1 : 1 / 3;
          if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') { e.preventDefault(); e.stopPropagation(); beginGesture(); set(value + (e.key === 'ArrowRight' ? step : -step), false); }
        }}
        onPointerDown={(e) => { if (!ready || e.button !== 0) return; (e.target as HTMLElement).setPointerCapture(e.pointerId); beginGesture(); drag.current = { x: e.clientX, v: value }; }}
        onPointerMove={(e) => { const d = drag.current; if (!d) return; const k = e.ctrlKey ? 0.25 : 1; set(d.v - ((e.clientX - d.x) / PX_PER_EV) * k, e.shiftKey); }}
        onPointerUp={() => { drag.current = null; }}
        onDoubleClick={() => { if (ready) resetCameraExposure(); }}>
        <div className="v2-ruler-scale" style={{ transform: `translateX(${-value * PX_PER_EV}px)` }}>
          {Array.from({ length: 17 }, (_, i) => i - 8).map((ev) => (
            <span key={ev} className={'v2-tick' + (ev === 0 ? ' rest' : '')} style={{ left: `calc(50% + ${ev * PX_PER_EV}px)` }}>
              <i /><b>{ev > 0 ? `+${ev}` : ev < 0 ? `−${-ev}` : '0'}</b>
            </span>
          ))}
        </div>
        <div className="v2-ruler-mark" />
      </div>
    </div>
  );
}

/** A strength (README §3.6): 0 is off; above 0 the effect is on at that strength. */
function Strength({ label, value, on, onChange, range, testId }: { label: string; value: number; on: boolean; onChange: (v: number) => void; range: readonly [number, number]; testId?: string }) {
  return <ScrubSlider label={label} value={on ? value : 0} range={[0, range[1]]} zero={1} snap={0.25} format={(v) => `${v.toFixed(2)}×`} onChange={onChange} testId={testId} />;
}

function Format() {
  const p = useSession((s) => s.sidecar.params);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const noLayer = useSession((s) => s.catalog.hasNoAntihalationLayer(s.sidecar.params.filmStock));
  const e = p.effects;
  const setE = (patch: Partial<typeof e>) => setParams((q) => ({ ...q, effects: { ...q.effects, ...patch } }));
  const sizes = FILM_FRAMES_STILL.filter((f) => f.id !== 'Custom');
  return (
    <V2Section id="format" title={tz('Format', '画幅')} summary={`${p.filmFrame}  ·  ${tz('Grain', '颗粒')} ${(p.grainActive ? e.grain : 0).toFixed(2)}×`}
      onReset={() => { setFilmFrame('135'); setParams((q) => ({ ...q, grainActive: true, halationActive: true, effects: { ...q.effects, grain: EFFECTS_DEFAULT.grain, halation: EFFECTS_DEFAULT.halation, antihalationRemoved: false } })); }} resetEnabled={editable}>
      <div className="v2-size-cards" role="radiogroup" aria-label={tz('Size', '尺寸')} data-testid="format-sizes">
        {sizes.map((f) => (
          <button key={f.id} role="radio" aria-checked={p.filmFrame === f.id} className={'v2-size' + (p.filmFrame === f.id ? ' on' : '')} disabled={!editable} onClick={() => setFilmFrame(f.id)}>
            <b>{f.id}</b><small>{f.short} × {f.long}</small>
          </button>
        ))}
      </div>
      {noLayer
        ? <ToggleRow label={tz('Remove anti-halation layer', '去除防光晕层')} sublabel={tz('This film has none', '此胶片没有防光晕层')} on disabled onChange={() => {}} />
        : <ToggleRow label={tz('Remove anti-halation layer', '去除防光晕层')} sublabel={tz('Experimental simulation for all stocks', '适用于所有胶片的实验性模拟')} on={e.antihalationRemoved} disabled={!editable} onChange={(v) => setE({ antihalationRemoved: v })} testId="antihalation-toggle" />}
      <Strength label={tz('Grain', '颗粒')} value={e.grain} on={p.grainActive} range={EFFECT_RANGES.grain} testId="grain-strength"
        onChange={(v) => setParams((q) => ({ ...q, grainActive: v > 0, effects: { ...q.effects, grain: v > 0 ? v : q.effects.grain } }))} />
      <Strength label={tz('Halation', '光晕')} value={e.halation} on={p.halationActive} range={EFFECT_RANGES.halation} testId="halation-strength"
        onChange={(v) => setParams((q) => ({ ...q, halationActive: v > 0, effects: { ...q.effects, halation: v > 0 ? v : q.effects.halation } }))} />
    </V2Section>
  );
}

export function DevelopRail({ mode, navigator }: { mode: string; navigator: 'well' | 'line' | 'hidden' }) {
  const gate = useSession((s) => s.gate);
  return (
    <Rail side="left" title={tz('Develop', '冲洗')} mode={mode}>
      <div className="v2-rail-fixed">
        <WorkspaceSwitch />
        <Navigator fold={navigator} />
      </div>
      <div className="v2-rail-scroll" data-testid="develop-sections">
        <FilmPaper />
        <div className="v2-section-pad"><FilmExposure /></div>
        <Format />
        {gate.overscan && <V2Section id="filmEdge" title={tz('Film Edge', '片边')}><Host><FilmEdgeSection /></Host></V2Section>}
        {gate.dateImprint && <V2Section id="dateBack" title={tz('Date Back', '日期背')}><Host><DateBackSection /></Host></V2Section>}
        {gate.overscan && <Host testId="pair-host"><PairSection /></Host>}
      </div>
    </Rail>
  );
}

// ----------------------------------------------------------------- Edit

/** Adjust's tiles in the strip's order, and what the v1 Layer 2 can do (R7). */
export const ADJUST_TILES: { id: AdjustTile; label: () => string; built: boolean; why?: string }[] = [
  { id: 'brightness', label: () => tz('Brightness', '亮度'), built: true },
  { id: 'contrast', label: () => tz('Contrast', '对比度'), built: true },
  { id: 'tone', label: () => tz('Tone', '色调'), built: true },
  { id: 'hsl', label: () => 'HSL', built: false, why: 'the v1 Layer 2 has no HSL set' },
  { id: 'channels', label: () => tz('Channels', '通道'), built: false, why: 'the v1 Layer 2 has no channel mixer' },
  { id: 'wheels', label: () => tz('Colour Wheels', '色轮'), built: true },
  { id: 'vibrance', label: () => tz('Vibrance', '鲜艳度'), built: false, why: 'the v1 Layer 2 has no vibrance' },
  { id: 'saturation', label: () => tz('Saturation', '饱和度'), built: true },
  { id: 'temperature', label: () => tz('Temperature', '色温'), built: true },
  { id: 'curve', label: () => tz('Curve', '曲线'), built: true },
  { id: 'vignette', label: () => tz('Vignette', '暗角'), built: true },
];

function tileEdited(id: AdjustTile, a: ReturnType<typeof shownAdjustments>): boolean {
  const d = ADJUSTMENTS_DEFAULT;
  switch (id) {
    case 'brightness': return a.brightness !== d.brightness || a.exposure !== d.exposure;
    case 'contrast': return a.contrast !== d.contrast;
    case 'tone': return a.highlights !== 0 || a.shadows !== 0 || a.whitePoint !== d.whitePoint || a.blackPoint !== d.blackPoint;
    case 'wheels': return Object.values(a.colorBalance).some((z) => z.saturation !== 0 || z.luminance !== 0);
    case 'saturation': return a.saturation !== 0;
    case 'temperature': return a.temperature !== 0 || a.tint !== 0;
    case 'curve': return JSON.stringify(a.curves) !== JSON.stringify(CURVES_IDENTITY);
    case 'vignette': return a.vignette.amount !== 0;
    default: return false;
  }
}

function AdjustBody({ tile }: { tile: AdjustTile }) {
  const a = useSession(shownAdjustments);
  const row = (label: string, key: 'exposure' | 'contrast' | 'brightness' | 'saturation' | 'highlights' | 'shadows' | 'blackPoint' | 'whitePoint' | 'temperature' | 'tint', range: [number, number], digits: number, snap: number) => (
    <ScrubSlider key={key} label={label} value={a[key]} range={range} snap={snap} format={signed(digits)} onChange={(v) => setAdjustments((q) => ({ ...q, [key]: v }))} testId={'adj-' + key} />
  );
  switch (tile) {
    case 'brightness': return <>{row(tz('Brightness', '亮度'), 'brightness', [-50, 50], 0, 5)}{row(tz('Exposure', '曝光'), 'exposure', [-3, 3], 2, 0.25)}</>;
    case 'contrast': return row(tz('Contrast', '对比度'), 'contrast', [-50, 50], 0, 5);
    case 'tone': return (
      <div className="v2-pairs">
        {row(tz('Highlights', '高光'), 'highlights', [-100, 100], 0, 5)}{row(tz('Shadows', '阴影'), 'shadows', [-100, 100], 0, 5)}
        {row(tz('Whites', '白色'), 'whitePoint', [0, 50], 0, 1)}{row(tz('Blacks', '黑色'), 'blackPoint', [0, 50], 0, 1)}
      </div>
    );
    case 'saturation': return row(tz('Saturation', '饱和度'), 'saturation', [-100, 100], 0, 5);
    case 'temperature': return <>{row(tz('Temperature', '色温'), 'temperature', [-100, 100], 0, 5)}{row(tz('Tint', '色调偏移'), 'tint', [-100, 100], 0, 5)}</>;
    case 'curve': return <Host><CurveSection /></Host>;
    case 'wheels': return <Host><ColorBalanceSection /></Host>;
    case 'vignette': return <>
      <ScrubSlider label={tz('Amount', '数量')} value={a.vignette.amount} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setAdjustments((q) => ({ ...q, vignette: { ...q.vignette, amount: v } }))} testId="adj-vignette" />
      <ScrubSlider label={tz('Midpoint', '中点')} value={a.vignette.midpoint} range={[0, 100]} snap={5} format={(v) => v.toFixed(0)} onChange={(v) => setAdjustments((q) => ({ ...q, vignette: { ...q.vignette, midpoint: v } }))} />
    </>;
    default: return null;
  }
}

function Tiles<T extends string>({ tiles, open, onToggle, edited, testId, columns }: {
  tiles: { id: T; label: () => string }[]; open: T | null; onToggle: (t: T) => void; edited: (t: T) => boolean; testId: string; columns: number;
}) {
  return (
    <div className="v2-tiles" role="group" data-testid={testId} style={{ gridTemplateColumns: `repeat(${columns}, 1fr)` }}>
      {tiles.map((t) => {
        const on = open === t.id;
        const ed = edited(t.id);
        return (
          <button key={t.id} className={'v2-tile' + (on ? ' on' : '') + (ed ? ' edited' : '')} aria-pressed={on}
            aria-label={ed ? `${t.label()}, ${tz('edited', '已编辑')}` : t.label()} data-tile={t.id} onClick={() => onToggle(t.id)}>
            <span className="v2-tile-face">{ed && <i className="v2-dot" />}</span>
            <span className="v2-tile-name">{t.label()}</span>
          </button>
        );
      })}
    </div>
  );
}

function Adjust() {
  const open = useUi((s) => s.adjustTile);
  const a = useSession(shownAdjustments);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const tiles = ADJUST_TILES.filter((t) => t.built);
  const current = tiles.find((t) => t.id === open);
  return (
    <V2Section id="adjust" title={tz('Adjust', '调整')} onReset={resetAdjustments} resetEnabled={editable}>
      <Tiles tiles={tiles} open={open} onToggle={toggleAdjustTile} edited={(t) => tileEdited(t, a)} testId="adjust-tiles" columns={4} />
      {current && <div className="v2-tile-open" data-testid={`tile-${current.id}`}>
        <div className="v2-tile-bar"><span>{current.label()}</span></div>
        <AdjustBody tile={current.id} />
      </div>}
    </V2Section>
  );
}

const DARKROOM_TILES: { id: DarkroomTile; label: () => string }[] = [
  { id: 'enlarger', label: () => tz('Enlarger', '放大机') },
  { id: 'decode', label: () => tz('Decode', '解码') },
  { id: 'effects', label: () => tz('Effects', '效果') },
];

function Effects() {
  const p = useSession((s) => s.sidecar.params);
  const e = p.effects;
  const setE = (patch: Partial<typeof e>) => setParams((q) => ({ ...q, effects: { ...q.effects, ...patch } }));
  return <>
    <Strength label={tz('Glare', '眩光')} value={e.glare} on={p.glareActive} range={EFFECT_RANGES.glare} testId="glare-strength"
      onChange={(v) => setParams((q) => ({ ...q, glareActive: v > 0, effects: { ...q.effects, glare: v > 0 ? v : q.effects.glare } }))} />
    <Strength label={tz('Couplers', '成色剂')} value={e.couplers} on={e.couplersActive} range={EFFECT_RANGES.couplers} testId="couplers-strength"
      onChange={(v) => setE({ couplersActive: v > 0, couplers: v > 0 ? v : e.couplers })} />
    <ScrubSlider label={tz('Scatter', '散射')} value={e.scatter} range={[...EFFECT_RANGES.scatter] as [number, number]} zero={1} snap={0.25} format={(v) => v.toFixed(2)} onChange={(v) => setE({ scatter: v })} />
    <ToggleRow label={tz('Sub-layers', '分层颗粒')} on={e.grainLayered} onChange={(v) => setE({ grainLayered: v })} />
    <ToggleRow label={tz('Print Effects', '相纸效果')} on={p.printEffects} onChange={(v) => setParams((q) => ({ ...q, printEffects: v }))} />
  </>;
}

function Darkroom() {
  const open = useUi((s) => s.darkroomTile);
  const p = useSession((s) => s.sidecar.params);
  const defaults = EFFECTS_DEFAULT;
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const edited = (t: DarkroomTile) => t === 'enlarger' ? p.printBrightnessStops !== 0 || p.yFilterShift !== 0 || p.mFilterShift !== 0 || p.preflashExposure !== 0
    : t === 'effects' ? p.effects.glare !== defaults.glare || p.effects.couplers !== defaults.couplers || p.effects.scatter !== defaults.scatter : false;
  return (
    <V2Section id="darkroom" title={tz('Darkroom', '暗房')} onReset={resetEnlarger} resetEnabled={editable}>
      <Tiles tiles={DARKROOM_TILES} open={open} onToggle={toggleDarkroomTile} edited={edited} testId="darkroom-tiles" columns={3} />
      {open === 'enlarger' && <div className="v2-tile-open" data-testid="tile-enlarger"><Host><EnlargerSection /></Host></div>}
      {open === 'decode' && <div className="v2-tile-open" data-testid="tile-decode"><Host><CameraSection parts="decode" /></Host></div>}
      {open === 'effects' && <div className="v2-tile-open" data-testid="tile-effects"><Effects /></div>}
    </V2Section>
  );
}

function CropPart() {
  const g = useSession((s) => s.sidecar.geometry);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const angle = g.angle ?? 0;
  return (
    <V2Section id="crop" title={tz('Crop', '裁剪')} summary={`${angle >= 0 ? '+' : '−'}${Math.abs(angle).toFixed(1)}°`} onReset={resetCrop} resetEnabled={editable}>
      <Host><CropSection /></Host>
    </V2Section>
  );
}

/** The Latitude meter, pinned at the right rail's top (README §3.5, PC-E1): the
 * scene's histogram on a fixed −8…+8 EV axis, the medium's latitude shaded,
 * the stops it holds and what falls below, within and above it. */
export function LatitudeMeter() {
  const { reply, failure } = useSession((s) => s.latitude);
  const catalog = useSession((s) => s.catalog);
  const p = useSession((s) => s.sidecar.params);
  const noFilm = useSession((s) => s.sidecar.noFilm);
  const W = 260, H = 44, lo = -8, hi = 8;
  const x = (ev: number) => ((clamp(ev, lo, hi) - lo) / (hi - lo)) * W;
  let below = 0, above = 0, total = 0;
  const bars: { x: number; w: number; h: number }[] = [];
  if (reply) {
    const h = reply.scene.histogram, f = h.placed_fractions ?? h.fractions, n = f.length;
    const peak = Math.max(...f, 1e-9);
    f.forEach((v, i) => {
      const a = h.lo_ev + (i * (h.hi_ev - h.lo_ev)) / n, b = h.lo_ev + ((i + 1) * (h.hi_ev - h.lo_ev)) / n, c = (a + b) / 2;
      total += v;
      if (c < reply.medium.shadow_ev) below += v; else if (c > reply.medium.highlight_ev) above += v;
      // Square-root heights, so a thin tail still shows.
      bars.push({ x: x(a), w: Math.max(0.5, x(b) - x(a)), h: Math.sqrt(v / peak) * (H - 2) });
    });
  }
  const pct = (v: number) => `${((v / (total || 1)) * 100).toFixed(1)} %`;
  const stops = reply ? tz(`${reply.medium.latitude_stops.toFixed(1)} stops held`, `宽容度 ${reply.medium.latitude_stops.toFixed(1)} 档`) : failure ? '' : '—';
  return (
    <div className="v2-latitude" aria-label={reply ? `${stops}, ${pct(total - below - above)} ${tz('within', '在内')}` : tz('Latitude', '宽容度')}>
      <div className="v2-lat-head"><b>{tz('Latitude', '宽容度')}</b><span className="dim">{noFilm ? tz('No film', '不应用胶片') : stops}</span></div>
      <svg className="v2-lat-plot" viewBox={`0 0 ${W} ${H}`} width="100%" height={H} data-testid="latitude-plot" preserveAspectRatio="none">
        {reply && <rect x={x(reply.medium.shadow_ev)} y={0} width={x(reply.medium.highlight_ev) - x(reply.medium.shadow_ev)} height={H} className="v2-lat-held" />}
        {bars.map((b, i) => <rect key={i} x={b.x} y={H - b.h} width={b.w} height={b.h} className="v2-lat-bar" />)}
      </svg>
      <div className="v2-lat-axis">{[-8, -4, 0, 4, 8].map((ev) => <span key={ev}>{ev > 0 ? `+${ev}` : ev < 0 ? `−${-ev}` : '0'}</span>)}</div>
      <div className="v2-lat-split"><span className="dim">{tz('Below', '低于')} {reply ? pct(below) : '—'}</span><span>{tz('Within', '在内')} {reply ? pct(total - below - above) : '—'}</span><span className="dim">{tz('Above', '高于')} {reply ? pct(above) : '—'}</span></div>
      <div className="v2-lat-pair dim">{failure ?? `${shortName(catalog, p.filmStock)}  ·  ${p.scanFilm ? tz('No paper', '不印放') : shortName(catalog, p.printStock)}`}</div>
    </div>
  );
}

export function EditRail({ mode }: { mode: string }) {
  return (
    <Rail side="right" title={tz('Edit', '编辑')} mode={mode}>
      <div className="v2-rail-fixed latitude" data-testid="latitude-meter"><LatitudeMeter /></div>
      <div className="v2-rail-scroll" data-testid="edit-sections">
        <Adjust />
        <Darkroom />
        <CropPart />
      </div>
    </Rail>
  );
}
