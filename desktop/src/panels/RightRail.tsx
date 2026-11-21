// RightRail.tsx — "Parameters" (`Panels/RightPanel.swift`):
//   Pre-Dev:  Latitude · Input / Camera · Film Format · Light Leak · Lens · Advanced · Scene Placement
//   Post-Dev: White Balance · Exposure · Curve · Color Balance (Layer 2)

import { useEffect, useRef, useState } from 'react';
import { Checkbox, NumberField, PillMenu, ScrubSlider, Section, SegmentedSwitch, ToggleRow, signed } from '../controls/controls';
import { t, tz } from '../i18n';
import { hostRedecodes, setAdjustments, setDecode, setFilmFrame, setFilmSide, setParams, setSideLengthMM, useSession } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import {
  type AEMethod,
  ADVANCED_DEFAULT,
  ADVANCED_RANGES,
  type AdvancedParams,
  EFFECTS_DEFAULT,
  EFFECT_RANGES,
  LEAK_DEFAULT,
  LEAK_EDGE_REST,
  LEAK_RANGE,
  LEAK_SEED_MAX,
  LENS_CHARACTERS,
  LENS_DEFAULT,
  type LeakKind,
  type LeakSettings,
  type LensSettings,
  SOFT_FILTERS,
  SOFT_FILTER_STRENGTHS,
  FILM_FRAMES,
  FILM_FRAME_CUSTOM,
  SIDE_UNIT_DECIMALS,
  SIDE_UNIT_PER_MM,
  type SideUnit,
  aeMethodOf,
  applyAEMethod,
} from '@shared/params';
import { type ColorZone, type CurveChannel, type HSLBand, type HSLHue, type MixerChannel, BORDER_DEFAULT, BORDER_RANGES, CURVE_CHANNELS, HSL_DEFAULT, HSL_HUES, MIXER_CHANNELS, MIXER_DEFAULT, hslNeutral, isNeutral, mixerNeutral } from '@shared/adjustments';
import {
  type AsShot,
  TEMPERATURE_RANGE,
  TINT_RANGE,
  WB_MODES,
  applyBoxes,
  boxesOf,
  isRawPath,
  modeOf,
  shownDecode,
  withPreset,
  withTemperature,
  withTint,
} from '@shared/whiteBalance';
import { CurveEditor } from './CurveEditor';
import { type Watermark, type WatermarkPosition, WATERMARK_DEFAULT, WATERMARK_POSITIONS } from '@shared/watermark';
import { activeCatalog } from '@shared/stocks';
import { LensCorrectionPart } from './LensPicker';
import { type SceneLayer, type SceneLayerKind, MAX_SCENE_LAYERS, SCENE_LAYER_DEFAULT } from '@shared/sceneLayers';
import { unsupportedReason } from './gate';
import { host, HostCallError } from '../host/client';

export function RightRail() {
  const tab = useSettings((s) => s.parametersTab);
  const edited = useSession((s) => s.sidecar.adjustments.enabled && !isNeutral(s.sidecar.adjustments));
  return (
    <aside className="rail right" data-testid="right-rail">
      <div className="rail-header">{t('railParameters')}</div>
      <SegmentedSwitch
        value={tab}
        onChange={(v) => settingsStore.getState().set('parametersTab', v)}
        options={[
          { value: 'preDev', label: t('tabPreDev') },
          { value: 'postDev', label: t('tabPostDev'), marked: edited, markHelp: tz('The grade is not neutral.', '调色不是中性的。') },
        ]}
      />
      <div className="hairline" />
      <div className="rail-scroll">
        {tab === 'preDev' ? (
          <>
            <LatitudeSection />
            <CameraSection />
            <FilmFormatSection />
            <LightLeakSection />
            <LensSection />
            <LayersSection />
            <AdvancedSection />
            <ScenePlacementSection />
          </>
        ) : (
          <>
            <WhiteBalanceSection />
            <ExposureSection />
            <CurveSection />
            <HslSection />
            <ChannelMixerSection />
            <ColorBalanceSection />
            <BorderSection />
            <WatermarkSection />
          </>
        )}
      </div>
    </aside>
  );
}

// ------------------------------------------------------------------ Latitude

interface LatitudeReply {
  medium: { shadow_ev: number; highlight_ev: number; latitude_stops: number };
  scene: { histogram: { lo_ev: number; hi_ev: number; fractions: number[]; placed_fractions?: number[] } };
}

export function LatitudeSection() {
  const sid = useSession((s) => s.engineSession);
  const badge = useSession((s) => s.badge);
  const film = useSession((s) => s.sidecar.params.filmStock);
  const paper = useSession((s) => s.sidecar.params.printStock);
  const catalog = useSession((s) => s.catalog);
  const [reply, setReply] = useState<LatitudeReply | null>(null);
  const [why, setWhy] = useState<string | null>(null);
  useEffect(() => {
    if (!sid || badge !== 'full') return;
    let live = true;
    const t0 = setTimeout(() => {
      host()
        .sceneLatitude(sid, {})
        .then((r) => {
          if (live) {
            setReply(r as unknown as LatitudeReply);
            setWhy(null);
          }
        })
        .catch((e) => {
          if (!live) return;
          setReply(null);
          setWhy(e instanceof HostCallError && (e.code === 'unsupported' || e.code === 'bad_request') ? unsupportedReason('scene_latitude_mapping', false) : String((e as Error).message));
        });
    }, 250);
    return () => {
      live = false;
      clearTimeout(t0);
    };
  }, [sid, badge, film, paper]);
  const name = (id: string) => catalog.stock(id)?.name.replace(/^(Kodak|Fujifilm) (Professional )?/, '') ?? id;
  return (
    <Section id="latitude" title={t('sectionLatitude')} trailing={`${name(film)} · ${name(paper)}`} unsupported={why}>
      <LatitudePlot reply={reply} />
    </Section>
  );
}

function LatitudePlot({ reply }: { reply: LatitudeReply | null }) {
  const W = 240;
  const H = 60;
  if (!reply) return <svg className="plot" viewBox={`0 0 ${W} ${H}`} height={H} />;
  const h = reply.scene.histogram;
  const f = h.placed_fractions ?? h.fractions;
  const peak = Math.max(...f, 1e-9);
  const x = (ev: number) => ((ev - h.lo_ev) / (h.hi_ev - h.lo_ev)) * W;
  const n = f.length;
  let below = 0;
  let above = 0;
  let total = 0;
  f.forEach((v, i) => {
    const c = h.lo_ev + ((i + 0.5) * (h.hi_ev - h.lo_ev)) / n;
    total += v;
    if (c < reply.medium.shadow_ev) below += v;
    else if (c > reply.medium.highlight_ev) above += v;
  });
  const pct = (v: number) => ((v / (total || 1)) * 100).toFixed(1) + ' %';
  return (
    <>
      <svg className="plot" viewBox={`0 0 ${W} ${H}`} height={H} data-testid="latitude-plot">
        <rect x={x(reply.medium.shadow_ev)} y={0} width={x(reply.medium.highlight_ev) - x(reply.medium.shadow_ev)} height={H} fill="var(--latitude-beyond)" />
        {f.map((v, i) => (
          <rect key={i} x={(i / n) * W} y={H - (v / peak) * (H - 4)} width={W / n} height={(v / peak) * (H - 4)} fill="var(--latitude-inside)" />
        ))}
      </svg>
      <div className="caption num">
        {t('latitudeBelow')} {pct(below)} · {t('latitudeWithin')} {pct(total - below - above)} · {t('latitudeAbove')} {pct(above)} · {reply.medium.latitude_stops.toFixed(2)} {t('latitudeHeld')}
      </div>
    </>
  );
}

