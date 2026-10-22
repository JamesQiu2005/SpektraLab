// LeftRail.tsx — "Film and Print" (`Panels/LeftPanel.swift`):
// Navigator · Settings Clipboard · Film · Film Edge · Date Back · Print · Crop
// · Enlarger. Everything here runs in the engine except Crop (geometry, one
// draw).

import { useEffect, useRef } from 'react';
import { ScrubSlider, Section, ToggleRow, PillMenu, Checkbox, signed } from '../controls/controls';
import { FlipH, FlipV, RotateLeft, RotateRight } from '../controls/icons';
import { t, tz, useI18n } from '../i18n';
import {
  copySettings,
  pasteSettings,
  setGeometry,
  setPages,
  setParams,
  selectFilmStock,
  selectPrintStock,
  syncSettings,
  useSession,
  zoomToFit,
  sessionStore,
  setView,
  setTool,
  changeFilmBody,
  advanceFilm,
  flipFilmGate,
  enlargerParams,
  setEnlarger,
  resetEnlarger,
  updatePair,
  canMakePair,
  makePair,
} from '../state/session';
import { EDGE_FORMATS, dateCamera, dateEffective, datePrints, edgeEffective, stockSupportsEdge } from '@shared/filmEdge';
import { CLIPBOARD_GROUPS, type ClipboardGroup } from '@shared/clipboard';
import {
  CROP_ASPECT_PICKER,
  type CropAspect,
  aspectCanonical,
  aspectHasOrientation,
  aspectIsPortrait,
  aspectLabel,
  aspectTransposed,
  outputSize,
  straightened,
  turned,
  withAspect,
} from '@shared/geometry';
import { clamp } from '@shared/params';
import { useOutput } from '../canvas/output';
import { paintOutput } from '../canvas/colorSpace';
import { StockList } from './StockList';
import { unsupportedReason } from './gate';
import { PairSection } from './PairSection';

export function LeftRail() {
  const { t: tr } = useI18n();
  return (
    <aside className="rail left" data-testid="left-rail">
      <div className="rail-header">{tr('railFilmAndPrint')}</div>
      <div className="hairline" />
      <div className="rail-scroll">
        <NavigatorSection />
        <PairSection />
        <ClipboardSection />
        <FilmSection />
        <FilmEdgeSection />
        <DateBackSection />
        <PrintSection />
        <CropSection />
        <EnlargerSection />
      </div>
    </aside>
  );
}

// ---------------------------------------------------------------- Navigator

function NavigatorSection() {
  const out = useOutput();
  const view = useSession((s) => s.view);
  const canvasPx = useSession((s) => s.canvasPx);
  const native = useSession((s) => s.nativeSize);
  const geometry = useSession((s) => s.sidecar.geometry);
  const o = native ? outputSize(geometry, native) : null;
  // The part of the output the canvas shows, in output uv.
  const vis =
    o && !view.fit
      ? (() => {
          const w = Math.min(1, canvasPx.width / (o.width * view.zoom));
          const h = Math.min(1, canvasPx.height / (o.height * view.zoom));
          return { x: clamp(view.cx - w / 2, 0, 1 - w), y: clamp(view.cy - h / 2, 0, 1 - h), w, h };
        })()
      : null;
  const pan = (e: React.PointerEvent<HTMLDivElement>) => {
    if (!o || !out) return;
    const r = e.currentTarget.getBoundingClientRect();
    // The output is letterboxed inside the well (object-fit: contain).
    const k = Math.min(r.width / out.width, r.height / out.height);
    const ox = (r.width - out.width * k) / 2;
    const oy = (r.height - out.height * k) / 2;
    const u = clamp((e.clientX - r.left - ox) / (out.width * k), 0, 1);
    const v = clamp((e.clientY - r.top - oy) / (out.height * k), 0, 1);
    const s = sessionStore.getState().view;
    setView({ fit: false, zoom: s.fit ? Math.max(1, sessionStore.getState().fitZoom * 2) : s.zoom, cx: u, cy: v });
  };
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const c = ref.current;
    if (!c) return;
    if (!out) {
      c.width = 1;
      c.height = 1;
      return;
    }
    paintOutput(c, out);
  }, [out]);
  return (
    <Section id="navigator" title={t('sectionNavigator')}>
      <div className="navigator" data-testid="navigator" onPointerDown={pan} onPointerMove={(e) => e.buttons === 1 && pan(e)}>
        <canvas ref={ref} key={out?.colorSpace ?? 'srgb'} />
        {vis && out && <NavigatorBox vis={vis} aspect={out.width / out.height} />}
        <button className="navigator-fit" onClick={zoomToFit} title={tz('Fit (,)', '适合窗口（,）')}>
          {view.fit ? t('helpFit') : `${Math.round(view.zoom * 100)} %`}
        </button>
      </div>
    </Section>
  );
}

