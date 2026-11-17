// EditWorkspace.tsx — the picture column of the Edit workspace (README §5,
// §7; PC-E1–E13, PC-X1–X3): the toolbar over the picture, the picture on
// black, the filmstrip under it, and what is over the picture — the failed
// develop's InfoBar (PC-E12), the engine card (PC-E13), the embedded-preview
// capsule (PC-E8), ··· (PC-X1), Copy Settings (PC-X2) and the right-click
// command bar flyout (PC-X3).

import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { tz } from '../i18n';
import { Canvas } from '../canvas/Canvas';
import { Filmstrip } from '../windows/Filmstrip';
import { ChevronLeft, ChevronRight, Crop, BeforeAfter, Ellipsis, Export, SidebarLeft, SidebarRight } from '../controls/icons';
import {
  copySettings, requestPrint, sessionStore, setOriginal, setPages, setTool, toggleCompare, useSession, zoomTo, zoomToFit, selectRelative,
  resetCrop,
} from '../state/session';
import { baseName } from '../platform';
import { FILM_PARAMS_DEFAULT } from '@shared/params';
import { CLIPBOARD_GROUPS, type ClipboardGroup } from '@shared/clipboard';
import { commands, showInExplorer, toggleRailCommand } from '../app/commands';
import { MenuList } from '../app/TitleBar';
import { setUi, useUi } from '../app/ui';
import type { Layout } from '../app/layout';
import { editedParts, fitParts, statusParts, SEP } from './words';
import { restartHost } from '../windows/actions';
import { host } from '../host/client';
import { ExportingFlyout, useExportRun } from '../export/ExportDialog';

let measureCtx: CanvasRenderingContext2D | null = null;
const measure = (s: string) => {
  measureCtx ??= document.createElement('canvas').getContext('2d');
  if (!measureCtx) return s.length * 7;
  measureCtx.font = `12px ${getComputedStyle(document.documentElement).getPropertyValue('--font-ui') || 'sans-serif'}`;
  return measureCtx.measureText(s).width;
};

/** The status line (README §7): the scheduler's state, in V5's words, fitted without "…". */
export function useStatusLine(room: number): { text: string; tone: 'normal' | 'danger'; parts: string[] } {
  const s = useSession((x) => x);
  const run = useExportRun();
  const [now, setNow] = useState(0);
  const job = s.job && s.job.job.frameId === (s.selection ?? s.engineSession) ? s.job : null;
  const running = job?.state.state === 'running';
  useEffect(() => {
    if (!running) return;
    const id = setInterval(() => setNow(performance.now()), 100);
    return () => clearInterval(id);
  }, [running]);
  const engine = s.hostState.phase === 'failed' ? 'stopped' : s.hostState.phase === 'ready' ? 'ready' : 'starting';
  const { parts, tone } = statusParts({
    engine, hasFrame: !!s.selection, frameName: s.selection ? baseName(s.selection) : '', catalog: s.catalog, params: s.sidecar.params,
    noFilm: s.sidecar.noFilm, edited: editedParts(s.sidecar.adjustments, s.sidecar.params, FILM_PARAMS_DEFAULT), job,
    elapsedMs: running && job?.startedAt !== undefined ? Math.max(0, (now || performance.now()) - job.startedAt) : 0,
    printed: s.badge !== null, crop: null, notice: null,
    exporting: s.batchExporting && run.progress ? { done: run.progress.done, total: run.progress.total, format: run.format, colour: run.colour, file: run.file ?? '' } : null,
  });
  return { text: fitParts(parts, room, measure), tone, parts };
}

function Glyph({ children, label, keys, onClick, on, disabled, testId }: { children: React.ReactNode; label: string; keys?: string; onClick: () => void; on?: boolean; disabled?: boolean; testId?: string }) {
  return (
    <button className={'v2-glyph' + (on ? ' on' : '')} title={keys ? `${label} (${keys})` : label} aria-label={label} aria-pressed={on} disabled={disabled} onClick={onClick} data-testid={testId}>
      {children}
    </button>
  );
}

function OriginalButton() {
  const showing = useSession((s) => s.showingOriginal);
  const latched = useUi((s) => s.originalLatched);
  const has = useSession((s) => !!s.selection);
  const down = useRef(0);
  return (
    <button className={'v2-pill' + (showing ? ' on' : '')} disabled={!has} data-testid="tb-original" title={tz('Original (hold Space or \\)', '原图（按住空格或 \\）')}
      onPointerDown={() => { down.current = performance.now(); setOriginal(true); }}
      onPointerUp={() => {
        // A short click latches it; a press and hold shows it until release.
        const short = performance.now() - down.current < 250;
        const latch = short ? !latched : false;
        setUi({ originalLatched: latch });
        setOriginal(latch);
      }}>
      {tz('Original', '原图')}
    </button>
  );
}