// -------------------------------------------------------------------- Camera

export function CameraSection() {
  const p = useSession((s) => s.sidecar.params);
  const vignette = useSession((s) => s.sidecar.adjustments.vignette.amount);
  const ae = aeMethodOf(p);
  const wb = useWhiteBalance();
  const options: { value: AEMethod; label: string }[] = [
    { value: 'custom', label: t('meteringCustom') },
    { value: 'balanced', label: t('meteringBalanced') },
    { value: 'center', label: t('meteringCenter') },
    { value: 'protect_highlights', label: t('meteringProtectHighlights') },
    { value: 'protect_shadows', label: t('meteringProtectShadows') },
  ];
  if (ae === 'legacy') options.push({ value: 'legacy', label: t('meteringCenterWeightedLegacy') });
  const asShot = !p.autoExposure && p.exposureCompensationEV === 0;
  return (
    <Section
      id="camera"
      title={t('sectionCamera')}
      onReset={() => setParams((q) => ({ ...q, exposureCompensationEV: 0 }))}
      resetHelp={t('helpResetFilmExposure')}
      menu={[
        { label: t('helpResetFilmExposure'), onSelect: () => setParams((q) => ({ ...q, exposureCompensationEV: 0 })) },
        // The presets keep their English names, as on the Mac.
        ...WB_MODES.filter((m) => m !== 'Custom').map((m) => ({
          label: `${t('helpWhiteBalancePreset')}: ${m}`,
          checked: wb.mode === m,
          disabled: !!wb.reason,
          onSelect: () => setDecode((d) => withPreset(d, wb.asShot, m)),
        })),
      ]}
    >
      <PillMenu label={t('cameraMetering')} value={ae} options={options} fill onChange={(v) => setParams((q) => applyAEMethod(q, v))} testId="metering" />
      <ScrubSlider
        label={t('cameraFilmExposure')}
        sublabel={
          <span style={{ display: 'inline-flex', gap: 4, alignItems: 'center' }}>
            {t('cameraFilmExposureAsShot')}
            <Checkbox on={asShot} label={t('cameraFilmExposureAsShot')} onChange={() => setParams((q) => ({ ...applyAEMethod(q, 'custom'), exposureCompensationEV: 0 }))} />
          </span>
        }
        value={p.exposureCompensationEV}
        range={[-3, 3]}
        snap={1 / 3}
        format={signed(1)}
        onChange={(v) => setParams((q) => ({ ...q, exposureCompensationEV: v }))}
        testId="film-exposure"
      />
      <ScrubSlider
        label={t('cameraTemperature')}
        sublabel={<AsShotLine on={wb.boxes.temp} enabled={!!wb.asShot && !wb.reason} onChange={(v) => setDecode((d) => applyBoxes(d, wb.asShot, { temp: v }))} />}
        value={wb.shown.temperature}
        range={TEMPERATURE_RANGE}
        zero={wb.asShot?.temperature ?? 5500}
        snap={100}
        format={(v) => v.toFixed(0)}
        onChange={(v) => setDecode((d) => withTemperature(d, wb.asShot, v))}
        disabled={!!wb.reason}
        reason={wb.reason ?? undefined}
        gradient="linear-gradient(90deg,#005982,#8FA83C,#FFF100)"
        testId="wb-temperature"
      />
      <ScrubSlider
        label={t('cameraTint')}
        sublabel={<AsShotLine on={wb.boxes.tint} enabled={!!wb.asShot && !wb.reason} onChange={(v) => setDecode((d) => applyBoxes(d, wb.asShot, { tint: v }))} />}
        value={wb.shown.tint}
        range={TINT_RANGE}
        zero={wb.asShot?.tint ?? 0}
        snap={5}
        format={signed(1)}
        onChange={(v) => setDecode((d) => withTint(d, wb.asShot, v))}
        disabled={!!wb.reason}
        reason={wb.reason ?? undefined}
        gradient="linear-gradient(90deg,#00A93A,#8AA45E,#E4007F)"
        testId="wb-tint"
      />
      <ScrubSlider label={t('cameraVignetting')} value={vignette} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setAdjustments((a) => ({ ...a, vignette: { ...a.vignette, amount: v } }))} />
      <LensCorrectionPart />
    </Section>
  );
}

/** "As Shot ☐" — the second line under Temperature and Tint (`AsShotLine`). */
function AsShotLine({ on, enabled, onChange }: { on: boolean; enabled: boolean; onChange: (v: boolean) => void }) {
  return (
    <span style={{ display: 'inline-flex', gap: 4, alignItems: 'center' }}>
      {t('cameraFilmExposureAsShot')}
      <Checkbox on={on} label={t('cameraFilmExposureAsShot')} disabled={!enabled} onChange={onChange} />
    </span>
  );
}

/**
 * The decode white balance as the rows read it (`WhiteBalanceRows.swift`):
 * RAW only, and only on a host that can re-decode (R2's `redecode`).
 */
function useWhiteBalance() {
  const decode = useSession((s) => s.sidecar.decode);
  const shot = useSession((s) => s.metadata?.as_shot);
  const selection = useSession((s) => s.selection);
  const kind = useSession((s) => s.frameKind);
  const methods = useSession((s) => s.hello?.methods);
  const asShot: AsShot | null = shot ? { temperature: shot.temperature_k, tint: shot.tint } : null;
  const isRaw = kind ? kind === 'raw' : !!selection && isRawPath(selection);
  let reason: string | null = null;
  if (selection && !isRaw) reason = t('reasonDecodeWBDisabled');
  else if (!hostRedecodes(methods))
    reason = tz('This engine host cannot change white balance at decode (it has no `redecode`).', '此引擎进程不能在解码时更改白平衡（没有 `redecode`）。');
  return { mode: modeOf(decode), shown: shownDecode(decode, asShot), boxes: boxesOf(decode, asShot), asShot, reason };
}

// --------------------------------------------------------------- Film Format

