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
  syncSettings,
  useSession,
  zoomToFit,
  sessionStore,
  setView,
} from '../state/session';
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
import { StockList } from './StockList';
import { edgeTextFor } from '@shared/stocks';
import { unsupportedReason } from './gate';
import { platform } from '../platform';

export function LeftRail() {
  const { t: tr } = useI18n();
  return (
    <aside className="rail left" data-testid="left-rail">
      <div className="rail-header">{tr('railFilmAndPrint')}</div>
      <div className="hairline" />
      <div className="rail-scroll">
        <NavigatorSection />
        <ClipboardSection />
        <FilmSection />
        <FilmEdgeSection />
        <PairSection />
        <DoubleSection />
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
    const ctx = c.getContext('2d')!;
    if (!out) {
      ctx.clearRect(0, 0, c.width, c.height);
      return;
    }
    c.width = out.width;
    c.height = out.height;
    ctx.putImageData(new ImageData(new Uint8ClampedArray(out.data), out.width, out.height), 0, 0);
  }, [out]);
  return (
    <Section id="navigator" title={t('sectionNavigator')}>
      <div className="navigator" data-testid="navigator" onPointerDown={pan} onPointerMove={(e) => e.buttons === 1 && pan(e)}>
        <canvas ref={ref} />
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
  lensCorrection: () => tz('Lens Correction', '镜头校正'),
  localLayers: () => tz('Local Layers', '局部图层'),
};

export function ClipboardSection() {
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
      <div className="row" style={{ gap: 8 }}>
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

export function FilmSection() {
  const catalog = useSession((s) => s.catalog);
  const film = useSession((s) => s.sidecar.params.filmStock);
  const rows = catalog.filmGroups().flatMap((g) => [
    { id: '__g' + g.title, name: g.title === 'Positive' ? t('filmGroupPositive') : t('filmGroupNegative'), header: true },
    ...g.films.map((f) => ({
      id: f.id,
      name: f.name,
      cine: f.use === 'cine',
      cover: catalog.coverURL(f.id),
      swatch: f.swatch ?? null,
      iso: f.iso ?? null,
    })),
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
            if (tp) setParams((p) => ({ ...p, printStock: tp, scanFilm: false }));
          },
        },
      ]}
    >
      <StockList
        rows={rows}
        selected={film}
        // Selecting a film brings its recommended paper and is scanned if it is a slide
        // (Stock.swift `FilmParams.load(film:)`); a later explicit paper choice is kept.
        onSelect={(id) =>
          setParams((p) => ({
            ...p,
            filmStock: id,
            scanFilm: catalog.isSlide(id),
            printStock: catalog.ownPaper(id) ?? catalog.paperPrinting(id, p.printStock),
            digitalIntermediate: false,
          }))
        }
        testId="film-list"
      />
    </Section>
  );
}

// ------------------------------------------------- Film Edge, Date Back (stubs)

