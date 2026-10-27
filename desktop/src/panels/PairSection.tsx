import { Section, ScrubSlider, ToggleRow, PillMenu, signed } from '../controls/controls';
import { tz } from '../i18n';
import { baseName } from '../platform';
import { useSession, setPairSide,setPairFilm,updatePair,setPairExposure, updatePairHole, replacePairHole, retryPairSave } from '../state/session';
import { GEOMETRY_DEFAULT } from '@shared/geometry';
import { isRawPath, modeOf, shownDecode, withPreset, withTemperature, withTint, WB_MODES } from '@shared/whiteBalance';

/** A recipe owns its holes; source photographs and their sidecars stay intact. */
export function PairSection() {
  const p=useSession(s=>s.pairDocument), side=useSession(s=>s.pairSide);
  const layer=useSession(s=>s.pairLayer);
  const info=useSession(s=>s.pairInfo), busy=useSession(s=>s.pairUpdating), error=useSession(s=>s.pairSaveError);
  if(!p) return null;
  const hole=p[side], source=info?.sources[side==='left'?0:1];
  const shot=source?.metadata?.as_shot;
  const asShot=shot?{temperature:shot.temperature_k,tint:shot.tint}:null;
  const wb=hole?shownDecode(hole.decode,asShot):null;
  const crop=hole?.geometry.crop;
  const setPlacement=(v:Partial<NonNullable<typeof hole>['placement']>)=>updatePairHole(h=>({...h,placement:{...h.placement,...v}}));
  const cropValue=(key:'x'|'y'|'width'|'height',value:number)=>updatePairHole(h=>{
    const c={...h.geometry.crop,[key]:value};
    c.width=Math.min(c.width,1-c.x);c.height=Math.min(c.height,1-c.y);
    return {...h,geometry:{...h.geometry,crop:c}};
  });
  return <Section id="pair" title={tz('Half-frame Pair','半格配对')} trailing={busy?tz('Updating…','更新中…'):undefined}>
    <div className="row pair-layer-buttons" style={{gap:6}}>
      <button className={'btn'+(layer==='film'?' primary':'')} data-testid="pair-film" onClick={setPairFilm}>{tz('Film','胶片')}</button>
      {(['left','right'] as const).map(s=><button key={s} className={'btn'+(layer===s?' primary':'')} data-testid={'pair-'+s} onClick={()=>setPairSide(s)}>{s==='left'?tz('Left','左孔'):tz('Right','右孔')}</button>)}
      <button className="btn" onClick={()=>updatePair(q=>({...q,left:q.right,right:q.left}))}>{tz('Swap','交换')}</button>
    </div>
    <div className="caption" style={{overflowWrap:'anywhere'}} title={hole?.path}>{hole?baseName(hole.path):tz('Empty hole','空片门')}</div>
    <div className="row" style={{gap:6}}>
      <button className="btn" onClick={()=>void replacePairHole()}>{tz('Choose photo…','选择照片…')}</button>
      <button className="btn" disabled={!hole} onClick={()=>updatePair(q=>({...q,[side]:null}))}>{tz('Clear hole','清空片门')}</button>
    </div>
    {source?.decode_error&&<div className="unsupported-note">{source.decode_error}</div>}
    {info&&!info.can_export&&<div className="caption">{tz('Fill both holes with available photos before exporting.','两个片门都填入可用照片后才能导出。')}</div>}
    <ToggleRow label={tz('Turn the pair','旋转合片')} on={p.turned} onChange={v=>updatePair(q=>({...q,turned:v}))} />
    <ScrubSlider label={tz('Gap (mm)','间距（mm）')} value={p.onStrip?1:p.spacingMM} range={[.5,2]} zero={1} disabled={p.onStrip} reason={tz('Film strip fixes the gap at 1 mm.','胶片条的间距固定为 1 mm。')} onChange={v=>updatePair(q=>({...q,spacingMM:v}))}/>
    {hole&&<>
      <ToggleRow label={tz('Meter this hole','本孔自动测光')} on={hole.autoExposure} onChange={v=>updatePairHole(h=>({...h,autoExposure:v}))} testId="pair-auto-exposure"/>
      <PillMenu label={tz('Metering','测光方式')} value={hole.meterMethod??'balanced'} options={['balanced','center','protect_highlights','protect_shadows'].map(value=>({value,label:({balanced:tz('Balanced','均衡'),center:tz('Centre','中央'),protect_highlights:tz('Protect highlights','保护高光'),protect_shadows:tz('Protect shadows','保护阴影')} as Record<string,string>)[value]!}))} onChange={v=>updatePairHole(h=>({...h,meterMethod:v}))}/>
      <PillMenu label={tz('Exposure scope','曝光作用范围')} value={hole.exposureScope??'frame'} options={[{value:'frame',label:tz('Frame','本孔')},{value:'film',label:tz('+ Film','本孔 + 片基')}]} onChange={v=>updatePairHole(h=>({...h,exposureScope:v}),false)}/>
      <ScrubSlider label={tz('Hole exposure','本孔曝光')} value={hole.exposureEV} range={[-5,5]} format={signed(2)} snap={1/3} onChange={setPairExposure} testId="pair-exposure"/>
      {source?.present&&hole.autoExposure&&<div className="caption num">{tz('Metered','测光补偿')} {signed(2)(source.metered_ev)} EV</div>}
      <ScrubSlider label={tz('Fill','放大')} value={hole.placement.scale} range={[1,4]} zero={1} onChange={v=>setPlacement({scale:v})}/>
      <ScrubSlider label={tz('Horizontal','水平取景')} value={hole.placement.x} range={[-1,1]} onChange={v=>setPlacement({x:v})}/>
      <ScrubSlider label={tz('Vertical','垂直取景')} value={hole.placement.y} range={[-1,1]} onChange={v=>setPlacement({y:v})}/>
      <div className="row" style={{gap:6}}>
        <button className="btn" onClick={()=>setPlacement({quarterTurns:(hole.placement.quarterTurns+1)%4})}>{tz('Rotate hole 90°','本孔旋转 90°')}</button>
        <button className="btn" onClick={()=>updatePairHole(h=>({...h,geometry:GEOMETRY_DEFAULT,placement:{scale:1,x:0,y:0,quarterTurns:0}}))}>{tz('Reset framing','重置取景')}</button>
      </div>
      <ToggleRow label={tz('Flip horizontal','水平翻转')} on={hole.geometry.flipH} onChange={v=>updatePairHole(h=>({...h,geometry:{...h.geometry,flipH:v}}))}/>
      <ToggleRow label={tz('Flip vertical','垂直翻转')} on={hole.geometry.flipV} onChange={v=>updatePairHole(h=>({...h,geometry:{...h.geometry,flipV:v}}))}/>
      <ScrubSlider label={tz('Straighten','拉直')} value={hole.geometry.angle} range={[-45,45]} onChange={v=>updatePairHole(h=>({...h,geometry:{...h.geometry,angle:v}}))}/>
      {crop&&(['x','y','width','height'] as const).map(key=><ScrubSlider key={key} label={tz('Crop '+key,({x:'裁切 X',y:'裁切 Y',width:'裁切宽度',height:'裁切高度'})[key])} value={crop[key]} range={key==='width'?[.01,1-crop.x]:key==='height'?[.01,1-crop.y]:[0,.99]} onChange={v=>cropValue(key,v)}/>)}
      {isRawPath(hole.path)&&wb&&<>
        <PillMenu label={tz('RAW white balance','RAW 白平衡')} value={modeOf(hole.decode)} options={WB_MODES.filter(m=>m!=='Custom'||modeOf(hole.decode)==='Custom').map(value=>({value,label:value}))} onChange={v=>updatePairHole(h=>({...h,decode:withPreset(h.decode,asShot,v)}))}/>
        <ScrubSlider label={tz('Temperature','色温')} value={wb.temperature} range={[2000,20000]} zero={asShot?.temperature??5500} format={v=>v.toFixed(0)} onChange={v=>updatePairHole(h=>({...h,decode:withTemperature(h.decode,asShot,v)}))}/>
        <ScrubSlider label={tz('Tint','色调')} value={wb.tint} range={[-150,150]} onChange={v=>updatePairHole(h=>({...h,decode:withTint(h.decode,asShot,v)}))}/>
      </>}
    </>}
    <div className="caption">{layer==='film'?tz('Enlarger and Post-Dev edit the whole film. RAW/framing controls above refer to the last selected hole.','放大机与显影后调色当前编辑整条胶片；上方 RAW 和取景控件对应最后选中的片门。'):tz('Enlarger and Post-Dev edit the selected hole. The enlarger scope also controls the surrounding film.','放大机与显影后调色当前编辑所选片门；放大机作用范围可同时影响周围片基。')}</div>
    {error&&<div className="unsupported-note">{error}<button className="btn" onClick={retryPairSave}>{tz('Retry save','重试保存')}</button></div>}
  </Section>;
}