function NavigatorBox({ vis, aspect }: { vis: { x: number; y: number; w: number; h: number }; aspect: number }) {
  // Drawn in the well's own box: the picture's letterbox is computed by CSS
  // with a percentage-based inner frame of the same aspect.
  return (
    <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', pointerEvents: 'none' }}>
      <div style={{ position: 'relative', aspectRatio: String(aspect), maxWidth: '100%', maxHeight: '100%', width: aspect >= 203 / 183 ? '100%' : 'auto', height: aspect >= 203 / 183 ? 'auto' : '100%' }}>
        <div
          style={{
            position: 'absolute',
            left: `${vis.x * 100}%`,
            top: `${vis.y * 100}%`,
            width: `${vis.w * 100}%`,
            height: `${vis.h * 100}%`,
            border: '1px solid var(--accent)',
          }}
        />
      </div>
    </div>
  );
}

// ---------------------------------------------------------------- Clipboard

const GROUP_LABEL: Record<ClipboardGroup, () => string> = {
  filmAndPaper: () => t('clipFilmAndPaper'),
  exposure: () => t('clipExposure'),
  whiteBalance: () => t('clipWhiteBalance'),
  filmEffects: () => t('clipFilmEffects'),
  printEffects: () => t('clipPrintEffects'),
  scenePlacement: () => t('clipScenePlacement'),
};

function ClipboardSection() {
  const groups = useSession((s) => s.clipboardGroups);
  const clip = useSession((s) => s.clipboard);
  const picked = useSession((s) => s.picked);
  const selection = useSession((s) => s.selection);
  const others = picked.filter((p) => p !== selection).length;
  const toggle = (g: ClipboardGroup) =>
    setPages({ clipboardGroups: groups.includes(g) ? groups.filter((x) => x !== g) : CLIPBOARD_GROUPS.filter((x) => x === g || groups.includes(x)) });
  return (
    <Section id="clipboard" title={t('sectionClipboard')}>
      {CLIPBOARD_GROUPS.map((g) => (
        <div className="row toggle-row" key={g}>
          <span className="row-label">{GROUP_LABEL[g]()}</span>
          <Checkbox on={groups.includes(g)} onChange={() => toggle(g)} label={GROUP_LABEL[g]()} />
        </div>
      ))}
      <div className="row clipboard-actions">
        <button className="btn" disabled={!selection || !groups.length} onClick={copySettings} title={t('clipCopyHelp')}>
          {t('clipCopy')}
        </button>
        <button className="btn" disabled={!clip || !selection} onClick={() => void pasteSettings()}>
          {others > 0 ? t('clipPasteTo').replace('%d', String(others + 1)) : t('clipPaste')}
        </button>
        <button className="btn" disabled={!selection || others === 0 || !groups.length} onClick={() => void syncSettings()}>
          {others > 0 ? t('clipSyncTo').replace('%d', String(others)) : t('clipSync')}
        </button>
      </div>
      <div className="caption">{clip ? tz(`Holds: ${clip.sourceName} · ${clip.groups.length} groups`, `内容：${clip.sourceName} · ${clip.groups.length} 组`) : t('clipEmpty')}</div>
    </Section>
  );
}

// --------------------------------------------------------------------- Film

function FilmSection() {
  const catalog = useSession((s) => s.catalog);
  const film = useSession((s) => s.sidecar.params.filmStock);
  const rows = catalog.filmGroups().flatMap((g) => [
    { id: '__g' + g.title, name: g.title === 'Positive' ? t('filmGroupPositive') : g.title === 'Black & White' ? tz('Black & White', '黑白') : t('filmGroupNegative'), header: true },
    ...g.films.map((f) => ({ id: f.id, name: f.name, cine: f.use === 'cine', cover: catalog.coverURL(f.id) })),
  ]);
  return (
    <Section
      id="film"
      title={t('sectionFilm')}
      menu={[
        {
          label: t('helpUseFilmPaper'),
          disabled: !catalog.stock(film)?.targetPrint,
          onSelect: () => {
            const tp = catalog.stock(film)?.targetPrint;
            if (tp) selectPrintStock(tp);
          },
        },
      ]}
    >
      <StockList rows={rows} selected={film} onSelect={selectFilmStock} testId="film-list" />
    </Section>
  );
}