export function FilmEdgeSection() {
  const gate = useSession((s) => s.gate);
  const fe = useSession((s) => s.sidecar.params.filmEdge);
  const film = useSession((s) => s.sidecar.params.filmStock);
  const catalog = useSession((s) => s.catalog);
  const reason = unsupportedReason('overscan', gate.overscan);
  const setFe = (patch: Partial<typeof fe>) => setParams((p) => ({ ...p, filmEdge: { ...p.filmEdge, ...patch } }));
  const roll = () => 1 + Math.floor(Math.random() * 2147483646);
  const is120 = fe.format.startsWith('120');
  return (
    <Section id="filmEdge" title={t('sectionFilmEdge')} unsupported={reason}>
      <ToggleRow label={t('sectionFilmEdge')} on={fe.active} onChange={(v) => setFe({ active: v })} />
      <PillMenu
        label={t('edgeFormat')}
        value={fe.format}
        options={['135', '135_half', '135_xpan', '135_sprocket', '120_645', '120_6x6', '120_6x7', '120_6x8', '120_6x9', '120_6x12', '120_6x17'].map((v) => ({
          value: v,
          label: v === '135_sprocket' ? tz('135 full width', '135 全幅') : v.replace('_', ' '),
        }))}
        onChange={(v) => setFe({ format: v })}
      />
      <PillMenu
        label={t('edgeView')}
        value={fe.view}
        options={[
          { value: 'strip', label: t('edgeViewStrip') },
          { value: 'filed', label: t('edgeViewFiled') },
        ]}
        onChange={(v) => setFe({ view: v })}
      />
      <PillMenu
        label={t('edgeGate')}
        value={fe.gate}
        options={(['auto', 'square', 'rounded', 'eared', 'shouldered', 'kicked'] as const).map((g) => ({
          value: g,
          label: t(('edgeGate' + g[0]!.toUpperCase() + g.slice(1)) as 'edgeGateAuto'),
        }))}
        onChange={(v) => setFe({ gate: v })}
      />
      <PillMenu
        label={t('edgeHoles')}
        value={fe.holes}
        options={[
          { value: 'white', label: t('edgeHolesWhite') },
          { value: 'black', label: t('edgeHolesBlack') },
        ]}
        onChange={(v) => setFe({ holes: v })}
      />
      <PillMenu
        label={tz('Carrier', '片夹')}
        value={fe.carrier ?? 'none'}
        options={[
          { value: 'none', label: tz('None', '无') },
          { value: 'black', label: tz('Black', '黑') },
          { value: 'open', label: tz('Open (light)', '透光') },
        ]}
        onChange={(v) => setFe({ carrier: v })}
      />
      <ScrubSlider label={t('edgeFog')} value={fe.fog} range={[0, 4]} zero={1} onChange={(v) => setFe({ fog: v })} />
      <ScrubSlider label={t('edgeLeaks')} value={fe.leaks} range={[0, 4]} onChange={(v) => setFe({ leaks: v })} />
      <ScrubSlider
        label={tz('Lens Falloff', '镜头暗角')}
        sublabel={tz('darker corners, as a wide lens on full-width film', '边角变暗，如全幅胶片上的广角镜')}
        value={fe.falloff ?? 0}
        range={[0, 1.5]}
        zero={0}
        snap={0.05}
        format={(v) => v.toFixed(2)}
        onChange={(v) => setFe({ falloff: v })}
      />
      {is120 && (
        <ToggleRow
          label={tz('65 mm Keyholes', '65mm 钥匙孔齿孔')}
          sublabel={tz('120 cut from 65 mm cine film', '由 65mm 电影胶片裁成的 120')}
          on={fe.perforation === 'ks65'}
          onChange={(v) => setFe({ perforation: v ? 'ks65' : 'none' })}
        />
      )}
      <div className="row" style={{ gap: 8 }}>
        <span className="row-label">{tz('Edge Text', '边缘文字')}</span>
        <input
          className="unit-field"
          style={{ flex: 1, minWidth: 0 }}
          value={fe.edgeText}
          placeholder={edgeTextFor(catalog, film, fe.format)}
          onChange={(e) => setFe({ edgeText: e.target.value.toUpperCase().slice(0, 40) })}
          title={tz('Empty: the film’s own words', '留空：使用胶片自己的文字')}
          data-testid="edge-text"
        />
      </div>
      <ScrubSlider
        label={tz('Frame Number', '帧号')}
        sublabel={fe.frameNumber === 0 ? tz('0: the roll decides', '0：由胶卷决定') : undefined}
        value={fe.frameNumber}
        range={[0, 99]}
        zero={0}
        snap={1}
        format={(v) => (v === 0 ? tz('Auto', '自动') : v.toFixed(0))}
        onChange={(v) => setFe({ frameNumber: Math.round(v) })}
      />
      <div className="row" style={{ gap: 8 }}>
        <button className="btn" onClick={() => setFe({ cameraSeed: roll() })} title={tz('Another camera: its gate’s shape and wobble, its spool leaks', '换一台相机：片门形状与抖动、漏光')}>
          {tz('New Camera', '换相机')}
        </button>
        <button className="btn" onClick={() => setFe({ frameSeed: roll(), seeded: true })} title={tz('Another frame on the same roll', '同一卷中的另一帧')}>
          {tz('New Frame', '换一帧')}
        </button>
      </div>
    </Section>
  );
}

// ------------------------------------------------------------- Half-Frame Pair
// Develop's half-frame pair (SpektraLab 2's Pair): this photograph and another on one piece of 135, each
// cut to the half frame's 18 x 24 and at its own exposure, the 1 mm of film between them. The host makes
// the piece (decode.pair); with the film edge on it is printed as a pair on one strip.

