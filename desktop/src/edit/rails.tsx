// rails.tsx — the Develop and Edit tools of the left column (PRD-W5 §2, the
// Mac's one window: all edits on the left, under the mode row; the Latitude
// meter heads both). The controls are the Mac's, in the Mac HIG's sections,
// drawn as desktop/design/windows draws them; their bodies are v1's
// components wherever v1 already had them (Navigator, Enlarger, Decode,
// Curve, Colour Wheels, Film Edge, Date Back, the pair), placed in the v2
// order and drawn in the v2 rows.
//
// The gates (README §3.8, R7): a section whose feature the engine refuses is
// absent — no head, no dimmed tile. An Adjust tile the v1 Layer 2 has no
// maths for (HSL, Channels, Vibrance) is not shipped either ("a tile that
// does nothing is not shipped"); `ADJUST_TILES` says which and why.

import { useEffect, useRef, useState, type ReactNode } from 'react';
import { tz } from '../i18n';
import { ScrubSlider, ToggleRow, signed } from '../controls/controls';
import {
  setAdjustments, setParams, selectFilmStock, selectPrintStock, setFilmFrame, shownAdjustments, useSession, zoomTo, zoomToFit,
  cameraExposureTotal, setCameraExposureTotal, resetCameraExposure, beginGesture, resetAdjustments, resetEnlarger, resetCrop, resetFilmStock,
  setGeometry, setTool, undo,
} from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { setUi, toggleAdjustTile, toggleDarkroomTile, useUi, type AdjustTile, type DarkroomTile } from '../app/ui';
import { EFFECT_RANGES, EFFECTS_DEFAULT, FILM_FRAMES_STILL, clamp } from '@shared/params';
import { ADJUSTMENTS_DEFAULT, CURVES_IDENTITY, type Adjustments } from '@shared/adjustments';
import {
  aspectCanonical, aspectHasOrientation, aspectIsPortrait, aspectLabel, aspectTransposed, outputSize, straightened, turned, withAspect,
  type CropAspect, type Geometry,
} from '@shared/geometry';
import type { Stock, StockCatalog } from '@shared/stocks';
import { NavigatorSection, EnlargerSection, FilmEdgeSection, DateBackSection } from '../panels/LeftRail';
import { CameraSection, CurveSection, ColorBalanceSection } from '../panels/RightRail';
import { PairSection } from '../panels/PairSection';
import { MenuList } from '../app/TitleBar';
import type { MenuEntry } from '../app/commands';
import { Glyph as G, type GlyphName } from '../theme/Glyph';
import { cardName, shortName } from './words';

// ------------------------------------------------------------------ parts

/** A button that opens a menu under itself; a press outside it, or Esc, closes it. */
export function MenuButton({ className, label, children, items, testId, align = 'left', pressed }: {
  className: string; label: string; children: ReactNode; items: () => MenuEntry[]; testId?: string; align?: 'left' | 'right'; pressed?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const away = (e: PointerEvent) => { if (!ref.current?.contains(e.target as Node)) setOpen(false); };
    const esc = (e: KeyboardEvent) => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false); } };
    window.addEventListener('pointerdown', away, true);
    window.addEventListener('keydown', esc, true);
    return () => { window.removeEventListener('pointerdown', away, true); window.removeEventListener('keydown', esc, true); };
  }, [open]);
  return (
    <div className="v2-menu-anchor" ref={ref}>
      <button className={className + (pressed ? ' on' : '')} aria-label={label} title={label} aria-haspopup="menu" aria-expanded={open} data-testid={testId}
        onClick={() => setOpen(!open)}>{children}</button>
      {open && <div className={'v2-menu-drop' + (align === 'right' ? ' right' : '')}><MenuList items={items()} onDone={() => setOpen(false)} /></div>}
    </div>
  );
}

/** Open or close every section of the rail `from` is in (Ctrl+click on a head, or a head's ···). */
function setAllSections(from: Element | null, closed: boolean) {
  const st = settingsStore.getState();
  const rail = from?.closest('.v2-rail');
  const ids = [...(rail?.querySelectorAll<HTMLElement>('[data-v2-section]') ?? [])].map((x) => `v2.${x.dataset.v2Section}`);
  const c = { ...st.collapsedSections };
  for (const k of ids) c[k] = closed;
  st.set('collapsedSections', c);
}