export function Toolbar({ layout }: { layout: Layout }) {
  const s = useSession((x) => x);
  const left = layout.left, right = layout.right;
  const more = useUi((u) => u.moreOpen);
  const exportFlyout = useUi((u) => u.exportFlyout);
  const run = useExportRun();
  const index = s.frames.findIndex((f) => f.path === s.selection);
  const title = s.selection ? `${baseName(s.selection).replace(/\.[^.]+$/, '')}${SEP}${tz(`${index + 1} of ${s.frames.length}`, `${index + 1} / ${s.frames.length}`)}` : '';
  const statusRoom = Math.max(80, layout.picture.width - (layout.overflow.zoomCropOriginal ? 250 : 540));
  const status = useStatusLine(statusRoom);
  const printed = s.badge !== null;
  const k = commands();
  const pct = s.view.fit ? tz('Fit', '适合') : `${Math.round(s.view.zoom * 100)} %`;
  const [zoomMenu, setZoomMenu] = useState(false);
  const busy = s.job && (s.job.state.state === 'running' || s.job.state.state === 'waiting' || s.job.state.state === 'queued');
  const overflowItems = [
    ...(layout.overflow.navCompareTitle ? [k.prevFrame!, k.nextFrame!, k.compare!, k.pasteSettings!, { separator: true } as const] : []),
    ...(layout.overflow.zoomCropOriginal ? [k.zoomFit!, k.zoom100!, k.crop!, { separator: true } as const] : []),
    k.copySettings!, k.copySettingsDialog!, { separator: true } as const, k.settings!,
  ];
  return (
    <div className="v2-toolbar" data-testid="toolbar" role="toolbar" aria-label={tz('Toolbar', '工具栏')}>
      <div className="v2-tb-lead">
        <Glyph label={tz('Develop Rail', '冲洗栏')} keys="F7" on={left === 'docked' || left === 'over'} onClick={() => toggleRailCommand('left')} testId="tb-left-rail"><SidebarLeft /></Glyph>
        {!layout.overflow.navCompareTitle && <>
          <Glyph label={tz('Previous Frame', '上一张')} keys="←" disabled={s.frames.length < 2} onClick={() => selectRelative(-1)} testId="tb-prev"><ChevronLeft /></Glyph>
          <Glyph label={tz('Next Frame', '下一张')} keys="→" disabled={s.frames.length < 2} onClick={() => selectRelative(1)} testId="tb-next"><ChevronRight /></Glyph>
        </>}
        <div className="v2-tb-title">
          <div className="v2-frame-title" data-testid="frame-title">{title}</div>
          <div className={'v2-status' + (status.tone === 'danger' ? ' danger' : '')} data-testid="status-line" role="status" aria-live="polite">
            {busy && <i className="v2-busy-dot" />}{status.text}
          </div>
        </div>
      </div>
      <div className="v2-tb-mid">
        {!layout.overflow.zoomCropOriginal && <>
          <div className="v2-zoom">
            <button className="v2-pill" data-testid="tb-zoom" disabled={!s.selection} onClick={() => setZoomMenu(!zoomMenu)}>{pct} ▾</button>
            {zoomMenu && <div className="v2-menu-drop" onPointerLeave={() => setZoomMenu(false)}>
              <MenuList onDone={() => setZoomMenu(false)} items={[
                { id: 'zfit', label: tz('Fit', '适合'), run: zoomToFit, enabled: true, checked: s.view.fit },
                ...[0.5, 1, 2, 4].map((z) => ({ id: `z${z}`, label: `${z * 100} %`, run: () => zoomTo(z), enabled: true, checked: !s.view.fit && Math.abs(s.view.zoom - z) < 1e-3 })),
              ]} />
            </div>}
          </div>
          <Glyph label={tz('Crop', '裁剪')} keys="C" on={s.tool === 'crop'} disabled={!s.selection} onClick={() => setTool(s.tool === 'crop' ? 'select' : 'crop')} testId="tb-crop"><Crop /></Glyph>
          <OriginalButton />
        </>}
        {!layout.overflow.navCompareTitle && <Glyph label={tz('Compare', '对比')} keys="Y" on={s.comparing} disabled={!s.selection} onClick={toggleCompare} testId="tb-compare"><BeforeAfter /></Glyph>}
      </div>
      <div className="v2-tb-trail">
        <div className="v2-more">
          <Glyph label={tz('More', '更多')} on={more} onClick={() => setUi({ moreOpen: !more, menu: null })} testId="tb-more"><Ellipsis /></Glyph>
          {more && <div className="v2-menu-drop right" data-testid="more-menu"><MenuList items={overflowItems} onDone={() => setUi({ moreOpen: false })} /></div>}
        </div>
        {!layout.overflow.navCompareTitle && <Glyph label={tz('Paste Settings', '粘贴设置')} keys="Ctrl+Shift+V" disabled={!k.pasteSettings!.enabled} onClick={k.pasteSettings!.run} testId="tb-paste">
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor"><rect x="3.5" y="3.5" width="9" height="11" rx="1" /><path d="M6 3.5V2h4v1.5" /></svg>
        </Glyph>}
        <div className="v2-export-wrap">
          {s.batchExporting && run.progress ? (
            <button className="v2-export running" data-testid="export-ring" onClick={() => setUi({ exportFlyout: !exportFlyout })}
              style={{ ['--v2-ring' as string]: `${run.progress.total ? (run.progress.done / run.progress.total) * 360 : 0}deg` }}
              title={tz('Exporting', '正在导出')}>
              <span className="v2-ring" /><span>{tz(`${Math.min(run.progress.done + 1, run.progress.total)} of ${run.progress.total}`, `${Math.min(run.progress.done + 1, run.progress.total)} / ${run.progress.total}`)}</span>
            </button>
          ) : (
            <button className="v2-export" data-testid="export-button" disabled={!printed || s.batchExporting || s.hostState.phase !== 'ready'} onClick={() => setPages({ exportOpen: true })} title={`${tz('Export', '导出')} (Ctrl+E)`}>
              <Export /><span>{tz('Export', '导出')}</span>
            </button>
          )}
          <ExportingFlyout />
        </div>
        <Glyph label={tz('Edit Rail', '编辑栏')} keys="F8" on={right === 'docked' || right === 'over'} onClick={() => toggleRailCommand('right')} testId="tb-right-rail"><SidebarRight /></Glyph>
      </div>
    </div>
  );
}

