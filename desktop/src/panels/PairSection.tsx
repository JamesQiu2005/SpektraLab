import { useState } from 'react';
import { PillMenu, ScrubSlider, Section } from '../controls/controls';
import { isPairPath, pairSpacing, PLACEMENT_DEFAULT, type PairLayer, type PairSide } from '@shared/pair';
import { tz } from '../i18n';
import { baseName } from '../platform';
import { click, removePair, setPairHole, setPairLayer, setPairPlacement, swapPairHoles, togglePairPlacing, updatePair, useSession } from '../state/session';

export function PairSection() {
  const pair = useSession((s) => s.pair), layer = useSession((s) => s.pairLayer), info = useSession((s) => s.pairInfo);
  const placing = useSession((s) => s.pairPlacing), frames = useSession((s) => s.frames), batch = useSession((s) => s.batchExporting);
  const [picking, setPicking] = useState<PairSide | null>(null), [filter, setFilter] = useState('');
  if (!pair) return null;
  const side = layer === 'film' ? null : layer, hole = side ? pair[side] : null;
  const title = (l: PairLayer) => l === 'film' ? tz('Film', '胶片') : l === 'left'
    ? pair.turned ? tz('Top frame', '上格') : tz('Left frame', '左格')
    : pair.turned ? tz('Bottom frame', '下格') : tz('Right frame', '右格');
  return <Section id="pair" title={tz('Photo Pair · Half Frame', '双图拼接 · 半格')} menu={[{ label: tz('Remove this pair', '移除此拼接'), onSelect: () => void removePair(), disabled: batch }]}>
    <p className="caption">{tz('Two photos share one film frame. Add or replace either photo below; source files stay unchanged.', '将两张照片拼在同一胶片画面中。可分别添加或替换；原始文件不会修改。')}</p>
    {(['film', 'left', 'right'] as PairLayer[]).map((l) => <button key={l} className={'row pair-layer' + (l === layer ? ' selected' : '')}
      aria-pressed={l === layer} disabled={batch} onClick={() => setPairLayer(l)} data-testid={`pair-layer-${l}`}>
      <span>{title(l)}</span><span className="caption">{l === 'film' ? `${pairSpacing(pair).toFixed(1)} mm` : pair[l]
        ? (info?.[l]?.available === false ? tz('Missing: ', '无法读取：') : '') + baseName(pair[l]!.path) : tz('Empty', '空')}</span>
    </button>)}
    {layer === 'film' ? <>
      <PillMenu label={tz('Camera', '相机')} value={pair.turned ? 'turned' : 'level'} disabled={batch}
        options={[{ value: 'level', label: tz('Level', '横持') }, { value: 'turned', label: tz('Turned', '竖持') }]}
        onChange={(v) => updatePair((p) => ({ ...p, turned: v === 'turned' }), { step: true })} />
      <ScrubSlider label={tz('Spacing', '间距')} sublabel="mm" value={pairSpacing(pair)} range={[.5, 2]} zero={1} snap={.1}
        disabled={pair.onStrip || batch} reason={tz('With Film Edge, the camera advance sets the gap.', '开启片边后，间距由相机过片决定。')}
        onChange={(v) => updatePair((p) => ({ ...p, spacingMM: v }), { defer: true })} />
      <button className="pill-menu" disabled={batch || (!pair.left && !pair.right)} onClick={swapPairHoles}>{tz('Swap the two frames', '两格对调')}</button>
      <p className="caption">{tz('Click a frame on the canvas to edit it; drag a photograph from the strip to replace it.', '点击画布上的一格可编辑；从胶片条拖入照片可替换。')}</p>
    </> : hole && side ? <>
      <div className="row"><button className="pill-menu" disabled={batch || info?.[side]?.available === false} onClick={togglePairPlacing}>{placing ? tz('Done', '完成') : tz('Crop on the canvas', '在画布上裁剪')}</button>
        <button className="pill-menu" disabled={batch} onClick={() => setPairPlacement(side, (p) => ({ ...p, quarterTurns: (p.quarterTurns + 1) % 4 }), false)}>{tz('Turn', '旋转')}</button></div>
      <ScrubSlider label={tz('Scale', '缩放')} sublabel="×" value={hole.placement.scale} range={[1, 4]} zero={1} snap={.05} disabled={batch} onChange={(v) => setPairPlacement(side, (p) => ({ ...p, scale: v }))} />
      <ScrubSlider label={tz('Across', '横向')} value={hole.placement.x} range={[-1, 1]} snap={.05} disabled={batch} onChange={(v) => setPairPlacement(side, (p) => ({ ...p, x: v }))} />
      <ScrubSlider label={tz('Up / down', '纵向')} value={hole.placement.y} range={[-1, 1]} snap={.05} disabled={batch} onChange={(v) => setPairPlacement(side, (p) => ({ ...p, y: v }))} />
      <div className="row"><button className="pill-menu" disabled={batch} onClick={() => setPicking(side)}>{tz('Replace…', '替换…')}</button>
        <button className="pill-menu" disabled={batch} onClick={() => void setPairHole(side, null)}>{tz('Remove', '移除')}</button>
        <button className="pill-menu" disabled={batch} onClick={() => setPairPlacement(side, () => ({ ...PLACEMENT_DEFAULT }), false)}>{tz('Reset crop', '重置裁剪')}</button></div>
      <button className="pill-menu" disabled={batch || info?.[side]?.available === false} onClick={() => click(hole.path)}>{tz('Open frame alone', '单独打开照片')}</button>
      <p className="caption">{info?.[side]?.error ?? tz('Its exposure and white balance are in Input / Camera; its print is in Enlarger.', '这一格的曝光与白平衡在“输入 / 相机”中；印放在“放大机”中。')}</p>
    </> : side ? <>
      <button className="pill-menu" disabled={batch} onClick={() => setPicking(side)}>{tz('Add frame…', '添加照片…')}</button>
      <p className="caption">{tz('An empty hole is unexposed film. Fill both to export.', '空格是未曝光胶片。两格均有照片才可导出。')}</p>
    </> : null}
    {picking && <div className="pair-picker" role="dialog" aria-label={tz('Choose a frame', '选择照片')}>
      <div className="row"><input value={filter} onChange={(e) => setFilter(e.target.value)} placeholder={tz('Filter by name', '按文件名筛选')} /><button className="pill-menu" onClick={() => setPicking(null)}>{tz('Cancel', '取消')}</button></div>
      {frames.filter((f) => !isPairPath(f.path) && f.name.toLocaleLowerCase().includes(filter.toLocaleLowerCase())).map((f) => <button key={f.path} className="row" onClick={() => { void setPairHole(picking, f.path); setPicking(null); }}>
        {f.name}{pair.left?.path === f.path || pair.right?.path === f.path ? ` · ${tz('In this pair', '已在此拼接中')}` : ''}
      </button>)}
    </div>}
  </Section>;
}
