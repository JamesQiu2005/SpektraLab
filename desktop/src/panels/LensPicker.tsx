// LensPicker.tsx — Pre-Dev › Camera › Lens Correction (Develop, Linux): the switch, the lens the photo
// was taken with (lensfun's database, or one of My Lenses), its focal length and f-number, and for a
// custom lens the four sliders it is set with by eye. Every change decodes the photo again.

import { useEffect, useState } from 'react';
import { NumberField, ScrubSlider, ToggleRow } from '../controls/controls';
import { tz } from '../i18n';
import { setDecode, useSession } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { host } from '../host/client';
import {
  type CustomLensNumbers,
  type LensEntry,
  type LensList,
  type LensPick,
  type MyLens,
  CUSTOM_LENS_DEFAULT,
  LENS_SLIDERS,
  lensFixes,
  pickOfMyLens,
  searchLenses,
} from '@shared/lens';

let cachedList: LensList | null = null;

function fixesText(e: { distortion?: boolean; tca?: boolean; vignetting?: boolean }): string {
  const words: Record<string, () => string> = {
    distortion: () => tz('distortion', '畸变'),
    'dark corners': () => tz('dark corners', '暗角'),
    'colour fringing': () => tz('colour fringing', '色散'),
  };
  return lensFixes(e).map((w) => words[w]?.() ?? w).join(', ');
}