export function FilmFormatSection() {
  const p = useSession((s) => s.sidecar.params);
  const unit = useSettings((s) => s.sideUnit);
  const isCustom = p.filmFrame === FILM_FRAME_CUSTOM.id;
  const e = p.effects;
  const setE = (patch: Partial<typeof e>) => setParams((q) => ({ ...q, effects: { ...q.effects, ...patch } }));
  // Every effect's strength is shown (the owner, 2026-11-18); they were behind Settings' "Decouple
  // effects". 1 is the engine's own amount; 0.05 steps; double-click puts a slider back to 1.
  const strength = (label: string, key: 'halation' | 'scatter' | 'couplers' | 'glare', enabled: boolean) => (
    <ScrubSlider label={label} value={e[key]} range={[...EFFECT_RANGES[key]] as [number, number]} zero={1} snap={0.05} format={(v) => v.toFixed(2)} disabled={!enabled} reason={t('reasonEffectOff')} onChange={(v) => setE({ [key]: v })} />
  );
  return (
    <Section
      id="filmFormat"
      title={t('filmFormat')}
      onReset={() => {
        setFilmFrame('135');
        setFilmSide('short');
        setParams((q) => ({ ...q, grainActive: true, halationActive: true, glareActive: true, effects: EFFECTS_DEFAULT }));
      }}
      resetHelp={t('helpResetFilmFormat')}
      menu={[
        { label: t('helpAllEffectsOn'), onSelect: () => setParams((q) => ({ ...q, grainActive: true, halationActive: true, glareActive: true })) },
        { label: t('helpAllEffectsOff'), onSelect: () => setParams((q) => ({ ...q, grainActive: false, halationActive: false, glareActive: false })) },
        { label: t('helpResetEffectStrengths'), onSelect: () => setParams((q) => ({ ...q, effects: EFFECTS_DEFAULT })) },
        { label: t('helpSubLayerGrain'), checked: e.grainLayered, disabled: !p.grainActive, onSelect: () => setE({ grainLayered: !e.grainLayered }) },
      ]}
    >
      <PillMenu
        label={t('filmFormatSize')}
        value={p.filmFrame}
        options={FILM_FRAMES.map((f) => ({ value: f.id, label: f.id, badge: f.isCine ? 'CINE' : undefined }))}
        onChange={(v) => setFilmFrame(v)}
        testId="film-format-size"
      />
      <PillMenu
        label={t('filmFormatSide')}
        value={p.filmSide}
        options={[
          { value: 'short', label: t('filmFormatShort') },
          { value: 'long', label: t('filmFormatLong') },
        ]}
        onChange={(v) => setFilmSide(v)}
      />
      <div className="row" title={isCustom ? undefined : t('reasonNonCustomSideLength')}>
        <span className="row-label">{t('filmFormatSideLength')}</span>
        <NumberField
          value={p.sideLengthMM / SIDE_UNIT_PER_MM[unit]}
          decimals={SIDE_UNIT_DECIMALS[unit]}
          label={t('filmFormatSideLength')}
          onCommit={(v) => setSideLengthMM(v * SIDE_UNIT_PER_MM[unit])}
        />
        <PillMenu<SideUnit>
          value={unit}
          options={[
            { value: 'mm', label: 'mm' },
            { value: 'cm', label: 'cm' },
            { value: 'inch', label: 'inch' },
          ]}
          onChange={(v) => settingsStore.getState().set('sideUnit', v)}
        />
      </div>
      <ToggleRow label={t('filmGrain')} on={p.grainActive} onChange={(v) => setParams((q) => ({ ...q, grainActive: v }))} testId="grain-toggle" />
      {/* Always shown (the owner, 2026-11-18): how much grain is a judgement made photo by photo.
          1 is the engine's own amount for the film; 0.05 steps; double-click puts it back to 1. */}
      <ScrubSlider
        label={t('filmGrainStrength')}
        value={e.grain}
        range={[...EFFECT_RANGES.grain] as [number, number]}
        zero={1}
        snap={0.05}
        format={(v) => v.toFixed(2)}
        disabled={!p.grainActive}
        reason={t('reasonEffectOff')}
        onChange={(v) => setE({ grain: v })}
        testId="grain-strength"
      />
      <ToggleRow label={t('filmHalation')} on={p.halationActive} onChange={(v) => setParams((q) => ({ ...q, halationActive: v }))} />
      <ToggleRow label={t('filmAntihalationLayer')} on={!e.antihalationRemoved} disabled={!p.halationActive} reason={t('reasonEffectOff')} onChange={(v) => setE({ antihalationRemoved: !v })} />
      {strength(t('filmHalationStrength'), 'halation', p.halationActive)}
      {strength(t('filmScatterStrength'), 'scatter', p.halationActive)}
      <ScrubSlider label={t('filmHighlightBoost')} value={e.highlightBoost} range={[0, 8]} snap={0.25} format={(v) => v.toFixed(2)} disabled={!p.halationActive} reason={t('reasonEffectOff')} onChange={(v) => setE({ highlightBoost: v })} />
      <ToggleRow label={t('filmCouplers')} on={e.couplersActive} onChange={(v) => setE({ couplersActive: v })} />
      {strength(t('filmCouplersStrength'), 'couplers', e.couplersActive)}
      <ToggleRow label={t('filmGlare')} on={p.glareActive} disabled={!p.printEffects} reason={t('reasonPrintEffectsOff')} onChange={(v) => setParams((q) => ({ ...q, glareActive: v }))} />
      {strength(t('filmGlareStrength'), 'glare', p.glareActive && p.printEffects)}
    </Section>
  );
}

// ------------------------------------------------------------------ Advanced
//
// Engine settings no SpektraLab interface exposed before (params.ts `AdvancedParams`), each at the
// engine's own default until moved; double-click a slider to put it back.

export function AdvancedSection() {
  const p = useSession((s) => s.sidecar.params);
  const a = p.linuxAdvanced ?? ADVANCED_DEFAULT;
  const setA = (patch: Partial<AdvancedParams>) =>
    setParams((q) => ({ ...q, linuxAdvanced: { ...(q.linuxAdvanced ?? ADVANCED_DEFAULT), ...patch } }));
  const range = (k: keyof typeof ADVANCED_RANGES) => [...ADVANCED_RANGES[k]] as [number, number];
  // Highlight headroom only acts on a film with no anti-halation layer (CineStill 800T, or the
  // layer switched off above).
  // A slide scanned directly has no scanner black/white correction in the engine.
  const slideScan = p.scanFilm && activeCatalog().isPositive(p.filmStock);
  const slideReason = tz('Not available for a slide film scanned directly', '直接扫描的反转片不可用');
  const headroomApplies = p.halationActive && (p.effects.antihalationRemoved || p.filmStock === 'cinestill_800t');
  return (
    <Section id="advanced" title={tz('Advanced', '高级')} onReset={() => setParams((q) => ({ ...q, linuxAdvanced: ADVANCED_DEFAULT }))} resetHelp={tz('Put every advanced setting back to the engine’s own value.', '将所有高级设置恢复为引擎默认值。')}>
      <ScrubSlider
        label={tz('Development Contrast', '冲洗反差')}
        sublabel={tz('1 = the data sheet’s', '1 = 数据手册')}
        value={a.developGamma}
        range={range('developGamma')}
        zero={1}
        snap={0.05}
        format={(v) => v.toFixed(2)}
        onChange={(v) => setA({ developGamma: v })}
        testId="adv-develop-gamma"
      />
      <ScrubSlider
        label={tz('Lens Softness', '镜头柔化')}
        sublabel={tz('µm on the film', '胶片上的微米')}
        value={a.lensBlurUM}
        range={range('lensBlurUM')}
        zero={0}
        snap={1}
        format={(v) => v.toFixed(0)}
        onChange={(v) => setA({ lensBlurUM: v })}
        testId="adv-lens-blur"
      />
      <ScrubSlider
        label={tz('Scanner Softness', '扫描仪柔化')}
        value={a.scannerBlur}
        range={range('scannerBlur')}
        zero={0}
        snap={0.25}
        format={(v) => v.toFixed(2)}
        onChange={(v) => setA({ scannerBlur: v })}
        testId="adv-scanner-blur"
      />
      <ScrubSlider
        label={tz('Highlight Headroom', '高光余量')}
        sublabel={tz('stops, no anti-halation layer', '档，无防光晕层')}
        value={a.headroomEV}
        range={range('headroomEV')}
        zero={4}
        snap={0.25}
        format={(v) => v.toFixed(2)}
        disabled={!headroomApplies}
        reason={tz('Only for a film with no anti-halation layer (CineStill 800T, or the layer switched off)', '仅适用于无防光晕层的胶片（CineStill 800T，或关闭防光晕层）')}
        onChange={(v) => setA({ headroomEV: v })}
        testId="adv-headroom"
      />
      <ToggleRow label={tz('Scanner White Point', '扫描仪白点校正')} on={a.scannerWhite && !slideScan} onChange={(v) => setA({ scannerWhite: v })} disabled={slideScan} reason={slideReason} />
      <ToggleRow label={tz('Scanner Black Point', '扫描仪黑点校正')} on={a.scannerBlack && !slideScan} onChange={(v) => setA({ scannerBlack: v })} disabled={slideScan} reason={slideReason} />
    </Section>
  );
}

