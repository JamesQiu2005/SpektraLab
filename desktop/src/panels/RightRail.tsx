// RightRail.tsx — "Parameters" (`Panels/RightPanel.swift`):
//   Pre-Dev:  Latitude · Input / Camera · Film Format · Scene Placement
//   Post-Dev: White Balance · Exposure · Curve · Color Balance (Layer 2)

import { useRef, useState } from 'react';
import { Checkbox, NumberField, PillMenu, ScrubSlider, Section, SegmentedSwitch, ToggleRow, signed } from '../controls/controls';
import { isChinese, t, tz } from '../i18n';
import { cameraParams, pairFocus, setCamera, shownAdjustments, shownDecode as selectedDecode, updatePair, canPickNeutral, currentPlacementWindow, hostRedecodes, placeScene, placementReady, resetScenePlacement, setAdjustments, setDecode, setFilmFrame, setFilmSide, setParams, setSideLengthMM, startNeutralPick, useSession } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import {
  type AEMethod,
  EFFECTS_DEFAULT,
  EFFECT_RANGES,
  FILM_FRAMES,
  FILM_FRAME_CUSTOM,
  SIDE_UNIT_DECIMALS,
  SIDE_UNIT_PER_MM,
  type SideUnit,
  aeMethodOf,
  applyAEMethod,
} from '@shared/params';
import { type ColorZone, type CurveChannel, CURVE_CHANNELS, isNeutral } from '@shared/adjustments';
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
import { unsupportedReason } from './gate';
import { type LatitudeReply, type PlacementSide, placementMessage } from '@shared/latitude';

export function RightRail() {
  const tab = useSettings((s) => s.parametersTab);
  const edited = useSession((s) => shownAdjustments(s).enabled && !isNeutral(shownAdjustments(s)));
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
            <ScenePlacementSection />
          </>
        ) : (
          <>
            <WhiteBalanceSection />
            <ExposureSection />
            <CurveSection />
            <ColorBalanceSection />
          </>
        )}
      </div>
    </aside>
  );
}

// ------------------------------------------------------------------ Latitude