// ----------------------------------------------------- Film Edge, Date Back

function FilmEdgeSection() {
  const gate = useSession((s) => s.gate);
  const fe = useSession((s) => s.sidecar.params.filmEdge);
  const stock = useSession((s) => s.catalog.stock(s.sidecar.params.filmStock));
  const tool = useSession((s) => s.tool);
  const selection = useSession((s) => s.selection);
  const pair = useSession((s) => s.pair);
  const reason = unsupportedReason('overscan', gate.overscan);
  const set = (patch: Partial<typeof fe>) => { if (gate.overscan) setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, ...patch } })); };
  const off = !gate.overscan || !fe.active;
  return (
    <Section id="filmEdge" title={t('sectionFilmEdge')} unsupported={reason}>
      <ToggleRow label={t('sectionFilmEdge')} on={fe.active} disabled={!gate.overscan} reason={reason ?? undefined} onChange={(v) => set({ active: v })} testId="film-edge-enable" />
      <PillMenu
        label={t('edgeFormat')}
        value={fe.format}
        disabled={off || !!pair}
        options={EDGE_FORMATS.map((v) => ({ value: v.id, label: v.id === '135_half' ? tz('Half frame', '半格') : v.label, group: v.gauge, disabled: !stockSupportsEdge(stock, v.id) }))}
        onChange={(v) => set({ format: v })}
        testId="film-edge-format"
      />
      <PillMenu
        label={t('edgeView')}
        value={fe.view}
        disabled={off}
        options={[
          { value: 'strip', label: t('edgeViewStrip') },
          { value: 'filed', label: t('edgeViewFiled') },
        ]}
        onChange={(v) => set({ view: v })}
      />
      {!pair && <div className="row"><span className="row-label">{tz('Framing', '取景')}</span>
        <button className="pill-menu" disabled={off || !selection} onClick={() => setTool(tool === 'crop' ? 'select' : 'crop')}>{tool === 'crop' ? tz('Done', '完成') : tz('Frame', '取景')}</button>
        <button className="icon-btn" disabled={off || !selection} onClick={flipFilmGate} title={tz('Swap gate orientation', '切换片窗横竖方向')}>↔</button></div>}
      {!pair && fe.format === '135_half' && <button className="pill-menu" disabled={off || !canMakePair()} onClick={() => void makePair(true)}>{tz('Add a second half frame…', '添加第二张半格照片…')}</button>}
      <PillMenu label={tz('Gate', '片窗')} value={fe.gate} disabled={off} options={[
        ['auto', tz('Camera', '跟随机身')], ['square', tz('Square', '直角')], ['rounded', tz('Rounded', '圆角')], ['eared', tz('Eared', '耳形')], ['shouldered', tz('Shouldered', '肩形')], ['kicked', tz('Kicked', '偏斜')],
      ].map(([value, label]) => ({ value: value!, label: label! }))} onChange={(v) => set({ gate: v })} />
      <PillMenu label={tz('Perforations', '齿孔')} value={fe.holes} disabled={off} options={[{ value: 'white', label: tz('White', '白色') }, { value: 'black', label: tz('Black', '黑色') }]} onChange={(v) => set({ holes: v })} />
      <div className="row"><span className="row-label">{tz('Camera body', '机身')} <span className="num">{fe.cameraSeed}</span></span><button className="pill-menu" disabled={off} onClick={changeFilmBody}>{tz('Another', '换一台')}</button></div>
      <div className="row"><span className="row-label">{tz('Film advance', '过片')}</span><button className="pill-menu" disabled={off} onClick={advanceFilm}>{tz('Another', '再过一格')}</button></div>
      <ScrubSlider label={tz('Frame number', '帧号')} sublabel={tz('0 = automatic', '0 = 自动')} value={fe.frameNumber} disabled={off} range={[0, 99]} snap={1} format={(v) => String(Math.round(v))} onChange={(v) => set({ frameNumber: Math.round(v) })} />
      <ScrubSlider label={t('edgeFog')} value={fe.fog} disabled={off} range={[0, 4]} zero={1} onChange={(v) => set({ fog: v })} />
      <ScrubSlider label={t('edgeLeaks')} value={fe.leaks} disabled={off} range={[0, 4]} onChange={(v) => set({ leaks: v })} />
      {fe.active && <p className="caption">{fe.edgeText}{fe.fNumber > 0 ? ` · f/${fe.fNumber}` : ''}</p>}
    </Section>
  );
}