// ---------------------------------------------------------------- Light Leak
// SpektraLab 2's 漏光 (LensEdgePanels.swift `LeakControls`): the kind, Shuffle, its strength, and the
// Edge Burn beside it at its own strength. Light on the film, so every change re-develops.

const LEAK_LABEL: Record<LeakKind, () => string> = {
  off: () => tz('Off', '关'),
  auto: () => tz('Auto', '自动'),
  band: () => tz('Band', '光带'),
  wash: () => tz('Wash', '漫光'),
  spot: () => tz('Spot', '光斑'),
};

const LAYER_KIND_LABEL: Record<SceneLayerKind, () => string> = {
  linear: () => tz('Graduated', '渐变'),
  radial: () => tz('Radial', '径向'),
  whole: () => tz('Whole Frame', '全画面'),
};

/**
 * Local exposure layers (shared/sceneLayers.ts): graduated and radial masks, each a local amount of exposure
 * and warmth on the light before it reaches the film, so the film's own curve and colour respond to it.
 */
export function LayersSection() {
  const layers = useSession((s) => s.sidecar.params.sceneLayers) ?? [];
  const can = useSession((s) => !!s.hello?.methods?.includes('scene_layers'));
  const [sel, setSel] = useState(0);
  const i = Math.min(sel, Math.max(0, layers.length - 1));
  const cur: SceneLayer | undefined = layers[i];
  const setAll = (next: SceneLayer[]) => setParams((q) => ({ ...q, sceneLayers: next }));
  const setCur = (patch: Partial<SceneLayer>) => cur && setAll(layers.map((l, k) => (k === i ? { ...l, ...patch } : l)));
  const add = () => {
    if (layers.length >= MAX_SCENE_LAYERS) return;
    setAll([...layers, { ...SCENE_LAYER_DEFAULT }]);
    setSel(layers.length);
  };
  const remove = () => {
    setAll(layers.filter((_, k) => k !== i));
    setSel(Math.max(0, i - 1));
  };
  const unsupported = can ? null : tz('Local layers need an engine that has them.', '局部图层需要支持它的引擎。');
  return (
    <Section
      id="sceneLayers"
      title={tz('Local Layers', '局部图层')}
      onReset={() => setAll([])}
      resetEnabled={layers.length > 0}
      resetHelp={tz('No local layers.', '无局部图层。')}
      unsupported={unsupported}
    >
      <div className="row" style={{ gap: 6, flexWrap: 'wrap' }}>
        {layers.map((l, k) => (
          <button key={k} className={'btn' + (k === i ? ' on' : '')} style={{ opacity: l.enabled ? 1 : 0.5 }} onClick={() => setSel(k)} data-testid={'layer-' + k}>
            {k + 1}
          </button>
        ))}
        <button className="btn" disabled={layers.length >= MAX_SCENE_LAYERS} onClick={add} data-testid="layer-add">
          {tz('+ Add', '+ 添加')}
        </button>
        {cur && (
          <button className="btn" onClick={remove} data-testid="layer-remove">
            {tz('Remove', '删除')}
          </button>
        )}
      </div>
      {!cur ? (
        <div className="caption">{tz('Add a layer to darken a sky, lift a face or warm a corner. It changes the light reaching the film, so the film responds to it.', '添加图层可压暗天空、提亮面部或暖化角落。它改变照到胶片上的光，胶片随之响应。')}</div>
      ) : (
        <>
          <ToggleRow label={tz('On', '启用')} on={cur.enabled} onChange={(v) => setCur({ enabled: v })} />
          <PillMenu
            label={tz('Mask', '蒙版')}
            value={cur.kind}
            options={(Object.keys(LAYER_KIND_LABEL) as SceneLayerKind[]).map((k) => ({ value: k, label: LAYER_KIND_LABEL[k]() }))}
            fill
            onChange={(v) => setCur({ kind: v as SceneLayerKind })}
          />
          <ScrubSlider label={tz('Exposure', '曝光')} sublabel={tz('stops', '档')} value={cur.exposure} range={[-3, 3]} zero={0} snap={0.05} format={signed(2)} onChange={(v) => setCur({ exposure: v })} />
          <ScrubSlider label={tz('Warmth', '色温')} sublabel={tz('cool … warm', '冷 … 暖')} value={cur.warmth} range={[-100, 100]} zero={0} snap={1} format={signed(0)} onChange={(v) => setCur({ warmth: v })} />
          <ScrubSlider label={tz('Opacity', '不透明度')} value={cur.opacity * 100} range={[0, 100]} zero={100} snap={1} format={(v) => v.toFixed(0)} onChange={(v) => setCur({ opacity: v / 100 })} />
          {cur.kind !== 'whole' && (
            <>
              {cur.kind === 'linear' && (
                <ScrubSlider label={tz('Angle', '角度')} sublabel={tz('0 = the top, 90 = the right', '0 = 顶部，90 = 右侧')} value={cur.angle} range={[-180, 180]} zero={0} snap={5} format={(v) => `${v.toFixed(0)}°`} onChange={(v) => setCur({ angle: v })} />
              )}
              <ScrubSlider label={tz('Across', '左右')} value={cur.x * 100} range={[0, 100]} zero={50} snap={1} format={(v) => v.toFixed(0)} onChange={(v) => setCur({ x: v / 100 })} />
              <ScrubSlider label={tz('Up / Down', '上下')} value={cur.y * 100} range={[0, 100]} zero={cur.kind === 'linear' ? 40 : 50} snap={1} format={(v) => v.toFixed(0)} onChange={(v) => setCur({ y: v / 100 })} />
              {cur.kind === 'radial' && (
                <ScrubSlider label={tz('Size', '大小')} value={cur.radius * 100} range={[5, 150]} zero={40} snap={1} format={(v) => v.toFixed(0)} onChange={(v) => setCur({ radius: v / 100 })} />
              )}
              <ScrubSlider label={tz('Feather', '羽化')} value={cur.feather * 100} range={[0, 100]} zero={50} snap={1} format={(v) => v.toFixed(0)} onChange={(v) => setCur({ feather: v / 100 })} />
              <ToggleRow label={tz('Invert', '反转')} sublabel={tz('affect the other side', '作用于另一侧')} on={cur.invert} onChange={(v) => setCur({ invert: v })} />
            </>
          )}
        </>
      )}
    </Section>
  );
}