/**
 * A rail's section head (README §3.7, PC-E1): a thin chevron and the title;
 * at the right edge the summary while it is closed, ↺ while it is open, and
 * ··· (Reset, Open All Sections, Close All Sections). Ctrl+click on the head
 * opens or closes every section of the rail.
 */
export function V2Section({ id, title, summary, onReset, resetEnabled = true, defaultClosed = false, more = true, children, testId }: {
  id: string; title: string; summary?: string; onReset?: () => void; resetEnabled?: boolean; defaultClosed?: boolean; more?: boolean; children: ReactNode; testId?: string;
}) {
  const key = `v2.${id}`;
  const closed = useSettings((s) => s.collapsedSections[key] ?? defaultClosed);
  const head = useRef<HTMLDivElement>(null);
  const toggle = (e: React.MouseEvent) => {
    if (e.ctrlKey) { setAllSections(e.currentTarget, !closed); return; }
    const st = settingsStore.getState();
    st.set('collapsedSections', { ...st.collapsedSections, [key]: !(st.collapsedSections[key] ?? defaultClosed) });
  };
  return (
    <section className="v2-section" data-v2-section={id} data-testid={testId ?? `section-${id}`}>
      <div className="v2-section-head" ref={head}>
        <button className="v2-disclosure" aria-expanded={!closed} aria-label={title} onClick={toggle}><G name={closed ? 'chevronRight' : 'chevronDown'} /></button>
        <span className="v2-section-title" onClick={toggle}>{title}</span>
        <span className="v2-head-gap" onClick={toggle} />
        {closed && summary && <span className="v2-section-summary" data-testid={`summary-${id}`}>{summary}</span>}
        {!closed && onReset && (
          <button className="v2-head-btn" title={`${tz('Reset', '重置')} ${title}`} aria-label={`${tz('Reset', '重置')} ${title}`} disabled={!resetEnabled}
            onClick={onReset} data-testid={`section-reset-${id}`}><G name="reset" /></button>
        )}
        {more && <MenuButton className="v2-head-btn" label={`${title}: ${tz('More', '更多')}`} align="right" testId={`section-more-${id}`} items={() => [
          ...(onReset ? [{ id: `reset-${id}`, label: `${tz('Reset', '重置')} ${title}`, run: onReset, enabled: resetEnabled }, { separator: true } as const] : []),
          { id: 'open-all', label: tz('Open All Sections', '展开所有部分'), run: () => setAllSections(head.current, false), enabled: true },
          { id: 'close-all', label: tz('Close All Sections', '收起所有部分'), run: () => setAllSections(head.current, true), enabled: true },
        ]}><G name="sectionMore" /></MenuButton>}
      </div>
      {!closed && <div className="v2-section-body">{children}</div>}
    </section>
  );
}

/** A v1 section's body inside a v2 place: its own head is the v2 one. */
const Host = ({ children, testId }: { children: ReactNode; testId?: string }) => <div className="v2-host" data-testid={testId}>{children}</div>;

// -------------------------------------------------------------- Develop

function Navigator({ fold }: { fold: 'well' | 'line' | 'hidden' }) {
  const view = useSession((s) => s.view);
  if (fold === 'hidden') return null;
  const chips = (
    <div className="v2-nav-chips" data-testid="navigator-zoom">
      <button className={view.fit ? 'on' : ''} onClick={zoomToFit}>{tz('Fit', '适合')}</button>
      <button className={!view.fit && Math.abs(view.zoom - 1) < 1e-3 ? 'on' : ''} onClick={() => zoomTo(1)}>100 %</button>
      <button className={!view.fit && Math.abs(view.zoom - 2) < 1e-3 ? 'on' : ''} onClick={() => zoomTo(2)}>200 %</button>
    </div>
  );
  if (fold === 'line') return <div className="v2-navigator line" data-testid="navigator-line"><span className="v2-nav-word">{tz('Navigator', '导航器')}</span>{chips}</div>;
  return <div className="v2-navigator" data-testid="navigator-well"><Host><NavigatorSection /></Host>{chips}</div>;
}