export function PairSection() {
  const p = useSession((s) => s.sidecar.params);
  const selection = useSession((s) => s.selection);
  const pairWith = p.pairWith ?? '';
  const name = (path: string) => path.split(/[\\/]/).pop() ?? path;
  const choose = async () => {
    const files = await platform().pickFiles(tz('Pair with another photograph', '与另一张照片组成双格'));
    const second = files[0];
    if (!second || second === selection) return;
    setParams((q) => ({ ...q, pairWith: second, pairSwap: false }));
  };
  return (
    <Section id="pair" title={tz('Half-Frame Pair', '半格双拼')}>
      <div className="caption">
        {pairWith
          ? tz(`Paired with ${name(pairWith)}`, `已与 ${name(pairWith)} 组成双格`)
          : tz('Two photographs side by side on one frame of 135, as a half-frame camera makes them.', '两张照片并排在一格 135 胶片上，如半格相机所拍。')}
      </div>
      <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
        <button className="btn" disabled={!selection} onClick={() => void choose()} data-testid="pair-with">
          {pairWith ? tz('Change…', '更换…') : tz('Pair with…', '组成双格…')}
        </button>
        <button className="btn" disabled={!pairWith} onClick={() => setParams((q) => ({ ...q, pairSwap: !q.pairSwap }))} title={tz('Swap which photograph comes first', '交换先后顺序')}>
          {tz('Swap', '交换')}
        </button>
        <button className="btn" disabled={!pairWith} onClick={() => setParams((q) => ({ ...q, pairWith: '', pairSwap: false }))}>
          {tz('Unpair', '取消双格')}
        </button>
      </div>
      {pairWith && !p.filmEdge.active && (
        <div className="caption">{tz('Tick Film Edge to see the pair on its strip.', '勾选胶片边缘即可看到胶片条上的双格。')}</div>
      )}
    </Section>
  );
}

// ------------------------------------------------------------ Double Exposure
// Develop's double exposure (SpektraLab 2's Double, RFC-048): a second photograph's light added over this
// frame on the same piece of film, each metered alone; Balance is the second's share of the light.

export function DoubleSection() {
  const p = useSession((s) => s.sidecar.params);
  const selection = useSession((s) => s.selection);
  const second = p.doubleWith ?? '';
  const name = (path: string) => path.split(/[\\/]/).pop() ?? path;
  const choose = async () => {
    const files = await platform().pickFiles(tz('Expose another photograph over this one', '在此照片上叠加曝光另一张'));
    const f = files[0];
    if (!f || f === selection) return;
    setParams((q) => ({ ...q, doubleWith: f, doubleBalance: q.doubleBalance || 0.5 }));
  };
  return (
    <Section id="double" title={tz('Double Exposure', '双重曝光')}>
      <div className="caption">
        {second
          ? tz(`Exposed with ${name(second)}`, `已与 ${name(second)} 叠加曝光`)
          : tz('Two exposures on one frame: the second photograph’s light added to this one’s.', '一格胶片两次曝光：第二张照片的光叠加在此照片上。')}
      </div>
      {p.pairWith && <div className="caption">{tz('Not with a half-frame pair: unpair first.', '半格双拼时不可用：请先取消双格。')}</div>}
      <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
        <button className="btn" disabled={!selection || !!p.pairWith} onClick={() => void choose()} data-testid="double-with">
          {second ? tz('Change…', '更换…') : tz('Expose with…', '叠加曝光…')}
        </button>
        <button className="btn" disabled={!second} onClick={() => setParams((q) => ({ ...q, doubleWith: '' }))}>
          {tz('Remove', '移除')}
        </button>
      </div>
      <ScrubSlider
        label={tz('Balance', '平衡')}
        sublabel={tz('the second exposure’s share of the light', '第二次曝光所占的光量')}
        value={Math.round((p.doubleBalance ?? 0.5) * 100)}
        range={[10, 90]}
        zero={50}
        snap={5}
        format={(v) => `${v.toFixed(0)} %`}
        disabled={!second}
        onChange={(v) => setParams((q) => ({ ...q, doubleBalance: Math.min(0.9, Math.max(0.1, v / 100)) }))}
        testId="double-balance"
      />
    </Section>
  );
}

export function DateBackSection() {
  const gate = useSession((s) => s.gate);
  const d = useSession((s) => s.sidecar.params.dateBack);
  const reason = unsupportedReason('date_imprint', gate.dateImprint);
  const set = (patch: Partial<typeof d>) => setParams((p) => ({ ...p, dateBack: { ...p.dateBack, ...patch } }));
  return (
    <Section id="dateBack" title={t('sectionDateBack')} unsupported={reason}>
      <ToggleRow label={t('dateImprint')} on={d.active} onChange={(v) => set({ active: v })} />
      <PillMenu
        label={t('dateFace')}
        value={d.face}
        options={[
          { value: 'lcd', label: 'LCD' },
          { value: 'dots', label: t('dateFaceDots') },
          { value: 'data', label: t('dateFaceData') },
        ]}
        onChange={(v) => set({ face: v })}
      />
      <PillMenu
        label={t('dateCorner')}
        value={d.corner}
        options={['br', 'bl', 'tr', 'tl'].map((v) => ({ value: v, label: v.toUpperCase() }))}
        onChange={(v) => set({ corner: v })}
      />
      <ScrubSlider label={t('dateSize')} value={d.size} range={[0.4, 3]} zero={1} onChange={(v) => set({ size: v })} />
      <ScrubSlider label={t('dateBrightness')} sublabel={t('dateStops')} value={d.brightnessEV} range={[-2, 8]} zero={3.5} onChange={(v) => set({ brightnessEV: v })} />
    </Section>
  );
}