export function LightLeakSection() {
  const lk = useSession((s) => s.sidecar.params.leak) ?? LEAK_DEFAULT;
  const setLeak = (patch: Partial<LeakSettings>) =>
    setParams((q) => ({ ...q, leak: { ...(q.leak ?? LEAK_DEFAULT), ...patch } }));
  const kindOn = lk.kind !== 'off';
  const edgeOn = lk.edge > 0;
  const shuffle = () => {
    let next = lk.seed;
    while (next === lk.seed) next = 1 + Math.floor(Math.random() * LEAK_SEED_MAX);
    setLeak({ seed: next });
  };
  return (
    <Section
      id="lightLeak"
      title={tz('Light Leak', '漏光')}
      onReset={() => setParams((q) => ({ ...q, leak: LEAK_DEFAULT }))}
      resetEnabled={kindOn || edgeOn || lk.seed !== 0 || lk.amount !== LEAK_DEFAULT.amount}
      resetHelp={tz('No light leak.', '无漏光。')}
      menu={[
        {
          label: tz('Camera’s Own Leak', '相机默认漏光'),
          disabled: lk.seed === 0,
          onSelect: () => setLeak({ seed: 0 }),
        },
      ]}
    >
      <PillMenu
        label={tz('Kind', '类型')}
        value={(lk.kind as LeakKind) ?? 'off'}
        options={(Object.keys(LEAK_LABEL) as LeakKind[]).map((k) => ({ value: k, label: LEAK_LABEL[k]() }))}
        fill
        onChange={(v) => setLeak({ kind: v })}
        testId="leak-kind"
      />
      <ScrubSlider
        label={tz('Strength', '强度')}
        sublabel={tz('1 reaches orange, 4 clips to white', '1 为橙色，4 溢出为白')}
        value={lk.amount}
        range={[...LEAK_RANGE] as [number, number]}
        zero={LEAK_DEFAULT.amount}
        snap={0.05}
        format={(v) => v.toFixed(2)}
        disabled={!kindOn}
        reason={tz('Choose a kind of leak first', '请先选择漏光类型')}
        onChange={(v) => setLeak({ amount: v })}
        testId="leak-amount"
      />
      <ToggleRow
        label={tz('Edge Burn', '边缘漏光')}
        sublabel={tz('light along the film’s long edges', '沿胶片长边的漏光')}
        on={edgeOn}
        onChange={(v) => setLeak({ edge: v ? LEAK_EDGE_REST : 0 })}
        testId="leak-edge"
      />
      <ScrubSlider
        label={tz('Edge Strength', '边缘强度')}
        value={lk.edge}
        range={[0.05, LEAK_RANGE[1]]}
        zero={LEAK_EDGE_REST}
        snap={0.05}
        format={(v) => v.toFixed(2)}
        disabled={!edgeOn}
        reason={tz('Switch the Edge Burn on first', '请先打开边缘漏光')}
        onChange={(v) => setLeak({ edge: v })}
        testId="leak-edge-amount"
      />
      <div className="row" style={{ gap: 8 }}>
        <button
          className="btn"
          disabled={!kindOn && !edgeOn}
          onClick={shuffle}
          title={tz('A new place, edge and shape for this leak. The menu (…) gives the camera’s own back.', '为漏光换一个新位置、边缘与形状。菜单（…）可恢复相机默认。')}
          data-testid="leak-shuffle"
        >
          {tz('Shuffle', '随机')}
        </button>
        <span className="caption">{lk.seed === 0 ? tz('The camera’s own leak', '相机默认漏光') : tz('Shuffled', '已随机')}</span>
      </div>
    </Section>
  );
}

// ---------------------------------------------------------------------- Lens
// SpektraLab 2's 镜头 (LensEdgePanels.swift `LensControls`): the soft filter in front of the lens at its
// five grades, and the lens's character at an amount. Both act on the photo before the film.

const SOFT_FILTER_LABEL: Record<string, () => string> = {
  black_pro_mist: () => tz('Black Mist', '黑柔'),
  pro_mist: () => tz('White Mist', '白柔'),
  glimmerglass: () => tz('Glimmer', '闪柔'),
  cinebloom: () => tz('Bloom', '晕柔'),
};
const LENS_CHARACTER_LABEL: Record<string, () => string> = {
  helios44: () => tz('Swirl', '旋焦'),
  petzval: () => tz('Petzval', '佩兹伐'),
  vintage_soft: () => tz('Vintage', '老镜'),
  plastic: () => tz('Toy', '玩具镜'),
};
const strengthText = (s: number) => (s === 0.125 ? '1/8' : s === 0.25 ? '1/4' : s === 0.5 ? '1/2' : String(s));

export function LensSection() {
  const ln = useSession((s) => s.sidecar.params.lens) ?? LENS_DEFAULT;
  const setLens = (patch: Partial<LensSettings>) =>
    setParams((q) => ({ ...q, lens: { ...(q.lens ?? LENS_DEFAULT), ...patch } }));
  const OFF = '__off';
  // The grade's detents are powers of two, so the slider runs in stops of it: one step is one detent.
  const stops = Math.log2(Math.max(ln.strength, 0.125));
  return (
    <Section
      id="lens"
      title={tz('Lens', '镜头')}
      onReset={() => setParams((q) => ({ ...q, lens: LENS_DEFAULT }))}
      resetEnabled={ln.filter !== null || ln.character !== null || ln.strength !== LENS_DEFAULT.strength || ln.amount !== LENS_DEFAULT.amount}
      resetHelp={tz('No soft filter and no lens character.', '无柔光镜，无镜头像差。')}
    >
      <PillMenu
        label={tz('Soft Filter', '柔光镜')}
        value={ln.filter ?? OFF}
        options={[{ value: OFF, label: tz('Off', '关') }, ...SOFT_FILTERS.map((f) => ({ value: f as string, label: SOFT_FILTER_LABEL[f]!() }))]}
        fill
        onChange={(v) => setLens({ filter: v === OFF ? null : v })}
        testId="lens-filter"
      />
      <ScrubSlider
        label={tz('Filter Strength', '柔光强度')}
        sublabel={tz('the filter’s grade', '柔光镜等级')}
        value={stops}
        range={[-3, 1]}
        zero={-1}
        snap={1}
        format={(v) => strengthText(Math.pow(2, Math.round(v)))}
        parse={(txt) => {
          const m = /^\s*(\d+)\s*\/\s*(\d+)\s*$/.exec(txt);
          const v = m ? Number(m[1]) / Number(m[2]) : Number(txt);
          return Number.isFinite(v) && v > 0 ? Math.log2(v) : null;
        }}
        disabled={ln.filter === null}
        reason={tz('Choose a soft filter first', '请先选择柔光镜')}
        onChange={(v) => {
          const s = Math.pow(2, Math.min(1, Math.max(-3, Math.round(v))));
          if ((SOFT_FILTER_STRENGTHS as readonly number[]).includes(s)) setLens({ strength: s });
        }}
        testId="lens-filter-strength"
      />
      <PillMenu
        label={tz('Character', '像差')}
        value={ln.character ?? OFF}
        options={[{ value: OFF, label: tz('Off', '关') }, ...LENS_CHARACTERS.map((c) => ({ value: c as string, label: LENS_CHARACTER_LABEL[c]!() }))]}
        fill
        onChange={(v) => setLens({ character: v === OFF ? null : v })}
        testId="lens-character"
      />
      <ScrubSlider
        label={tz('Amount', '程度')}
        value={ln.amount * 100}
        range={[0, 100]}
        zero={100}
        snap={1}
        format={(v) => `${v.toFixed(0)} %`}
        disabled={ln.character === null}
        reason={tz('Choose a lens character first', '请先选择镜头像差')}
        onChange={(v) => setLens({ amount: Math.min(1, Math.max(0, v / 100)) })}
        testId="lens-amount"
      />
    </Section>
  );
}