/** PC-E12: a failed develop keeps the last print; an InfoBar at the picture's top says why. */
function FailedBar() {
  const failure = useSession((s) => s.renderFailure);
  if (!failure) return null;
  return (
    <div className="v2-infobar" role="alert" data-testid="render-failed">
      <svg className="v2-infobar-icon" width="16" height="16" viewBox="0 0 16 16" aria-hidden><circle cx="8" cy="8" r="7" fill="var(--v2-danger)" /><path d="M8 4v5M8 11.5v.5" stroke="var(--v2-ground)" strokeWidth="1.6" strokeLinecap="round" /></svg>
      <b>{tz('Could not develop', '无法冲洗')}</b>
      <span className="reason">{failure}</span>
      <button className="v2-button" data-testid="try-again" onClick={() => { sessionStore.setState({ renderFailure: null }); void requestPrint(); }}>{tz('Try Again', '重试')}</button>
    </div>
  );
}

/** PC-E13: the engine cannot start — a card on the picture, Try Again, Show Details. */
function EngineStopped() {
  const state = useSession((s) => s.hostState);
  const [details, setDetails] = useState(false);
  if (state.phase !== 'failed') return null;
  return (
    <div className="v2-engine-card" role="alert" data-testid="engine-stopped">
      <b>{tz('The engine cannot start', '引擎无法启动')}</b>
      <span>{state.reason}</span>
      <span className="dim">{tz('The Library still opens; nothing develops.', '图库仍可打开，但无法冲洗。')}</span>
      {details && state.detail && <pre className="v2-details">{state.detail}</pre>}
      <div className="v2-card-buttons">
        <button className="v2-button accent" data-testid="engine-try-again" onClick={() => void restartHost()}>{tz('Try Again', '重试')}</button>
        <button className="v2-button" data-testid="engine-details" onClick={() => setDetails(!details)}>{tz('Show Details', '显示详情')}</button>
      </div>
    </div>
  );
}

/** PC-E8: while the print develops, the camera's embedded preview, said so. */
function EmbeddedCapsule() {
  const show = useSession((s) => !!s.selection && s.badge === null && s.hostState.phase === 'ready');
  return show ? <div className="v2-capsule" data-testid="embedded-preview">{tz('Embedded preview', '内嵌预览')}</div> : null;
}