// -------------------------------------------------------------------- Print

const POSITIVE_ID = '__positive';
const DIGITAL_ID = '__digital';

export function PrintSection() {
  const catalog = useSession((s) => s.catalog);
  const p = useSession((s) => s.sidecar.params);
  const gate = useSession((s) => s.gate);
  const positive = catalog.isPositive(p.filmStock);
  const positiveReason = t('reasonPositiveFilmDisablesPaper');
  const diReason = unsupportedReason('digital_intermediate', gate.digitalIntermediate);
  const rows = [
    ...catalog.paperGroups().flatMap((g) =>
      g.papers.length
        ? [
            { id: '__g' + g.title, name: g.title === 'Still' ? t('printGroupStill') : t('printGroupCine'), header: true },
            ...g.papers.map((s) => {
              // Silver on silver, colour on colour (Stock.swift `canPrint`): the other kind waits.
              const why = catalog.whyNotPrinted(p.filmStock, s.id);
              return { id: s.id, name: s.name, cine: s.use === 'cine', disabled: positive || !!why, reason: why ?? positiveReason };
            }),
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
          else if (!positive && catalog.canPrint(p.filmStock, id))
            setParams((q) => ({ ...q, printStock: id, scanFilm: false, digitalIntermediate: false }));
        }}
      />
      <ToggleRow label={t('printEffects')} on={p.printEffects} onChange={(v) => setParams((q) => ({ ...q, printEffects: v }))} />
      <ToggleRow
        label={t('printEDR')}
        sublabel={t('statusEDRScope')}
        on={p.extendedDynamicRange}
        disabled={p.scanFilm || positive}
        reason={t('reasonEDRDisabledInScanFilm')}
        onChange={(v) => setParams((q) => ({ ...q, extendedDynamicRange: v }))}
      />
    </Section>
  );
}

// --------------------------------------------------------------------- Crop

export function CropSection() {
  const g = useSession((s) => s.sidecar.geometry);
  const native = useSession((s) => s.nativeSize);
  const size = native ?? { width: 3000, height: 2000 };
  const out = native ? outputSize(g, native) : null;
  const portrait = aspectIsPortrait(g.aspect);
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
          value={aspectCanonical(g.aspect)}
          options={CROP_ASPECT_PICKER.map((a) => ({ value: a, label: a === 'free' ? t('cropAspectFree') : a === 'original' ? t('cropAspectOriginal') : aspectLabel(a) }))}
          onChange={(a) => setGeometry((q) => withAspect(q, portrait && aspectHasOrientation(a) ? aspectTransposed(a) : a, size))}
          testId="crop-aspect"
        />
        <Checkbox
          on={portrait}
          disabled={!aspectHasOrientation(g.aspect)}
          label={tz('Portrait', '竖向')}
          onChange={() => setGeometry((q) => withAspect(q, aspectTransposed(q.aspect), size))}
        />
      </div>
      <ScrubSlider
        label={t('cropStraighten')}
        sublabel={t('cropStraightenUnit')}
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

export function EnlargerSection() {
  const p = useSession((s) => s.sidecar.params);
  return (
    <Section
      id="enlarger"
      title={t('sectionEnlarger')}
      onReset={() => setParams((q) => ({ ...q, printBrightnessStops: 0, yFilterShift: 0, mFilterShift: 0, preflashExposure: 0 }))}
      resetHelp={t('helpResetEnlarger')}
    >
      <ScrubSlider
        label={tz('Brightness', '亮度')}
        sublabel={tz('stops', '档')}
        value={p.printBrightnessStops}
        range={[-3, 3]}
        snap={0.25}
        format={signed(2)}
        onChange={(v) => setParams((q) => ({ ...q, printBrightnessStops: v }))}
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
        onChange={(v) => setParams((q) => ({ ...q, yFilterShift: v }))}
      />
      <ScrubSlider
        label={tz('Magenta', '品红')}
        sublabel={tz('→ green', '→ 绿')}
        value={p.mFilterShift}
        range={[-1, 1]}
        snap={0.05}
        format={signed(2)}
        gradient="linear-gradient(90deg,#b07cae,#8a8a8a,#7ca87c)"
        onChange={(v) => setParams((q) => ({ ...q, mFilterShift: v }))}
      />
      <ScrubSlider
        label={t('enlargerPreflash')}
        sublabel="×100"
        value={p.preflashExposure * 100}
        range={[0, 3]}
        snap={0.25}
        disabled={!p.printEffects}
        reason={t('reasonPrintEffectsOff')}
        onChange={(v) => setParams((q) => ({ ...q, preflashExposure: clamp(v / 100, 0, 0.03) }))}
      />
    </Section>
  );
}

void sessionStore;