// ----------------------------------------------------------- Scene Placement

export function ScenePlacementSection() {
  const gate = useSession((s) => s.gate);
  const sl = useSession((s) => s.sidecar.params.sceneLatitude);
  const reason = unsupportedReason('scene_latitude_mapping', gate.sceneLatitude);
  return (
    <Section id="scenePlacement" title={t('sectionScenePlacement')} unsupported={reason} onReset={() => {}} resetHelp={t('helpResetPlacement')} resetEnabled={sl.active}>
      <ScrubSlider label={t('placementHighlight')} value={sl.highlightPullBack} range={[0, 8]} snap={0.25} onChange={() => {}} disabled={!!reason} reason={reason ?? undefined} />
      <ScrubSlider label={t('placementShadow')} value={sl.shadowPullBack} range={[0, 8]} snap={0.25} onChange={() => {}} disabled={!!reason} reason={reason ?? undefined} />
    </Section>
  );
}

// ---------------------------------------------------------------- Post-Dev

export function WhiteBalanceSection() {
  const a = useSession((s) => s.sidecar.adjustments);
  return (
    <Section id="wb2" title={t('sectionWhiteBalance')} trailing={t('statusRightRailWBScope')} onReset={() => setAdjustments((q) => ({ ...q, temperature: 0, tint: 0 }))} resetHelp={t('helpReset')}>
      <ScrubSlider label={t('cameraTemperature')} value={a.temperature} range={[-100, 100]} snap={5} format={signed(0)} gradient="linear-gradient(90deg,#5d7de8,#bbb,#e8c04e)" onChange={(v) => setAdjustments((q) => ({ ...q, temperature: v }))} />
      <ScrubSlider label={t('cameraTint')} value={a.tint} range={[-100, 100]} snap={5} format={signed(0)} gradient="linear-gradient(90deg,#62c462,#bbb,#d05bd0)" onChange={(v) => setAdjustments((q) => ({ ...q, tint: v }))} />
    </Section>
  );
}

export function ExposureSection() {
  const a = useSession((s) => s.sidecar.adjustments);
  const row = (label: string, key: 'exposure' | 'contrast' | 'brightness' | 'saturation' | 'vibrance' | 'highlights' | 'shadows' | 'blackPoint' | 'whitePoint', range: [number, number], digits: number, snap: number) => (
    <ScrubSlider key={key} label={label} value={a[key]} range={range} snap={snap} format={signed(digits)} onChange={(v) => setAdjustments((q) => ({ ...q, [key]: v }))} testId={'adj-' + key} />
  );
  return (
    <Section
      id="exposure2"
      title={t('sectionExposure')}
      onReset={() => setAdjustments((q) => ({ ...q, exposure: 0, contrast: 0, brightness: 0, saturation: 0, vibrance: 0, highlights: 0, shadows: 0, blackPoint: 0, whitePoint: 0 }))}
      resetHelp={t('helpReset')}
    >
      {row(t('clipExposure'), 'exposure', [-3, 3], 2, 1 / 3)}
      {row(t('exposureContrast'), 'contrast', [-50, 50], 0, 5)}
      {row(t('exposureBrightness'), 'brightness', [-50, 50], 0, 5)}
      {row(t('exposureSaturation'), 'saturation', [-100, 100], 0, 5)}
      {row(tz('Vibrance', '自然饱和度'), 'vibrance', [-100, 100], 0, 5)}
      {row(t('exposureHighlights'), 'highlights', [-100, 100], 0, 5)}
      {row(t('exposureShadows'), 'shadows', [-100, 100], 0, 5)}
      {/* SpektraLab 2's Whites and Blacks (Adjustments.swift `blacks`, `whites`): two-way, -50..+50.
          Blacks is -blackPoint (+ lifts, - crushes), Whites is whitePoint (+ brightens, - dims); the
          fields and the Layer 2 formula are unchanged, so a sidecar from either app reads the same. */}
      <ScrubSlider
        label={tz('Blacks', '黑色')}
        value={-a.blackPoint}
        range={[-50, 50]}
        zero={0}
        snap={1}
        format={signed(0)}
        onChange={(v) => setAdjustments((q) => ({ ...q, blackPoint: -v }))}
        testId="adj-blacks"
      />
      <ScrubSlider
        label={tz('Whites', '白色')}
        value={a.whitePoint}
        range={[-50, 50]}
        zero={0}
        snap={1}
        format={signed(0)}
        onChange={(v) => setAdjustments((q) => ({ ...q, whitePoint: v }))}
        testId="adj-whites"
      />
    </Section>
  );
}

const CHANNEL_LABEL: Record<CurveChannel, () => string> = {
  rgb: () => 'RGB',
  luma: () => t('curveLuma'),
  red: () => t('curveRed'),
  green: () => t('curveGreen'),
  blue: () => t('curveBlue'),
};

export function CurveSection() {
  const [ch, setCh] = useState<CurveChannel>('rgb');
  return (
    <Section
      id="curve"
      title={t('sectionCurve')}
      onReset={() => setAdjustments((q) => ({ ...q, curves: { ...q.curves, [ch]: { points: [[0, 0], [1, 1]] } } }))}
      resetHelp={t('helpReset')}
      menu={[{ label: t('helpResetChannels'), onSelect: () => setAdjustments((q) => ({ ...q, curves: { rgb: { points: [[0, 0], [1, 1]] }, luma: { points: [[0, 0], [1, 1]] }, red: { points: [[0, 0], [1, 1]] }, green: { points: [[0, 0], [1, 1]] }, blue: { points: [[0, 0], [1, 1]] } } })) }]}
    >
      <div className="row" style={{ gap: 4 }}>
        {CURVE_CHANNELS.map((c) => (
          <button key={c} className={'btn' + (c === ch ? ' primary' : '')} style={{ height: 18, padding: '0 8px', fontSize: 'var(--fs-small)' }} onClick={() => setCh(c)}>
            {CHANNEL_LABEL[c]()}
          </button>
        ))}
      </div>
      <CurveEditor channel={ch} />
    </Section>
  );
}

const ZONES: { key: 'master' | 'shadows' | 'midtones' | 'highlights'; label: () => string }[] = [
  { key: 'master', label: () => tz('Master', '整体') },
  { key: 'shadows', label: () => t('exposureShadows') },
  { key: 'midtones', label: () => t('balanceMidtones') },
  { key: 'highlights', label: () => t('exposureHighlights') },
];

// -------------------------------------------------------------------- Border
//
// A plain frame round the finished picture (Adjustments.border): shown on the canvas, written into
// every exported file. White, black or any grey; each side a share of the picture's long edge, the
// bottom optionally deeper.