export function LensCorrectionPart() {
  const decode = useSession((s) => s.sidecar.decode);
  const meta = useSession((s) => s.metadata);
  const status = useSession((s) => s.lensStatus);
  const methods = useSession((s) => s.hello?.methods);
  const myLenses = useSettings((s) => s.myLenses);
  const can = !!methods?.includes('lenses');
  const [list, setList] = useState<LensList | null>(cachedList);
  const [picking, setPicking] = useState(false);
  const [query, setQuery] = useState('');
  const [naming, setNaming] = useState<string | null>(null);

  useEffect(() => {
    if (!can || !decode.lensCorrection || list) return;
    let live = true;
    host()
      .lenses(meta?.make, meta?.model)
      .then((l) => {
        cachedList = l;
        if (live) setList(l);
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [can, decode.lensCorrection, list, meta?.make, meta?.model]);

  const available = can && (list === null || list.available);
  const pick = decode.lens;
  const setPick = (p: LensPick | null) => setDecode((d) => ({ ...d, lens: p }));
  const saveMyLenses = (next: MyLens[]) => settingsStore.getState().set('myLenses', next);

  // A custom lens's numbers: the photo's, and the saved lens of that name kept in step with it.
  const setNumbers = (patch: Partial<CustomLensNumbers>) => {
    if (!pick?.custom) return;
    const numbers = { ...pick.custom, ...patch };
    setPick({ ...pick, custom: numbers });
    if (myLenses.some((m) => m.name === pick.model))
      saveMyLenses(myLenses.map((m) => (m.name === pick.model ? { ...m, numbers } : m)));
  };
  const setFocalAperture = (patch: { focalMM?: number; aperture?: number }) => {
    const base: LensPick = pick ?? { maker: '', model: '', focalMM: 0, aperture: 0, custom: null };
    if (!pick) return;
    const next = { ...base, ...patch };
    setPick(next);
    if (next.custom && myLenses.some((m) => m.name === next.model))
      saveMyLenses(myLenses.map((m) => (m.name === next.model ? { ...m, focalMM: next.focalMM, aperture: next.aperture } : m)));
  };

  const chooseDb = (e: LensEntry) => {
    const prime = e.min_focal > 0 && e.min_focal === e.max_focal;
    setPick({ maker: e.maker, model: e.model, focalMM: prime ? e.min_focal : (pick?.focalMM ?? 0), aperture: pick?.aperture ?? 0, custom: null });
    setPicking(false);
    setQuery('');
  };
  const chooseMine = (m: MyLens) => {
    setPick(pickOfMyLens(m));
    setPicking(false);
    setQuery('');
  };
  const createMine = (name: string) => {
    const n = name.trim();
    if (!n) return;
    const existing = myLenses.find((m) => m.name === n);
    const lens: MyLens = existing ?? { name: n, focalMM: pick?.focalMM ?? 0, aperture: pick?.aperture ?? 0, numbers: { ...CUSTOM_LENS_DEFAULT } };
    if (!existing) saveMyLenses([...myLenses, lens]);
    chooseMine(lens);
    setNaming(null);
  };
  const removeMine = (name: string) => {
    saveMyLenses(myLenses.filter((m) => m.name !== name));
  };

  const q = query.trim().toLowerCase();
  const mine = myLenses.filter((m) => !q || m.name.toLowerCase().includes(q));
  const hits = list ? searchLenses(list.lenses, query) : [];
  const fileLens = meta?.lens?.trim();
  const shownName = pick
    ? pick.custom
      ? `${pick.model} · ${tz('My Lenses', '我的镜头')}`
      : pick.model
    : fileLens
      ? tz(`${fileLens} (from the photo)`, `${fileLens}（照片记录）`)
      : tz('Choose your lens…', '选择镜头…');
  const dbEntry = pick && !pick.custom && list ? list.lenses.find((e) => e.maker === pick.maker && e.model === pick.model) : undefined;
  const zoom = dbEntry ? dbEntry.min_focal !== dbEntry.max_focal : true;

  return (
    <>
      <ToggleRow
        label={tz('Lens Correction', '镜头校正')}
        sublabel={decode.lensCorrection ? undefined : tz('distortion, dark corners, colour fringing', '畸变、暗角、色散')}
        on={decode.lensCorrection && available}
        onChange={(v) => setDecode((d) => ({ ...d, lensCorrection: v }))}
        disabled={!available}
        reason={tz('This build has no lens database (lensfun).', '此版本没有镜头数据库（lensfun）。')}
        testId="lens-correction"
      />
      {decode.lensCorrection && available && (
        <div className="lens-part" data-testid="lens-part">
          <div className="row">
            <span className="row-label">{tz('Lens', '镜头')}</span>
            <button className="btn lens-choose" onClick={() => setPicking(!picking)} title={shownName} data-testid="lens-choose">
              {shownName}
            </button>
          </div>
          {picking && (
            <div className="lens-picker">
              <input
                className="unit-field lens-search"
                autoFocus
                placeholder={tz('Search: canon fd 50, helios, 135…', '搜索：canon fd 50、helios、135…')}
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                onKeyDown={(e) => e.key === 'Escape' && setPicking(false)}
                data-testid="lens-search"
              />
              <div className="lens-results">
                {mine.length > 0 && <div className="stock-group">{tz('My Lenses', '我的镜头')}</div>}
                {mine.map((m) => (
                  <div key={'mine:' + m.name} className="lens-row" onClick={() => chooseMine(m)}>
                    <span className="name">{m.name}</span>
                    <span className="sub">{m.focalMM > 0 ? `${m.focalMM} mm` : tz('custom', '自定义')}</span>
                  </div>
                ))}
                {q && <div className="stock-group">{tz('Lens database', '镜头数据库')}</div>}
                {hits.map((e) => (
                  <div key={e.maker + '\u0000' + e.model} className="lens-row" onClick={() => chooseDb(e)} title={e.mounts.join(', ')}>
                    <span className="name">{e.model.toLowerCase().startsWith(e.maker.toLowerCase()) ? e.model : `${e.maker} ${e.model}`}</span>
                    <span className="sub">{fixesText(e) || tz('no corrections', '无校正数据')}</span>
                  </div>
                ))}
                {q && hits.length === 0 && (
                  <div className="caption">{tz('Not in the database. Make it one of My Lenses below.', '数据库中没有。可在下方添加为我的镜头。')}</div>
                )}
                {!q && !mine.length && <div className="caption">{tz('Type to search about 1,000 lenses.', '输入以搜索约 1000 支镜头。')}</div>}
              </div>
              {naming === null ? (
                <button className="btn" onClick={() => setNaming(query.trim())} data-testid="lens-new">
                  {tz('New custom lens…', '新建自定义镜头…')}
                </button>
              ) : (
                <div className="row" style={{ gap: 6 }}>
                  <input
                    className="unit-field"
                    style={{ flex: 1 }}
                    autoFocus
                    placeholder={tz('Its name, e.g. Tokina RMC 500mm', '名称，例如 Tokina RMC 500mm')}
                    value={naming}
                    onChange={(e) => setNaming(e.target.value)}
                    onKeyDown={(e) => {
                      if (e.key === 'Enter') createMine(naming);
                      if (e.key === 'Escape') setNaming(null);
                    }}
                    data-testid="lens-new-name"
                  />
                  <button className="btn" disabled={!naming.trim()} onClick={() => createMine(naming)}>
                    {tz('Add', '添加')}
                  </button>
                </div>
              )}
            </div>
          )}
          {pick && (
            <>
              <div className="row" style={{ gap: 8 }}>
                <span className="row-label">{tz('Focal length', '焦距')}</span>
                <NumberField value={pick.focalMM} decimals={0} width={64} label="mm" disabled={!zoom && !pick.custom} onCommit={(v) => setFocalAperture({ focalMM: Math.max(0, Math.min(5000, v)) })} />
                <span className="caption">mm</span>
              </div>
              <div className="row" style={{ gap: 8 }} title={tz('The f-number the photo was taken at: dark corners depend on it. 0 leaves them.', '拍摄光圈：暗角与之相关。0 表示不校正暗角。')}>
                <span className="row-label">{tz('Aperture', '光圈')}</span>
                <span className="caption">f/</span>
                <NumberField value={pick.aperture} decimals={1} width={64} label="f-number" onCommit={(v) => setFocalAperture({ aperture: Math.max(0, Math.min(128, v)) })} />
              </div>
            </>
          )}
          {pick?.custom && (
            <>
              <ScrubSlider
                label={tz('Distortion', '畸变')}
                sublabel={tz('− barrel · + pincushion: until lines are straight', '− 桶形 · + 枕形：调到直线变直')}
                value={LENS_SLIDERS.distortion.fromNumber(pick.custom.distortion)}
                range={LENS_SLIDERS.distortion.range}
                zero={0}
                snap={1}
                format={(v) => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(0)}
                onChange={(v) => setNumbers({ distortion: LENS_SLIDERS.distortion.toNumber(v) })}
                testId="lens-custom-distortion"
              />
              <ScrubSlider
                label={tz('Dark Corners', '暗角')}
                sublabel={tz('how dark the lens makes them', '镜头造成的暗角程度')}
                value={LENS_SLIDERS.corners.fromNumber(pick.custom.vignetting)}
                range={LENS_SLIDERS.corners.range}
                zero={0}
                snap={1}
                format={(v) => v.toFixed(0)}
                onChange={(v) => setNumbers({ vignetting: LENS_SLIDERS.corners.toNumber(v) })}
                testId="lens-custom-corners"
              />
              <ScrubSlider
                label={tz('Red Fringe', '红色色散')}
                value={LENS_SLIDERS.fringe.fromNumber(pick.custom.tcaR)}
                range={LENS_SLIDERS.fringe.range}
                zero={0}
                snap={1}
                format={(v) => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(0)}
                onChange={(v) => setNumbers({ tcaR: LENS_SLIDERS.fringe.toNumber(v) })}
                testId="lens-custom-red"
              />
              <ScrubSlider
                label={tz('Blue Fringe', '蓝色色散')}
                value={LENS_SLIDERS.fringe.fromNumber(pick.custom.tcaB)}
                range={LENS_SLIDERS.fringe.range}
                zero={0}
                snap={1}
                format={(v) => (v > 0 ? '+' : v < 0 ? '−' : '') + Math.abs(v).toFixed(0)}
                onChange={(v) => setNumbers({ tcaB: LENS_SLIDERS.fringe.toNumber(v) })}
                testId="lens-custom-blue"
              />
              {myLenses.some((m) => m.name === pick.model) && (
                <div className="row" style={{ gap: 8 }}>
                  <span className="caption">{tz('Changes are saved to this lens in My Lenses.', '改动会保存到“我的镜头”中的这支镜头。')}</span>
                  <button className="btn" onClick={() => removeMine(pick.model)} title={tz('Remove it from My Lenses; this photo keeps its numbers.', '从“我的镜头”移除；本照片保留其数值。')}>
                    {tz('Remove', '移除')}
                  </button>
                </div>
              )}
            </>
          )}
          {status && (
            <div className="caption" data-testid="lens-status">
              {status.applied
                ? tz(`Corrected: ${fixesText(status) || 'nothing to correct at this setting'}`, `已校正：${fixesText(status) || '此设置下无需校正'}`)
                : status.error}
            </div>
          )}
          {pick && !pick.custom && (
            <div className="caption">
              <button className="btn" onClick={() => setPick(null)}>
                {tz('Use the photo’s own lens', '使用照片记录的镜头')}
              </button>
            </div>
          )}
        </div>
      )}
    </>
  );
}