/** PC-X3: right-click on the picture — Microsoft's command bar flyout. */
function PictureMenu() {
  const at = useUi((u) => u.pictureMenu);
  if (!at) return null;
  const k = commands();
  const close = () => setUi({ pictureMenu: null });
  return (
    <div className="v2-flyout" style={{ left: at.x, top: at.y }} data-testid="picture-menu" onPointerDown={(e) => e.stopPropagation()}>
      <div className="v2-flyout-bar">
        <Glyph label={tz('Copy Settings', '拷贝设置')} onClick={() => { close(); copySettings(); }}><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor"><rect x="5.5" y="5.5" width="8" height="8" rx="1" /><path d="M3 10.5V3a.5.5 0 0 1 .5-.5H10" /></svg></Glyph>
        <Glyph label={tz('Paste Settings', '粘贴设置')} disabled={!k.pasteSettings!.enabled} onClick={() => { close(); k.pasteSettings!.run(); }}><svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor"><rect x="3.5" y="3.5" width="9" height="11" rx="1" /><path d="M6 3.5V2h4v1.5" /></svg></Glyph>
        <Glyph label={tz('Compare', '对比')} onClick={() => { close(); toggleCompare(); }}><BeforeAfter /></Glyph>
        <Glyph label={tz('Export', '导出')} disabled={!k.export!.enabled} onClick={() => { close(); setPages({ exportOpen: true }); }}><Export /></Glyph>
      </div>
      <MenuList onDone={close} items={[k.zoomFit!, k.zoom100!, { separator: true }, { ...k.resetCrop!, label: tz('Reset Crop', '重置裁剪'), run: resetCrop }, { ...k.showInExplorer!, run: showInExplorer }]} />
    </div>
  );
}

const GROUP_WORDS: Record<ClipboardGroup, () => string> = {
  filmAndPaper: () => tz('Film & Paper', '胶片与相纸'),
  exposure: () => tz('Exposure', '曝光'),
  whiteBalance: () => tz('White Balance', '白平衡'),
  filmEffects: () => tz('Format · Grain · Halation', '画幅 · 颗粒 · 光晕'),
  printEffects: () => tz('Enlarger · Effects', '放大机 · 效果'),
  scenePlacement: () => tz('Scene Placement', '场景定位'),
};

/** PC-X2: the Copy Settings flyout; the groups leave out what the engine refuses (README §6.7). */
function CopySettingsFlyout() {
  const open = useUi((u) => u.copySettingsOpen);
  const gate = useSession((s) => s.gate);
  const current = useSession((s) => s.clipboardGroups);
  const [groups, setGroups] = useState<ClipboardGroup[]>(current);
  useEffect(() => { if (open) setGroups(current); }, [open, current]);
  if (!open) return null;
  const offered = CLIPBOARD_GROUPS.filter((g) => g !== 'scenePlacement' || gate.sceneLatitude);
  return (
    <div className="v2-dialog-flyout" role="dialog" aria-label={tz('Copy Settings', '拷贝设置')} data-testid="copy-settings">
      <div className="v2-flyout-head">
        <button className="v2-button" onClick={() => setUi({ copySettingsOpen: false })}>{tz('Cancel', '取消')}</button>
        <b>{tz('Copy Settings', '拷贝设置')}</b>
        <button className="v2-button accent" data-testid="copy-settings-copy" disabled={!groups.length} onClick={() => {
          sessionStore.setState({ clipboardGroups: groups });
          copySettings();
          setUi({ copySettingsOpen: false });
        }}>{tz('Copy', '拷贝')}</button>
      </div>
      {offered.map((g) => (
        <label key={g} className="v2-check-row">
          <input type="checkbox" checked={groups.includes(g)} onChange={(e) => setGroups(e.target.checked ? [...groups, g] : groups.filter((x) => x !== g))} />
          <span>{GROUP_WORDS[g]()}</span>
        </label>
      ))}
    </div>
  );
}

export function Picture({ layout }: { layout: Layout }) {
  const ref = useRef<HTMLDivElement>(null);
  const [room, setRoom] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setRoom({ w: el.clientWidth, h: el.clientHeight }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  void room;
  return (
    <div className="v2-picture" ref={ref} data-testid="picture"
      onContextMenu={(e) => { e.preventDefault(); const r = ref.current!.getBoundingClientRect(); setUi({ pictureMenu: { x: e.clientX - r.left, y: e.clientY - r.top }, moreOpen: false, menu: null }); }}
      onPointerDown={() => { if (layout.left === 'over' || layout.right === 'over') setUi({ overlay: null }); }}>
      <Canvas />
      <FailedBar />
      <EngineStopped />
      <EmbeddedCapsule />
      <PictureMenu />
      <CopySettingsFlyout />
    </div>
  );
}

export function FilmstripBand() {
  return <div className="v2-filmstrip" data-testid="v2-filmstrip"><Filmstrip cellHeight={56} /></div>;
}

export { host };