function DateBackSection() {
  const gate = useSession((s) => s.gate);
  const d = useSession((s) => s.sidecar.params.dateBack);
  const edge = useSession((s) => s.sidecar.params.filmEdge);
  const reason = unsupportedReason('date_imprint', gate.dateImprint);
  const set = (patch: Partial<typeof d>) => { if (gate.dateImprint) setParams((p) => ({ ...p, dateBack: { ...p.dateBack, ...patch } })); };
  const camera = dateCamera(d, edge, gate), off = !gate.dateImprint || !d.active;
  const medium = camera?.gauge === '120';
  const effective = dateEffective(d, edge, gate);
  return (
    <Section id="dateBack" title={t('sectionDateBack')} unsupported={reason}>
      <ToggleRow label={t('dateImprint')} on={d.active} disabled={!gate.dateImprint} reason={reason ?? undefined} onChange={(v) => set({ active: v })} testId="date-back-enable" />
      <PillMenu
        label={t('dateFace')}
        value={d.face}
        disabled={off}
        options={[
          { value: 'lcd', label: 'LCD' },
          { value: 'dots', label: t('dateFaceDots') },
          { value: 'data', label: t('dateFaceData') },
        ].map((v) => ({ ...v, disabled: !datePrints(v.value, d, edge, gate) }))}
        onChange={(v) => set({ face: v })}
      />
      <PillMenu label={tz('Date order', '日期顺序')} value={d.order} disabled={off || d.face === 'data'} options={[{ value: 'japan', label: tz('Year month day', '年 月 日') }, { value: 'us', label: tz('Month day year', '月 日 年') }]} onChange={(v) => set({ order: v })} />
      <ToggleRow label={tz('Shooting data', '拍摄数据')} on={d.withData} disabled={off || d.face === 'data' || !datePrints('data', d, edge, gate)} onChange={(v) => set({ withData: v })} />
      <PillMenu label={tz('Placement', '位置')} value={d.placement} disabled={off || medium || d.face === 'data'} options={[{ value: 'frame', label: tz('In picture', '画面内') }, { value: 'rebate', label: tz('Film margin', '片边'), disabled: !edgeEffective(edge, gate) }]} onChange={(v) => set({ placement: v })} />
      {!medium && d.face !== 'data' && <PillMenu
        label={t('dateCorner')}
        value={d.corner}
        disabled={off}
        options={['br', 'bl', 'tr', 'tl'].map((v) => ({ value: v, label: v.toUpperCase() }))}
        onChange={(v) => set({ corner: v })}
      />}
      <ScrubSlider label={t('dateSize')} value={d.size} disabled={off} range={[0.4, camera?.id === '135_half' && d.face === 'data' ? 1 : 3]} zero={1} onChange={(v) => set({ size: v })} />
      <ScrubSlider label={t('dateBrightness')} sublabel={t('dateStops')} value={d.brightnessEV} disabled={off} range={[-2, 8]} zero={3.5} onChange={(v) => set({ brightnessEV: v })} />
      {d.active && <p className="caption">{!effective ? tz('This camera/placement needs a compatible Film Edge. Panoramic formats have no date back.', '此机型或位置需要兼容的片边；全景画幅没有日期后背。') : d.text || tz('No capture date or shooting data in this file.', '文件没有拍摄日期或拍摄数据。')}{medium && effective ? tz(' · Prints on the film margin', ' · 印在片边') : ''}</p>}
    </Section>
  );
}

// -------------------------------------------------------------------- Print

const POSITIVE_ID = '__positive';
const DIGITAL_ID = '__digital';