export function BorderSection() {
  const b = useSession((s) => s.sidecar.adjustments.border) ?? BORDER_DEFAULT;
  const set = (patch: Partial<typeof b>) => setAdjustments((q) => ({ ...q, border: { ...(q.border ?? BORDER_DEFAULT), ...patch } }));
  const preset = b.tone >= 0.999 ? 'white' : b.tone <= 0.001 ? 'black' : 'grey';
  return (
    <Section id="border" title={tz('Border', '边框')} onReset={() => setAdjustments((q) => ({ ...q, border: BORDER_DEFAULT }))} resetHelp={tz('No border.', '无边框。')}>
      <ToggleRow label={tz('Border', '边框')} on={b.enabled} onChange={(v) => set({ enabled: v })} testId="border-toggle" />
      <PillMenu
        label={tz('Colour', '颜色')}
        value={preset}
        options={[
          { value: 'white', label: tz('White', '白色') },
          { value: 'black', label: tz('Black', '黑色') },
          { value: 'grey', label: tz('Grey', '灰色') },
        ]}
        onChange={(v) => set({ enabled: true, tone: v === 'white' ? 1 : v === 'black' ? 0 : 0.5 })}
      />
      <ScrubSlider
        label={tz('Tone', '明度')}
        sublabel={tz('0 black, 100 white', '0 黑，100 白')}
        value={Math.round(b.tone * 100)}
        range={[0, 100]}
        zero={100}
        snap={1}
        format={(v) => v.toFixed(0)}
        disabled={!b.enabled}
        onChange={(v) => set({ tone: v / 100 })}
        testId="border-tone"
      />
      <ScrubSlider
        label={tz('Size', '宽度')}
        sublabel={tz('% of the long edge', '长边的 %')}
        value={b.size}
        range={[...BORDER_RANGES.size] as [number, number]}
        zero={BORDER_DEFAULT.size}
        snap={0.25}
        format={(v) => v.toFixed(2) + ' %'}
        disabled={!b.enabled}
        onChange={(v) => set({ size: v })}
        testId="border-size"
      />
      <ScrubSlider
        label={tz('Deeper Bottom', '底边加宽')}
        sublabel={tz('gallery / instant print', '画廊 / 拍立得')}
        value={b.bottomExtra}
        range={[...BORDER_RANGES.bottomExtra] as [number, number]}
        zero={0}
        snap={0.25}
        format={(v) => v.toFixed(2) + ' %'}
        disabled={!b.enabled}
        onChange={(v) => set({ bottomExtra: v })}
        testId="border-bottom"
      />
    </Section>
  );
}

// ---------------------------------------------------------------------- HSL
// SpektraLab 2's HSL (Adjustments.swift HSLSet): pick one of eight colours, then its hue, saturation and
// luminance, −100…100 each. ±100 hue turns the colour a third of the way to the next primary.

const HSL_LABEL: Record<HSLHue, () => string> = {
  red: () => tz('Red', '红'),
  orange: () => tz('Orange', '橙'),
  yellow: () => tz('Yellow', '黄'),
  green: () => tz('Green', '绿'),
  aqua: () => tz('Aqua', '青'),
  blue: () => tz('Blue', '蓝'),
  purple: () => tz('Purple', '紫'),
  magenta: () => tz('Magenta', '品红'),
};
const HSL_SWATCH: Record<HSLHue, string> = {
  red: '#e0403a', orange: '#e8862e', yellow: '#e2c93a', green: '#4caf50', aqua: '#36b5c4', blue: '#3a6fe0', purple: '#8a4fd8', magenta: '#d64fb8',
};

export function HslSection() {
  const hsl = useSession((s) => s.sidecar.adjustments.hsl) ?? HSL_DEFAULT;
  const [pick, setPick] = useState<HSLHue>('red');
  const band = hsl[pick];
  const setBand = (patch: Partial<HSLBand>) =>
    setAdjustments((q) => ({ ...q, hsl: { ...(q.hsl ?? HSL_DEFAULT), [pick]: { ...(q.hsl ?? HSL_DEFAULT)[pick], ...patch } } }));
  return (
    <Section id="hsl" title="HSL" onReset={() => setAdjustments((q) => ({ ...q, hsl: HSL_DEFAULT }))} resetEnabled={!hslNeutral(hsl)} resetHelp={t('helpReset')}>
      <div className="row hsl-swatches" role="radiogroup" aria-label={tz('Colour', '颜色')}>
        {HSL_HUES.map((h) => {
          const b = hsl[h];
          const moved = b.hue !== 0 || b.saturation !== 0 || b.luminance !== 0;
          return (
            <button
              key={h}
              role="radio"
              aria-checked={h === pick}
              title={HSL_LABEL[h]()}
              className={'hsl-swatch' + (h === pick ? ' on' : '') + (moved ? ' moved' : '')}
              style={{ background: HSL_SWATCH[h] }}
              onClick={() => setPick(h)}
              data-testid={'hsl-' + h}
            />
          );
        })}
      </div>
      <div className="caption">{HSL_LABEL[pick]()}</div>
      <ScrubSlider label={tz('Hue', '色相')} value={band.hue} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setBand({ hue: v })} testId="hsl-hue" />
      <ScrubSlider label={tz('Saturation', '饱和度')} value={band.saturation} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setBand({ saturation: v })} testId="hsl-saturation" />
      <ScrubSlider label={tz('Luminance', '明度')} value={band.luminance} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setBand({ luminance: v })} testId="hsl-luminance" />
    </Section>
  );
}

// ------------------------------------------------------------- Channel Mixer
// SpektraLab 2's 通道 (ChannelMixer): each output channel takes some of each input, as an offset in
// percent from the channel itself; zero is the channel as it was.

export function ChannelMixerSection() {
  const mx = useSession((s) => s.sidecar.adjustments.channelMixer) ?? MIXER_DEFAULT;
  const [out, setOut] = useState<MixerChannel>('red');
  const label: Record<MixerChannel, string> = { red: tz('Red', '红'), green: tz('Green', '绿'), blue: tz('Blue', '蓝') };
  const setIn = (inp: MixerChannel, v: number) =>
    setAdjustments((q) => {
      const m = q.channelMixer ?? MIXER_DEFAULT;
      return { ...q, channelMixer: { ...m, [out]: { ...m[out], [inp]: v } } };
    });
  return (
    <Section id="channelMixer" title={tz('Channel Mixer', '通道混合器')} onReset={() => setAdjustments((q) => ({ ...q, channelMixer: MIXER_DEFAULT }))} resetEnabled={!mixerNeutral(mx)} resetHelp={t('helpReset')}>
      <SegmentedSwitch
        value={out}
        onChange={(v) => setOut(v)}
        options={MIXER_CHANNELS.map((c) => ({ value: c, label: label[c], marked: MIXER_CHANNELS.some((i) => mx[c][i] !== 0) }))}
      />
      <div className="caption">{tz(`How much of each colour goes into ${label[out].toLowerCase()}`, `每种颜色混入${label[out]}的量`)}</div>
      {MIXER_CHANNELS.map((inp) => (
        <ScrubSlider key={inp} label={label[inp]} value={mx[out][inp]} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setIn(inp, v)} testId={`mixer-${out}-${inp}`} />
      ))}
    </Section>
  );
}

// -------------------------------------------------------------------- Watermark
// Develop's text watermark (shared/watermark.ts): on the picture, inside any border, drawn the same way on
// the canvas and in every export.

const WM_POSITION_LABEL: Record<WatermarkPosition, string> = {
  tl: '↖', tc: '↑', tr: '↗', ml: '←', mc: '•', mr: '→', bl: '↙', bc: '↓', br: '↘',
};