type FilmFilter = 'all' | 'negative' | 'positive' | 'bw' | 'cine';
type PaperFilter = 'all' | 'colour' | 'bw' | 'cine';
const FILM_FILTERS: { id: FilmFilter; label: () => string; keep: (s: Stock) => boolean }[] = [
  { id: 'all', label: () => tz('All', '全部'), keep: () => true },
  { id: 'negative', label: () => tz('Negative', '负片'), keep: (s) => s.type !== 'positive' && !s.monochrome && s.use !== 'cine' },
  { id: 'positive', label: () => tz('Positive', '反转片'), keep: (s) => s.type === 'positive' },
  { id: 'bw', label: () => tz('Black & White', '黑白'), keep: (s) => !!s.monochrome },
  { id: 'cine', label: () => tz('Cine', '电影'), keep: (s) => s.use === 'cine' },
];
const PAPER_FILTERS: { id: PaperFilter; label: () => string; keep: (s: Stock) => boolean }[] = [
  { id: 'all', label: () => tz('All', '全部'), keep: () => true },
  { id: 'colour', label: () => tz('Colour', '彩色'), keep: (s) => !s.monochrome && s.use !== 'cine' },
  { id: 'bw', label: () => tz('Black & White', '黑白'), keep: (s) => !!s.monochrome },
  { id: 'cine', label: () => tz('Cine', '电影'), keep: (s) => s.use === 'cine' },
];

/** The filter capsule over a card grid: "Film · All ⌄", its menu the families. */
function FilterCapsule<T extends string>({ noun, value, filters, onChange, testId }: {
  noun: string; value: T; filters: { id: T; label: () => string }[]; onChange: (v: T) => void; testId: string;
}) {
  const current = filters.find((f) => f.id === value) ?? filters[0]!;
  return (
    <MenuButton className="v2-filter" label={`${noun} · ${current.label()}`} testId={testId}
      items={() => filters.map((f) => ({ id: `${testId}-${f.id}`, label: f.label(), run: () => onChange(f.id), enabled: true, checked: f.id === value }))}>
      <span className="v2-filter-noun">{noun}</span><span className="v2-filter-value">· {current.label()}</span><G name="filterChevron" />
    </MenuButton>
  );
}

/**
 * A stock card (README §3.2, PC-E1): the stock's picture, its name over a
 * dark strip at the foot, wrapped onto two lines inside the card. Where there
 * is no picture of the stock yet (the cards' small renders, README §8.6, wait
 * for a second preview worker) the card shows the stock's swatch: its
 * family's tone (colour negative, slide, cine, black and white, paper), never
 * an empty box.
 */
function StockCard({ stock, catalog, on, disabled, waits, title, label, onPick, cropped, kind }: {
  stock: Stock | null; catalog: StockCatalog; on: boolean; disabled: boolean; waits?: boolean; title: string; label?: string;
  onPick: () => void; cropped: boolean; kind: 'film' | 'paper';
}) {
  const cover = stock ? catalog.coverURL(stock.id) : null;
  const family = !stock ? 'none' : stock.monochrome ? 'bw' : stock.use === 'cine' ? 'cine' : stock.type === 'positive' ? 'positive' : kind === 'paper' ? 'paper' : 'negative';
  return (
    <button role="option" aria-selected={on} className={`v2-card ${kind}` + (on ? ' on' : '') + (waits ? ' waits' : '')} disabled={disabled} title={title}
      aria-label={label ?? title} onClick={onPick} data-stock={stock?.id ?? 'none'}>
      <span className={`v2-card-face ${family}` + (cover ? ' cover' : '') + (cropped ? '' : ' whole')} style={cover ? { backgroundImage: `url("${cover}")` } : undefined} />
      {stock?.use === 'cine' && kind === 'film' && <span className="v2-cine">CINE</span>}
      <span className="v2-card-name">{stock ? cardName(catalog, stock.id) : tz('No paper', '不印放')}</span>
    </button>
  );
}