function PrintSection() {
  const catalog = useSession((s) => s.catalog);
  const p = useSession((s) => s.sidecar.params);
  const gate = useSession((s) => s.gate);
  const positive = catalog.isPositive(p.filmStock);
  const positiveReason = t('reasonPositiveFilmDisablesPaper');
  const silverPaper = catalog.isMonochrome(p.printStock);
  const diReason = unsupportedReason('digital_intermediate', gate.digitalIntermediate);
  const rows = [
    ...catalog.paperGroups().flatMap((g) =>
      g.papers.length
        ? [
            { id: '__g' + g.title, name: g.title === 'Still' ? t('printGroupStill') : t('printGroupCine'), header: true },
            ...g.papers.map((s) => ({ id: s.id, name: s.name, cine: s.use === 'cine',
              disabled: positive || !catalog.canPrint(p.filmStock, s.id),
              reason: positive ? positiveReason : s.monochrome
                ? tz('A black-and-white paper. Choose a black-and-white film to print on it.', '黑白相纸，需要选择黑白胶片。')
                : tz('A colour paper. A black-and-white film prints on a black-and-white paper.', '彩色相纸；黑白胶片需印放在黑白相纸上。'),
            })),
          ]
        : [],
    ),
    { id: '__gDigital', name: t('printGroupDigital'), header: true },
    { id: DIGITAL_ID, name: t('printDigitalIntermediate'), disabled: positive || !!diReason, reason: diReason ?? positiveReason },
    { id: '__gPositive', name: tz('Positive', '正片'), header: true },
    { id: POSITIVE_ID, name: t('printNone') },
  ];
  const selected = p.scanFilm || positive ? POSITIVE_ID : p.digitalIntermediate && gate.digitalIntermediate ? DIGITAL_ID : p.printStock;
  return (
    <Section id="print" title={t('sectionPrint')}>
      <StockList
        rows={rows}
        selected={selected}
        testId="paper-list"
        onSelect={(id) => {
          if (id === POSITIVE_ID) setParams((q) => ({ ...q, scanFilm: true, digitalIntermediate: false }));
          else if (id === DIGITAL_ID) setParams((q) => ({ ...q, scanFilm: false, digitalIntermediate: true }));
          else selectPrintStock(id);
        }}
      />
      <ToggleRow label={t('printEffects')} on={p.printEffects} onChange={(v) => setParams((q) => ({ ...q, printEffects: v }))} />
      <ToggleRow
        label={t('printEDR')}
        sublabel={t('statusEDRScope')}
        on={p.extendedDynamicRange}
        disabled={p.scanFilm || positive || p.digitalIntermediate || silverPaper}
        reason={silverPaper ? tz('EDR is not calibrated for silver paper.', '银盐相纸尚无 EDR 标定。') : t('reasonEDRDisabledInScanFilm')}
        onChange={(v) => setParams((q) => ({ ...q, extendedDynamicRange: v }))}
      />
    </Section>
  );
}

// --------------------------------------------------------------------- Crop

function CropSection() {
  const g = useSession((s) => s.sidecar.geometry);
  const gateHeld = useSession((s) => edgeEffective(s.sidecar.params.filmEdge, s.gate));
  const pair = useSession((s) => s.pair);
  const native = useSession((s) => s.nativeSize);
  const size = native ?? { width: 3000, height: 2000 };
  const out = native ? outputSize(g, native) : null;
  const portrait = aspectIsPortrait(g.aspect);
  if (pair) return null;
  return (
    <Section
      id="crop"
      title={t('sectionCrop')}
      onReset={() => setGeometry(() => ({ ...g, crop: { x: 0, y: 0, width: 1, height: 1 }, angle: 0, aspect: 'free', intendedSize: null, lockedRatio: null }))}
      resetHelp={t('helpResetCrop')}
      menu={[
        { label: t('helpCropWholeFrame'), onSelect: () => setGeometry((q) => ({ ...q, crop: { x: 0, y: 0, width: 1, height: 1 }, intendedSize: null })) },
        { label: t('helpStraightenZero'), onSelect: () => setGeometry((q) => straightened(q, 0, size)) },
      ]}
    >
      <div className="row">
        <span className="row-label">{t('cropAspect')}</span>
        <PillMenu<CropAspect>
          fill
          disabled={gateHeld}
          reason={tz('The film format holds the framing ratio. Change it in Film Edge.', '片边画幅限定取景比例，请在片边中调整。')}
          value={aspectCanonical(g.aspect)}
          options={CROP_ASPECT_PICKER.map((a) => ({ value: a, label: a === 'free' ? t('cropAspectFree') : a === 'original' ? t('cropAspectOriginal') : aspectLabel(a) }))}
          onChange={(a) => setGeometry((q) => withAspect(q, portrait && aspectHasOrientation(a) ? aspectTransposed(a) : a, size))}
          testId="crop-aspect"
        />
        <Checkbox
          on={portrait}
          disabled={gateHeld || !aspectHasOrientation(g.aspect)}
          label={tz('Portrait', '竖向')}
          onChange={() => setGeometry((q) => withAspect(q, aspectTransposed(q.aspect), size))}
        />
      </div>
      <ScrubSlider
        label={t('cropStraighten')}
        sublabel={tz('Ctrl-drag a horizon or vertical on the canvas', '按住 Ctrl 拖动画布上的水平线或垂直线')}
        value={g.angle}
        range={[-45, 45]}
        snap={0.5}
        format={(v) => signed(1)(v) + '°'}
        onChange={(v) => setGeometry((q) => straightened(q, v, size), { coalesce: true })}
        testId="straighten"
      />
      <div className="row">
        <span className="row-label">{t('cropRotate')}</span>
        <button className="icon-btn" title={tz('Rotate Left (Ctrl+Alt+[)', '向左旋转（Ctrl+Alt+[）')} onClick={() => setGeometry((q) => turned(q, -1))}>
          <RotateLeft />
        </button>
        <button className="icon-btn" title={tz('Rotate Right (Ctrl+Alt+])', '向右旋转（Ctrl+Alt+]）')} onClick={() => setGeometry((q) => turned(q, 1))} data-testid="rotate-right">
          <RotateRight />
        </button>
        <button className="icon-btn" title={tz('Flip Horizontally', '水平翻转')} onClick={() => setGeometry((q) => ({ ...q, flipH: !q.flipH }))}>
          <FlipH />
        </button>
        <button className="icon-btn" title={tz('Flip Vertically', '垂直翻转')} onClick={() => setGeometry((q) => ({ ...q, flipV: !q.flipV }))}>
          <FlipV />
        </button>
      </div>
      {out && (
        <div className="caption num" data-testid="crop-size">
          {out.width} × {out.height} · {((out.width * out.height) / 1e6).toFixed(1)} MP
        </div>
      )}
    </Section>
  );
}