function LatitudeSection() {
  const film = useSession((s) => s.sidecar.params.filmStock);
  const paper = useSession((s) => s.sidecar.params.printStock);
  const catalog = useSession((s) => s.catalog);
  const { reply, failure } = useSession((s) => s.latitude);
  const name = (id: string) => catalog.stock(id)?.name.replace(/^(Kodak|Fujifilm) (Professional )?/, '') ?? id;
  return (
    <Section id="latitude" title={t('sectionLatitude')} trailing={`${name(film)} · ${name(paper)}`} unsupported={failure}>
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

function CameraSection() {
  const tool = useSession((s) => s.tool);
  const pickerReady = useSession(() => canPickNeutral());
  const state = useSession((s) => s);
  const p = cameraParams(state), focus = pairFocus(state), hole = focus ? state.pair?.[focus] : null;
  const vignette = useSession((s) => shownAdjustments(s).vignette.amount);
  const ae = aeMethodOf(p);
  const lens = (focus ? state.pairInfo?.[focus]?.metadata : state.metadata)?.lens_correction;
  const lensReady = lens?.available === true && !!state.hello?.methods?.includes(state.pair ? 'update_pair' : 'redecode') && !state.batchExporting;
  const lensReason = lens?.reason || tz('No matching lens profile is available for this photograph.', '此照片没有匹配的镜头配置文件。');
  const lensParts = lens ? [lens.distortion && tz('distortion', '畸变'), lens.tca && tz('colour fringing', '横向色差'), lens.vignetting && tz('vignetting', '暗角')].filter(Boolean).join(' · ') : '';
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
      onReset={() => setCamera((q) => ({ ...q, exposureCompensationEV: 0 }))}
      resetHelp={t('helpResetFilmExposure')}
      menu={[
        { label: t('helpResetFilmExposure'), onSelect: () => setCamera((q) => ({ ...q, exposureCompensationEV: 0 })) },
        // The presets keep their English names, as on the Mac.
        ...WB_MODES.filter((m) => m !== 'Custom').map((m) => ({
          label: `${t('helpWhiteBalancePreset')}: ${m}`,
          checked: wb.mode === m,
          disabled: !!wb.reason,
          onSelect: () => setDecode((d) => withPreset(d, wb.asShot, m)),
        })),
      ]}
    >
      <PillMenu label={t('cameraMetering')} value={ae} options={options} fill onChange={(v) => setCamera((q) => applyAEMethod(q, v))} testId="metering" />
      {hole && focus && <PillMenu label={tz('Exposure scope', '曝光范围')} value={hole.exposureScope}
        options={[{ value: 'frame', label: tz('Frame', '这一格') }, { value: 'film', label: tz('+ Film', '+ 胶片') }]}
        onChange={(v) => updatePair((p) => ({ ...p, [focus]: { ...p[focus]!, exposureScope: v } }))} />}
      <ScrubSlider
        label={t('cameraFilmExposure')}
        sublabel={
          <span style={{ display: 'inline-flex', gap: 4, alignItems: 'center' }}>
            {t('cameraFilmExposureAsShot')}
            <Checkbox on={asShot} label={t('cameraFilmExposureAsShot')} onChange={() => setCamera((q) => ({ ...applyAEMethod(q, 'custom'), exposureCompensationEV: 0 }))} />
          </span>
        }
        value={p.exposureCompensationEV}
        range={hole ? [-5, 5] : [-3, 3]}
        snap={1 / 3}
        format={signed(1)}
        onChange={(v) => setCamera((q) => ({ ...q, exposureCompensationEV: v }))}
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
      <button className="pill" disabled={!pickerReady} onClick={startNeutralPick} aria-pressed={tool === 'neutral'} data-testid="pick-neutral">
        {tool === 'neutral' ? tz('Cancel neutral picker', '取消中性灰取样') : tz('Pick neutral white balance', '吸取中性灰白平衡')}
      </button>
      <ScrubSlider label={t('cameraVignetting')} value={vignette} range={[-100, 100]} snap={5} format={signed(0)} onChange={(v) => setAdjustments((a) => ({ ...a, vignette: { ...a.vignette, amount: v } }))} />
      <ToggleRow label={t('cameraLensCorrection')} on={selectedDecode(state).lensCorrection} onChange={(v) => setDecode((d) => ({ ...d, lensCorrection: v }))} disabled={!lensReady} reason={!lensReady ? lensReason : undefined} testId="lens-correction" />
      <p className="caption" data-testid="lens-profile">{lensReady ? `${lens?.profile ?? ''}${lensParts ? ` · ${lensParts}` : ''}` : lensReason}</p>
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
  const decode = useSession(selectedDecode);
  const shot = useSession((s) => { const side = pairFocus(s); return side ? s.pairInfo?.[side]?.metadata?.as_shot : s.metadata?.as_shot; });
  const selection = useSession((s) => s.selection);
  const kind = useSession((s) => { const side = pairFocus(s); return side ? s.pairInfo?.[side]?.kind : s.frameKind; });
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

function FilmFormatSection() {
  const p = useSession((s) => s.sidecar.params);
  const monochrome = useSession((s) => s.catalog.isMonochrome(s.sidecar.params.filmStock));
  const unit = useSettings((s) => s.sideUnit);
  const decouple = useSettings((s) => s.decoupleEffects);
  const isCustom = p.filmFrame === FILM_FRAME_CUSTOM.id;
  const e = p.effects;
  const setE = (patch: Partial<typeof e>) => setParams((q) => ({ ...q, effects: { ...q.effects, ...patch } }));
  const strength = (label: string, key: 'grain' | 'halation' | 'scatter' | 'couplers' | 'glare', enabled: boolean) => (
    <ScrubSlider label={label} value={e[key]} range={[...EFFECT_RANGES[key]] as [number, number]} zero={1} snap={0.25} format={(v) => v.toFixed(2)} disabled={!enabled} reason={t('reasonEffectOff')} onChange={(v) => setE({ [key]: v })} />
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
        { label: monochrome ? tz('Single-layer grain (black-and-white film)', '单层颗粒（黑白胶片）') : t('helpSubLayerGrain'),
          checked: monochrome || e.grainLayered, disabled: !p.grainActive || monochrome, onSelect: () => setE({ grainLayered: !e.grainLayered }) },
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
      {decouple && strength(t('filmGrainStrength'), 'grain', p.grainActive)}
      <ToggleRow label={t('filmHalation')} on={p.halationActive} onChange={(v) => setParams((q) => ({ ...q, halationActive: v }))} />
      <ToggleRow label={t('filmAntihalationLayer')} on={!e.antihalationRemoved} disabled={!p.halationActive} reason={t('reasonEffectOff')} onChange={(v) => setE({ antihalationRemoved: !v })} />
      {decouple && (
        <>
          {strength(t('filmHalationStrength'), 'halation', p.halationActive)}
          {strength(t('filmScatterStrength'), 'scatter', p.halationActive)}
          <ScrubSlider label={t('filmHighlightBoost')} value={e.highlightBoost} range={[0, 8]} snap={0.5} format={(v) => v.toFixed(1)} disabled={!p.halationActive} onChange={(v) => setE({ highlightBoost: v })} />
          <ToggleRow label={t('filmCouplers')} on={e.couplersActive} onChange={(v) => setE({ couplersActive: v })} />
          {strength(t('filmCouplersStrength'), 'couplers', e.couplersActive)}
        </>
      )}
      <ToggleRow label={t('filmGlare')} on={p.glareActive} disabled={!p.printEffects} reason={t('reasonPrintEffectsOff')} onChange={(v) => setParams((q) => ({ ...q, glareActive: v }))} />
      {decouple && strength(t('filmGlareStrength'), 'glare', p.glareActive && p.printEffects)}
    </Section>
  );
}

// ----------------------------------------------------------- Scene Placement

function ScenePlacementSection() {
  const s = useSession((s) => s);
  const sl = s.sidecar.params.sceneLatitude, l = s.latitude;
  const unsupported = unsupportedReason('scene_latitude_mapping', s.gate.sceneLatitude);
  const ready = placementReady();
  const reason = unsupported ?? (s.sidecar.params.digitalIntermediate && !s.sidecar.params.scanFilm
    ? tz('Scene placement is unavailable in Digital Intermediate mode.', '数字中间片模式不使用场景置位。')
    : ready ? null : l.failure ?? tz('Waiting for the scene latitude measurement…', '正在等待场景宽容度测量…'));
  const row = (side: PlacementSide) => {
    const window = currentPlacementWindow(side);
    const why = placementMessage(l.refusal ?? (window?.span === null ? window.below : null), side, l.reply, isChinese());
    return <div key={side}>
      <ScrubSlider label={side === 'highlight' ? t('placementHighlight') : t('placementShadow')}
        value={side === 'highlight' ? sl.highlightPullBack : sl.shadowPullBack} range={[0, 8]} snap={0.25}
        format={(v) => v.toFixed(2)} onChange={(v) => placeScene(side, v)} disabled={!ready}
        reason={reason ?? undefined} usable={window?.span ? [window.span] : []} testId={`placement-${side}`} />
      {why && <div className="caption" data-testid={`placement-${side}-reason`}>{why}</div>}
    </div>;
  };
  return (
    <Section id="scenePlacement" title={t('sectionScenePlacement')} unsupported={unsupported} onReset={resetScenePlacement} resetHelp={t('helpResetPlacement')} resetEnabled={s.gate.sceneLatitude && (sl.active || sl.highlightPullBack > 0 || sl.shadowPullBack > 0)}>
      {reason && !unsupported && <p className="caption">{reason}</p>}
      {row('highlight')}{row('shadow')}
    </Section>
  );
}

// ---------------------------------------------------------------- Post-Dev

function WhiteBalanceSection() {
  const a = useSession(shownAdjustments);
  return (
    <Section id="wb2" title={t('sectionWhiteBalance')} trailing={t('statusRightRailWBScope')} onReset={() => setAdjustments((q) => ({ ...q, temperature: 0, tint: 0 }))} resetHelp={t('helpReset')}>
      <ScrubSlider label={t('cameraTemperature')} value={a.temperature} range={[-100, 100]} snap={5} format={signed(0)} gradient="linear-gradient(90deg,#5d7de8,#bbb,#e8c04e)" onChange={(v) => setAdjustments((q) => ({ ...q, temperature: v }))} />
      <ScrubSlider label={t('cameraTint')} value={a.tint} range={[-100, 100]} snap={5} format={signed(0)} gradient="linear-gradient(90deg,#62c462,#bbb,#d05bd0)" onChange={(v) => setAdjustments((q) => ({ ...q, tint: v }))} />
    </Section>
  );
}

function ExposureSection() {
  const a = useSession(shownAdjustments);
  const row = (label: string, key: 'exposure' | 'contrast' | 'brightness' | 'saturation' | 'highlights' | 'shadows' | 'blackPoint' | 'whitePoint', range: [number, number], digits: number, snap: number) => (
    <ScrubSlider key={key} label={label} value={a[key]} range={range} snap={snap} format={signed(digits)} onChange={(v) => setAdjustments((q) => ({ ...q, [key]: v }))} testId={'adj-' + key} />
  );
  return (
    <Section
      id="exposure2"
      title={t('sectionExposure')}
      onReset={() => setAdjustments((q) => ({ ...q, exposure: 0, contrast: 0, brightness: 0, saturation: 0, highlights: 0, shadows: 0, blackPoint: 0, whitePoint: 0 }))}
      resetHelp={t('helpReset')}
    >
      {row(t('clipExposure'), 'exposure', [-3, 3], 2, 1 / 3)}
      {row(t('exposureContrast'), 'contrast', [-50, 50], 0, 5)}
      {row(t('exposureBrightness'), 'brightness', [-50, 50], 0, 5)}
      {row(t('exposureSaturation'), 'saturation', [-100, 100], 0, 5)}
      {row(t('exposureHighlights'), 'highlights', [-100, 100], 0, 5)}
      {row(t('exposureShadows'), 'shadows', [-100, 100], 0, 5)}
      {row(t('exposureBlackPoint'), 'blackPoint', [0, 50], 0, 1)}
      {row(t('exposureWhitePoint'), 'whitePoint', [0, 50], 0, 1)}
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

function CurveSection() {
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

function ColorBalanceSection() {
  const cb = useSession((s) => shownAdjustments(s).colorBalance);
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