function FilmPaper() {
  const catalog = useSession((s) => s.catalog);
  const p = useSession((s) => s.sidecar.params);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const [filmFilter, setFilmFilter] = useState<FilmFilter>('all');
  const [paperFilter, setPaperFilter] = useState<PaperFilter>('all');
  const cropped = useUi((s) => s.cardsCropped);
  const positive = catalog.isPositive(p.filmStock);
  const keepFilm = FILM_FILTERS.find((f) => f.id === filmFilter)!.keep;
  const keepPaper = PAPER_FILTERS.find((f) => f.id === paperFilter)!.keep;
  const films = catalog.films.filter(keepFilm);
  const papers = catalog.papers.filter(keepPaper);
  const strip = useRef<HTMLDivElement>(null);
  return (
    <V2Section id="filmPaper" title={tz('Film & Paper', '胶片与相纸')} onReset={resetFilmStock} resetEnabled={editable}>
      <div className="v2-filter-row">
        <FilterCapsule noun={tz('Film', '胶片')} value={filmFilter} filters={FILM_FILTERS} onChange={setFilmFilter} testId="film-filter" />
        <button className={'v2-square-btn' + (cropped ? ' on' : '')} aria-pressed={cropped} data-testid="cards-cropped"
          title={tz('Crop Pictures to the Cards', '图片裁切以填满卡片')} aria-label={tz('Crop Pictures to the Cards', '图片裁切以填满卡片')}
          onClick={() => setUi({ cardsCropped: !cropped })}><G name="cropToCard" /></button>
      </div>
      <div className="v2-cards" role="listbox" aria-label={tz('Film', '胶片')} data-testid="film-cards">
        {films.map((f) => (
          <StockCard key={f.id} kind="film" stock={f} catalog={catalog} on={f.id === p.filmStock} disabled={!editable} title={f.name} cropped={cropped} onPick={() => selectFilmStock(f.id)} />
        ))}
        {!films.length && <div className="v2-cards-empty dim">{tz('No film in this family.', '此类别没有胶片。')}</div>}
      </div>
      <div className="v2-filter-row">
        <FilterCapsule noun={tz('Paper', '相纸')} value={paperFilter} filters={PAPER_FILTERS} onChange={setPaperFilter} testId="paper-filter" />
      </div>
      <div className="v2-strip" ref={strip} role="listbox" aria-label={tz('Paper', '相纸')} data-testid="paper-cards"
        onWheel={(e) => { if (e.shiftKey && strip.current) strip.current.scrollLeft += e.deltaY; }}>
        {paperFilter === 'all' && (
          <StockCard kind="paper" stock={null} catalog={catalog} on={positive || p.scanFilm} disabled={!editable || positive} title={tz('No paper', '不印放')} cropped={cropped}
            onPick={() => setParams((q) => ({ ...q, scanFilm: true, digitalIntermediate: false }))} />
        )}
        {papers.map((x) => {
          const waits = positive || !catalog.canPrint(p.filmStock, x.id);
          return (
            <StockCard key={x.id} kind="paper" stock={x} catalog={catalog} on={!positive && !p.scanFilm && x.id === p.printStock} disabled={!editable || waits} waits={waits}
              title={waits ? (positive ? tz('A slide is scanned, never printed.', '反转片直接扫描，不印放。') : tz('Silver on silver, colour on colour.', '黑白配黑白，彩色配彩色。')) : x.name}
              label={waits ? `${x.name}, ${tz('not for this film', '不适用于此胶片')}` : x.name} cropped={cropped} onPick={() => selectPrintStock(x.id)} />
          );
        })}
      </div>
      <FilmExposure />
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
        {/* The scale runs under the ruler's window: its far marks are cut by the window, as drawn (data-fit="scale"). */}
        <div className="v2-ruler-scale" data-fit="scale" style={{ transform: `translateX(${-value * PX_PER_EV}px)` }}>
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
        {sizes.map((f) => {
          // The frame's shape, drawn to scale inside the card (PC-E1): the longest frame fills 44 epx.
          const k = 44 / Math.max(...sizes.map((x) => x.long));
          return (
            <button key={f.id} role="radio" aria-checked={p.filmFrame === f.id} className={'v2-size' + (p.filmFrame === f.id ? ' on' : '')} disabled={!editable} onClick={() => setFilmFrame(f.id)}>
              <i className="v2-size-frame" style={{ width: Math.max(8, f.long * k), height: Math.max(6, f.short * k) }} />
              <b>{f.id}</b><small>{`${f.short} × ${f.long}`}</small>
            </button>
          );
        })}
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

/** Develop's tools, under the column's meter: the Navigator, then Film & Paper and Format (the Mac's develop column). */
export function DevelopTools({ navigator }: { navigator: 'well' | 'line' | 'hidden' }) {
  const gate = useSession((s) => s.gate);
  return (
    <>
      {navigator !== 'hidden' && <div className="v2-rail-fixed nav"><Navigator fold={navigator} /></div>}
      <div className="v2-rail-scroll" data-testid="develop-sections">
        <FilmPaper />
        <Format />
        {gate.overscan && <V2Section id="filmEdge" title={tz('Film Edge', '片边')}><Host><FilmEdgeSection /></Host></V2Section>}
        {gate.dateImprint && <V2Section id="dateBack" title={tz('Date Back', '日期背')}><Host><DateBackSection /></Host></V2Section>}
        {gate.overscan && <Host testId="pair-host"><PairSection /></Host>}
      </div>
    </>
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

function tileEdited(id: AdjustTile, a: Adjustments): boolean {
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

/** What a tile's trash puts back: its own values, nothing else. */
function resetTile(id: AdjustTile) {
  const d = ADJUSTMENTS_DEFAULT;
  setAdjustments((q) => {
    switch (id) {
      case 'brightness': return { ...q, brightness: d.brightness, exposure: d.exposure };
      case 'contrast': return { ...q, contrast: d.contrast };
      case 'tone': return { ...q, highlights: d.highlights, shadows: d.shadows, whitePoint: d.whitePoint, blackPoint: d.blackPoint };
      case 'wheels': return { ...q, colorBalance: d.colorBalance };
      case 'saturation': return { ...q, saturation: d.saturation };
      case 'temperature': return { ...q, temperature: d.temperature, tint: d.tint };
      case 'curve': return { ...q, curves: CURVES_IDENTITY };
      case 'vignette': return { ...q, vignette: d.vignette };
      default: return q;
    }
  });
}

function AdjustBody({ tile }: { tile: AdjustTile }) {
  const a = useSession(shownAdjustments);
  const row = (label: string, key: 'exposure' | 'contrast' | 'brightness' | 'saturation' | 'highlights' | 'shadows' | 'blackPoint' | 'whitePoint' | 'temperature' | 'tint', range: [number, number], digits: number, snap: number) => (
    <ScrubSlider key={key} label={label} value={a[key]} range={range} zero={ADJUSTMENTS_DEFAULT[key]} snap={snap} format={signed(digits)} onChange={(v) => setAdjustments((q) => ({ ...q, [key]: v }))} testId={'adj-' + key} />
  );
  switch (tile) {
    case 'brightness': return <div className="v2-pairs">{row(tz('Brightness', '亮度'), 'brightness', [-50, 50], 0, 5)}{row(tz('Exposure', '曝光'), 'exposure', [-3, 3], 2, 0.25)}</div>;
    case 'contrast': return row(tz('Contrast', '对比度'), 'contrast', [-50, 50], 0, 5);
    case 'tone': return (
      <div className="v2-pairs">
        {row(tz('Highlights', '高光'), 'highlights', [-100, 100], 0, 5)}{row(tz('Shadows', '阴影'), 'shadows', [-100, 100], 0, 5)}
        {row(tz('Whites', '白色'), 'whitePoint', [0, 50], 0, 1)}{row(tz('Blacks', '黑色'), 'blackPoint', [0, 50], 0, 1)}
      </div>
    );
    case 'saturation': return row(tz('Saturation', '饱和度'), 'saturation', [-100, 100], 0, 5);
    case 'temperature': return <div className="v2-pairs">{row(tz('Temperature', '色温'), 'temperature', [-100, 100], 0, 5)}{row(tz('Tint', '色调偏移'), 'tint', [-100, 100], 0, 5)}</div>;
    case 'curve': return <Host><CurveSection /></Host>;
    case 'wheels': return <Host><ColorBalanceSection /></Host>;
    case 'vignette': return <div className="v2-pairs">
      <ScrubSlider label={tz('Amount', '数量')} value={a.vignette.amount} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setAdjustments((q) => ({ ...q, vignette: { ...q.vignette, amount: v } }))} testId="adj-vignette" />
      <ScrubSlider label={tz('Midpoint', '中点')} value={a.vignette.midpoint} range={[0, 100]} zero={ADJUSTMENTS_DEFAULT.vignette.midpoint} snap={5} format={(v) => v.toFixed(0)} onChange={(v) => setAdjustments((q) => ({ ...q, vignette: { ...q.vignette, midpoint: v } }))} />
    </div>;
    default: return null;
  }
}

/** A grid of tiles (README §3.4): a 48 epx face with its glyph, the label under it; the open one ringed. */
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
            <span className="v2-tile-face"><G name={t.id as GlyphName} />{ed && <i className="v2-dot" />}</span>
            <span className="v2-tile-name">{t.label()}</span>
          </button>
        );
      })}
    </div>
  );
}