// ----------------------------------------------------------------- Enlarger

function EnlargerSection() {
  const state = useSession((s) => s), p = enlargerParams(state);
  const side = state.pair && state.pairLayer !== 'film' ? state.pairLayer : null;
  const hole = side ? state.pair?.[side] : null;
  return (
    <Section
      id="enlarger"
      title={t('sectionEnlarger')}
      onReset={resetEnlarger}
      resetHelp={t('helpResetEnlarger')}
    >
      {side && hole && <PillMenu label={tz('Print scope', '印放范围')} value={hole.printScope}
        options={[{ value: 'frame', label: tz('Frame', '这一格') }, { value: 'film', label: tz('+ Film', '+ 胶片') }]}
        onChange={(v) => updatePair((p) => ({ ...p, [side]: { ...p[side]!, printScope: v } }))} />}
      <ScrubSlider
        label={tz('Brightness', '亮度')}
        sublabel={tz('stops', '档')}
        value={p.printBrightnessStops}
        range={[-3, 3]}
        snap={0.25}
        format={signed(2)}
        onChange={(v) => setEnlarger((q) => ({ ...q, printBrightnessStops: v }))}
        testId="enlarger-brightness"
      />
      <ScrubSlider
        label={tz('Yellow', '黄')}
        sublabel={tz('→ blue', '→ 蓝')}
        value={p.yFilterShift}
        range={[-1, 1]}
        snap={0.05}
        format={signed(2)}
        gradient="linear-gradient(90deg,#b8a860,#8a8a8a,#6f7fb0)"
        onChange={(v) => setEnlarger((q) => ({ ...q, yFilterShift: v }))}
      />
      <ScrubSlider
        label={tz('Magenta', '品红')}
        sublabel={tz('→ green', '→ 绿')}
        value={p.mFilterShift}
        range={[-1, 1]}
        snap={0.05}
        format={signed(2)}
        gradient="linear-gradient(90deg,#b07cae,#8a8a8a,#7ca87c)"
        onChange={(v) => setEnlarger((q) => ({ ...q, mFilterShift: v }))}
      />
      <ScrubSlider
        label={t('enlargerPreflash')}
        sublabel="×100"
        value={p.preflashExposure * 100}
        range={[0, 3]}
        snap={0.25}
        disabled={!p.printEffects}
        reason={t('reasonPrintEffectsOff')}
        onChange={(v) => setEnlarger((q) => ({ ...q, preflashExposure: clamp(v / 100, 0, 0.03) }))}
      />
    </Section>
  );
}

void sessionStore;