export function WatermarkSection() {
  const wm = useSession((s) => s.sidecar.adjustments.watermark) ?? WATERMARK_DEFAULT;
  const setWm = (patch: Partial<Watermark>) =>
    setAdjustments((q) => ({ ...q, watermark: { ...(q.watermark ?? WATERMARK_DEFAULT), ...patch } }));
  return (
    <Section id="watermark" title={tz('Watermark', '水印')} onReset={() => setAdjustments((q) => ({ ...q, watermark: WATERMARK_DEFAULT }))} resetEnabled={wm.enabled || !!wm.text} resetHelp={t('helpReset')}>
      <ToggleRow label={tz('Watermark', '水印')} on={wm.enabled} onChange={(v) => setWm({ enabled: v })} testId="wm-on" />
      <div className="row" style={{ gap: 8 }}>
        <input
          className="unit-field"
          style={{ flex: 1, minWidth: 0 }}
          value={wm.text}
          placeholder={tz('© Your Name 2026', '© 你的名字 2026')}
          onChange={(e) => setWm({ text: e.target.value.slice(0, 200), enabled: true })}
          data-testid="wm-text"
        />
      </div>
      <PillMenu
        label={tz('Font', '字体')}
        value={wm.font}
        fill
        options={[
          { value: 'sans', label: tz('Sans', '无衬线') },
          { value: 'serif', label: tz('Serif', '衬线') },
          { value: 'mono', label: tz('Typewriter', '打字机') },
          { value: 'script', label: tz('Script', '手写') },
        ]}
        onChange={(v) => setWm({ font: v as Watermark['font'] })}
      />
      <ToggleRow label={tz('Bold', '粗体')} on={wm.bold} onChange={(v) => setWm({ bold: v })} />
      <ScrubSlider label={tz('Size', '大小')} value={wm.size} range={[1, 15]} zero={3} snap={0.5} format={(v) => v.toFixed(1)} onChange={(v) => setWm({ size: v })} />
      <ScrubSlider label={tz('Tone', '明暗')} sublabel={tz('0 black · 100 white', '0 黑 · 100 白')} value={wm.tone * 100} range={[0, 100]} zero={100} snap={5} format={(v) => v.toFixed(0)} onChange={(v) => setWm({ tone: v / 100 })} />
      <ScrubSlider label={tz('Opacity', '不透明度')} value={wm.opacity * 100} range={[0, 100]} zero={70} snap={5} format={(v) => `${v.toFixed(0)} %`} onChange={(v) => setWm({ opacity: v / 100 })} />
      <ScrubSlider label={tz('Margin', '边距')} value={wm.margin} range={[0, 15]} zero={3} snap={0.5} format={(v) => v.toFixed(1)} onChange={(v) => setWm({ margin: v })} />
      <div className="wm-grid" role="radiogroup" aria-label={tz('Position', '位置')}>
        {WATERMARK_POSITIONS.map((pos) => (
          <button key={pos} role="radio" aria-checked={wm.position === pos} className={'btn' + (wm.position === pos ? ' on' : '')} onClick={() => setWm({ position: pos })}>
            {WM_POSITION_LABEL[pos]}
          </button>
        ))}
      </div>
    </Section>
  );
}

export function ColorBalanceSection() {
  const cb = useSession((s) => s.sidecar.adjustments.colorBalance);
  const [zone, setZone] = useState<(typeof ZONES)[number]['key']>('master');
  const z = cb[zone];
  const setZ = (patch: Partial<ColorZone>) => setAdjustments((q) => ({ ...q, colorBalance: { ...q.colorBalance, [zone]: { ...q.colorBalance[zone], ...patch } } }));
  return (
    <Section
      id="colorbalance"
      title={t('sectionColorBalance')}
      onReset={() => setAdjustments((q) => ({ ...q, colorBalance: { master: zero, shadows: zero, midtones: zero, highlights: zero } }))}
      resetHelp={t('helpReset')}
    >
      <div className="row" style={{ gap: 4 }}>
        {ZONES.map((zz) => (
          <button key={zz.key} className={'btn' + (zz.key === zone ? ' primary' : '')} style={{ height: 18, padding: '0 8px', fontSize: 'var(--fs-small)' }} onClick={() => setZone(zz.key)}>
            {zz.label()}
          </button>
        ))}
      </div>
      <HueWheel zone={z} onChange={setZ} />
      <ScrubSlider label={tz('Hue', '色相')} value={z.hue} range={[0, 360]} snap={15} format={(v) => v.toFixed(0) + '°'} gradient="linear-gradient(90deg,#e8524e,#e8c04e,#62c462,#4ec0e8,#5d7de8,#d05bd0,#e8524e)" onChange={(v) => setZ({ hue: v })} />
      <ScrubSlider label={t('exposureSaturation')} value={z.saturation} range={[0, 1]} snap={0.05} onChange={(v) => setZ({ saturation: v })} />
      <ScrubSlider label={tz('Luminance', '亮度')} value={z.luminance} range={[-1, 1]} snap={0.05} format={signed(2)} onChange={(v) => setZ({ luminance: v })} />
    </Section>
  );
}
const zero: ColorZone = { hue: 0, saturation: 0, luminance: 0 };

/** A small hue/saturation disc: drag to set both (the Mac's ColorWheel, simplified). */
function HueWheel({ zone, onChange }: { zone: ColorZone; onChange: (z: Partial<ColorZone>) => void }) {
  const ref = useRef<SVGSVGElement>(null);
  const R = 46;
  const set = (e: React.PointerEvent) => {
    const r = ref.current!.getBoundingClientRect();
    const dx = e.clientX - (r.left + r.width / 2);
    const dy = e.clientY - (r.top + r.height / 2);
    const sat = Math.min(1, Math.hypot(dx, dy) / R);
    const hue = ((Math.atan2(-dy, dx) * 180) / Math.PI + 360) % 360;
    onChange({ hue, saturation: sat });
  };
  const a = (zone.hue * Math.PI) / 180;
  return (
    <div className="row" style={{ justifyContent: 'center' }}>
      <svg
        ref={ref}
        width={R * 2 + 6}
        height={R * 2 + 6}
        viewBox={`${-R - 3} ${-R - 3} ${R * 2 + 6} ${R * 2 + 6}`}
        onPointerDown={(e) => {
          (e.target as Element).setPointerCapture(e.pointerId);
          set(e);
        }}
        onPointerMove={(e) => e.buttons && set(e)}
        style={{ cursor: 'crosshair' }}
      >
        <defs>
          <radialGradient id="wheel-fade">
            <stop offset="0" stopColor="#2d2d2c" stopOpacity="1" />
            <stop offset="1" stopColor="#2d2d2c" stopOpacity="0" />
          </radialGradient>
        </defs>
        <circle r={R} fill="none" stroke="url(#hue)" />
        {Array.from({ length: 36 }, (_, i) => {
          const a0 = (i * 10 * Math.PI) / 180;
          const a1 = ((i + 1) * 10 * Math.PI) / 180;
          return <path key={i} d={`M0 0 L${R * Math.cos(a0)} ${-R * Math.sin(a0)} A${R} ${R} 0 0 0 ${R * Math.cos(a1)} ${-R * Math.sin(a1)} Z`} fill={`hsl(${i * 10 + 5} 55% 50%)`} />;
        })}
        <circle r={R} fill="url(#wheel-fade)" />
        <circle cx={zone.saturation * R * Math.cos(a)} cy={-zone.saturation * R * Math.sin(a)} r={4} fill="none" stroke="var(--knob)" strokeWidth={1.5} />
      </svg>
    </div>
  );
}