/** The open tile's bar (PC-E1): trash (its own values back to rest), undo, its name, ✓ (close it). */
function TileBar({ title, onTrash, onDone, trashEnabled }: { title: string; onTrash: () => void; onDone: () => void; trashEnabled: boolean }) {
  const canUndo = useSession((s) => s.undo.length > 0);
  return (
    <div className="v2-tile-bar">
      <button className="v2-disc" title={`${tz('Reset', '重置')} ${title}`} aria-label={`${tz('Reset', '重置')} ${title}`} disabled={!trashEnabled} onClick={onTrash} data-testid="tile-trash"><G name="trash" /></button>
      <button className="v2-disc" title={tz('Undo', '撤销')} aria-label={tz('Undo', '撤销')} disabled={!canUndo} onClick={() => undo()} data-testid="tile-undo"><G name="undo" /></button>
      <span className="v2-tile-title">{title}</span>
      <button className="v2-disc done" title={tz('Done', '完成')} aria-label={tz('Done', '完成')} onClick={onDone} data-testid="tile-done"><G name="check" /></button>
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
        <TileBar title={current.label()} trashEnabled={editable && tileEdited(current.id, a)} onTrash={() => resetTile(current.id)} onDone={() => toggleAdjustTile(current.id)} />
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
      {open && <div className="v2-tile-open" data-testid={`tile-${open}`}>
        <TileBar title={DARKROOM_TILES.find((t) => t.id === open)!.label()} trashEnabled={editable && open !== 'decode' && edited(open)}
          onTrash={() => (open === 'enlarger' ? resetEnlarger() : open === 'effects' ? setParams((q) => ({ ...q, effects: { ...q.effects, glare: defaults.glare, couplers: defaults.couplers, scatter: defaults.scatter } })) : undefined)}
          onDone={() => toggleDarkroomTile(open)} />
        {open === 'enlarger' && <Host><EnlargerSection /></Host>}
        {open === 'decode' && <Host><CameraSection parts="decode" /></Host>}
        {open === 'effects' && <Effects />}
      </div>}
    </V2Section>
  );
}

/** The ratio chips of Crop (PC-E9), in the drawing's two rows. */
const RATIO_ROWS: CropAspect[][] = [['original', 'free', 'square'], ['r16x9', 'r5x4', 'r7x5', 'r4x3', 'r3x2']];
const ratioWords = (a: CropAspect) => a === 'original' ? tz('Original ratio', '原始比例') : a === 'free' ? tz('Freeform', '自由') : a === 'square' ? tz('Square', '正方形') : aspectLabel(a);

/** Crop's summary, as its closed head shows it (PC-E1): the ratio and the straighten angle. */
export function cropSummary(g: Geometry): string {
  const angle = g.angle ?? 0;
  return `${ratioWords(aspectCanonical(g.aspect))}  ·  ${angle >= 0 ? '+' : '−'}${Math.abs(angle).toFixed(1)}°`;
}

/** Crop (PC-E9): turn and flip, Reset, the size it makes, Straighten, orientation and ratio, and Cancel / Done while the crop stage is open. */
function CropBody() {
  const g = useSession((s) => s.sidecar.geometry);
  const native = useSession((s) => s.nativeSize);
  const tool = useSession((s) => s.tool);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const size = native ?? { width: 3000, height: 2000 };
  const out = native ? outputSize(g, native) : null;
  const portrait = aspectIsPortrait(g.aspect);
  const oriented = aspectHasOrientation(g.aspect);
  const entered = useRef<Geometry | null>(null);
  useEffect(() => { entered.current = tool === 'crop' ? (entered.current ?? g) : null; }, [tool]); // eslint-disable-line react-hooks/exhaustive-deps
  const pick = (a: CropAspect) => setGeometry((q) => withAspect(q, portrait && aspectHasOrientation(a) ? aspectTransposed(a) : a, size));
  return (
    <div className="v2-crop" data-testid="crop-body">
      <div className="v2-crop-tools">
        <div className="v2-pill-pair">
          <button title={tz('Flip Horizontally', '水平翻转')} aria-label={tz('Flip Horizontally', '水平翻转')} disabled={!editable} onClick={() => setGeometry((q) => ({ ...q, flipH: !q.flipH }))}><G name="flip" /></button>
          <button title={tz('Rotate Right', '向右旋转')} aria-label={tz('Rotate Right', '向右旋转')} disabled={!editable} onClick={() => setGeometry((q) => turned(q, 1))} data-testid="rotate-right"><G name="rotate" /></button>
        </div>
        <button className="v2-chip" disabled={!editable} onClick={resetCrop} data-testid="crop-reset">{tz('Reset', '重置')}</button>
        <span className="v2-crop-gap" />
      </div>
      {out && <div className="v2-crop-size dim" data-testid="crop-size">{out.width.toLocaleString('en-US')} × {out.height.toLocaleString('en-US')}  ·  {((out.width * out.height) / 1e6).toFixed(1)} MP</div>}
      <ScrubSlider label={tz('Straighten', '拉直')} value={g.angle} range={[-45, 45]} snap={0.5} format={(v) => signed(1)(v) + '°'}
        onChange={(v) => setGeometry((q) => straightened(q, v, size), { coalesce: true })} testId="straighten" />
      <div className="v2-caption-head">{tz('RATIO', '比例')}</div>
      <div className="v2-orientation" role="radiogroup" aria-label={tz('Orientation', '方向')}>
        <button role="radio" aria-checked={portrait} className={portrait ? 'on' : ''} disabled={!editable || !oriented} title={tz('Portrait', '竖向')} aria-label={tz('Portrait', '竖向')}
          onClick={() => { if (!portrait) setGeometry((q) => withAspect(q, aspectTransposed(q.aspect), size)); }}><G name="portrait" /></button>
        <button role="radio" aria-checked={!portrait} className={!portrait ? 'on' : ''} disabled={!editable || !oriented} title={tz('Landscape', '横向')} aria-label={tz('Landscape', '横向')}
          onClick={() => { if (portrait) setGeometry((q) => withAspect(q, aspectTransposed(q.aspect), size)); }}><G name="landscape" /></button>
      </div>
      {RATIO_ROWS.map((row, i) => (
        <div key={i} className="v2-chips" role="radiogroup" aria-label={tz('Ratio', '比例')}>
          {row.map((a) => {
            const on = aspectCanonical(g.aspect) === a;
            return <button key={a} role="radio" aria-checked={on} className={'v2-chip' + (on ? ' on' : '')} disabled={!editable} onClick={() => pick(a)} data-aspect={a}>{ratioWords(a)}</button>;
          })}
        </div>
      ))}
      {tool === 'crop' && (
        <div className="v2-crop-end">
          <button className="v2-wide" data-testid="crop-cancel" onClick={() => { const back = entered.current; if (back) setGeometry(() => back); setTool('select'); }}>{tz('Cancel', '取消')}</button>
          <button className="v2-wide on" data-testid="crop-done" onClick={() => setTool('select')}>{tz('Done', '完成')}</button>
        </div>
      )}
    </div>
  );
}

function CropPart() {
  const g = useSession((s) => s.sidecar.geometry);
  const pair = useSession((s) => s.pair);
  const editable = useSession((s) => !!s.selection && !s.batchExporting);
  const tool = useSession((s) => s.tool);
  // Crop starts closed (PC-E1), its summary at the head's right; the crop stage opens it.
  useEffect(() => {
    if (tool !== 'crop') return;
    const st = settingsStore.getState();
    if (st.collapsedSections['v2.crop'] ?? true) st.set('collapsedSections', { ...st.collapsedSections, 'v2.crop': false });
  }, [tool]);
  if (pair) return null;
  return (
    <V2Section id="crop" title={tz('Crop', '裁剪')} summary={cropSummary(g)} onReset={resetCrop} resetEnabled={editable} defaultClosed>
      <CropBody />
    </V2Section>
  );
}

/** The Latitude meter, pinned at the right rail's top (README §3.5, PC-E1): a
 * well holding the scene's histogram on a fixed −8…+8 EV axis, the medium's
 * latitude shaded, the stops it holds; under it what falls below, within and
 * above, and the pair it was measured for. Its ⌄ chooses which scene is shown
 * (as placed by Scene Placement, or as shot). While the measurement is on its
 * way the well says so; it is never an empty plot. */
export function LatitudeMeter() {
  const { reply, failure } = useSession((s) => s.latitude);
  const catalog = useSession((s) => s.catalog);
  const p = useSession((s) => s.sidecar.params);
  const noFilm = useSession((s) => s.sidecar.noFilm);
  const has = useSession((s) => !!s.selection);
  const [asShot, setAsShot] = useState(false);
  const W = 260, H = 40, lo = -8, hi = 8;
  const x = (ev: number) => ((clamp(ev, lo, hi) - lo) / (hi - lo)) * W;
  let below = 0, above = 0, total = 0;
  const bars: { x: number; w: number; h: number }[] = [];
  if (reply) {
    const h = reply.scene.histogram, f = (asShot ? h.fractions : h.placed_fractions ?? h.fractions), n = f.length;
    const peak = Math.max(...f, 1e-9);
    f.forEach((v, i) => {
      const a = h.lo_ev + (i * (h.hi_ev - h.lo_ev)) / n, b = h.lo_ev + ((i + 1) * (h.hi_ev - h.lo_ev)) / n, c = (a + b) / 2;
      total += v;
      if (c < reply.medium.shadow_ev) below += v; else if (c > reply.medium.highlight_ev) above += v;
      // Square-root heights, so a thin tail still shows.
      bars.push({ x: x(a), w: Math.max(0.5, x(b) - x(a)), h: Math.sqrt(v / peak) * (H - 2) });
    });
  }
  const state = noFilm ? 'off' : reply ? 'measured' : failure ? 'failed' : has ? 'measuring' : 'empty';
  const pct = (v: number) => `${((v / (total || 1)) * 100).toFixed(1)} %`;
  const stops = reply ? tz(`${reply.medium.latitude_stops.toFixed(1)} stops held`, `宽容度 ${reply.medium.latitude_stops.toFixed(1)} 档`) : '';
  return (
    <div className="v2-latitude" data-state={state} data-testid="latitude" aria-label={reply ? `${stops}, ${pct(total - below - above)} ${tz('within', '在内')}` : tz('Latitude', '宽容度')}>
      <div className="v2-lat-well">
        <div className="v2-lat-head">
          <MenuButton className="v2-lat-title" label={tz('Latitude', '宽容度')} testId="latitude-menu" items={() => [
            { id: 'lat-placed', label: tz('Scene as Placed', '定位后的场景'), run: () => setAsShot(false), enabled: true, checked: !asShot },
            { id: 'lat-shot', label: tz('Scene as Shot', '拍摄时的场景'), run: () => setAsShot(true), enabled: true, checked: asShot },
          ]}><b>{tz('Latitude', '宽容度')}</b><G name="latitudeChevron" /></MenuButton>
          <span className="dim">{noFilm ? tz('No film', '不应用胶片') : stops}</span>
        </div>
        <svg className="v2-lat-plot" viewBox={`0 0 ${W} ${H}`} width="100%" height={H} data-testid="latitude-plot" preserveAspectRatio="none">
          {reply && <rect x={x(reply.medium.shadow_ev)} y={0} width={x(reply.medium.highlight_ev) - x(reply.medium.shadow_ev)} height={H} className="v2-lat-held" />}
          {bars.map((b, i) => <rect key={i} x={b.x} y={H - b.h} width={b.w} height={b.h} className="v2-lat-bar" />)}
        </svg>
        {state === 'measuring' && <span className="v2-lat-wait dim" data-testid="latitude-measuring">{tz('Measuring', '正在测量')}</span>}
        <div className="v2-lat-axis">{[-8, -4, 0, 4, 8].map((ev) => <span key={ev}>{ev > 0 ? `+${ev}` : ev < 0 ? `−${-ev}` : '0'}</span>)}</div>
      </div>
      <div className="v2-lat-split"><span className="dim">{tz('Below', '低于')} {reply ? pct(below) : '—'}</span><span>{tz('Within', '在内')} {reply ? pct(total - below - above) : '—'}</span><span className="dim">{tz('Above', '高于')} {reply ? pct(above) : '—'}</span></div>
      <div className="v2-lat-pair dim">{failure ?? `${shortName(catalog, p.filmStock)}  ·  ${p.scanFilm ? tz('No paper', '不印放') : shortName(catalog, p.printStock)}`}</div>
    </div>
  );
}

/** Edit's tools, directly under the column's meter — no second tab row (the owner, 2026-10-26). */
export function EditTools() {
  return (
    <div className="v2-rail-scroll" data-testid="edit-sections">
      <Adjust />
      <Darkroom />
      <CropPart />
    </div>
  );
}
