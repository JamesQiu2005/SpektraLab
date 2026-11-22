// TopBar.tsx — the canvas's own bar (`Windows/TopBar.swift`, v4):
// ◧ · import · export · select · crop · [Process] [Original] … status …
// before/after · [zoom %] · zoom out · zoom in · ◨
// Selection is orange, not grey (Capture One's convention).

import * as DropdownMenu from '@radix-ui/react-dropdown-menu';
import { BeforeAfter, Crop, Cursor, Export, Import, Redo, SidebarLeft, SidebarRight, Undo, ZoomIn, ZoomOut } from '../controls/icons';
import { t, tz } from '../i18n';
import { currentFitZoom, redo, setOriginal, setPages, setTool, solveNow, toggleCompare, undo, useSession, zoomStep, zoomTo, zoomToFit } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { openFilesDialog } from './actions';
import { baseName } from '../platform';

export function TopBar() {
  const leftCollapsed = useSettings((s) => s.leftCollapsed);
  const rightCollapsed = useSettings((s) => s.rightCollapsed);
  const tool = useSession((s) => s.tool);
  const selection = useSession((s) => s.selection);
  const engine = useSession((s) => s.engineSession);
  const developing = useSession((s) => s.developing);
  const original = useSession((s) => s.showingOriginal);
  const comparing = useSession((s) => s.comparing);
  const status = useSession((s) => s.status);
  const view = useSession((s) => s.view);
  const native = useSession((s) => s.nativeSize);
  const hello = useSession((s) => s.hello);
  const zoomLocked = tool === 'crop';
  const canUndo = useSession((s) => s.undo.length > 0);
  const canRedo = useSession((s) => s.redo.length > 0);
  const fitZoom = useSession((s) => s.fitZoom);
  const pct = Math.round((view.fit ? fitZoom : view.zoom) * 100);
  const info = selection
    ? [baseName(selection), native ? `${native.width}×${native.height}` : '', hello?.mock ? 'mock host' : 'sRGB'].filter(Boolean).join(' · ')
    : '';
  return (
    <div className="topbar" data-testid="topbar">
      <button className="icon-btn" title={leftCollapsed ? t('helpDevelopRailShow') : t('helpDevelopRailHide')} onClick={() => settingsStore.getState().set('leftCollapsed', !leftCollapsed)}>
        <SidebarLeft />
      </button>
      <span style={{ width: 14 }} />
      {/* Photographs, any kind, one or many (the folder is File › Open Folder…, Ctrl+O): a folder picker here
          greyed every file out, and its "Open a folder or image" promised both (the owner, 2026-11-19). */}
      <button className="icon-btn" title={tz('Open photographs (Ctrl+Shift+O)', '打开照片（Ctrl+Shift+O）')} onClick={() => void openFilesDialog()} data-testid="open-button">
        <Import />
      </button>
      <button className="icon-btn" title={tz('Layout: several photographs on one print', '排版：多张照片排在一张上')} onClick={() => setPages({ layoutOpen: true })} data-testid="layout-button">
        <svg viewBox="0 0 20 20" width="18" height="18" aria-hidden="true"><rect x="2" y="4" width="5" height="12" rx="1" fill="currentColor" /><rect x="8" y="4" width="4" height="12" rx="1" fill="currentColor" opacity="0.7" /><rect x="13" y="4" width="5" height="12" rx="1" fill="currentColor" /></svg>
      </button>
      <button className="icon-btn" title={t('helpExport') + ' (Ctrl+E)'} disabled={!selection} onClick={() => setPages({ exportOpen: true })} data-testid="export-button">
        <Export />
      </button>
      <span style={{ width: 14 }} />
      <button className={'icon-btn ' + (tool === 'select' ? 'active' : 'dim')} title={t('helpSelect') + ' (V)'} onClick={() => setTool('select')}>
        <Cursor />
      </button>
      <button className={'icon-btn ' + (tool === 'crop' ? 'active' : 'dim')} title={tz('Crop (C)', '裁剪（C）')} onClick={() => setTool(tool === 'crop' ? 'select' : 'crop')} data-testid="crop-tool">
        <Crop />
      </button>
      <span style={{ width: 14 }} />
      {/* Also Edit › Undo / Redo and Ctrl+Z / Ctrl+Shift+Z; these are the only way on a touch screen. */}
      <button className="icon-btn" title={tz('Undo (Ctrl+Z)', '撤销（Ctrl+Z）')} disabled={!canUndo} onClick={undo} data-testid="undo-button">
        <Undo />
      </button>
      <button className="icon-btn" title={tz('Redo (Ctrl+Shift+Z)', '重做（Ctrl+Shift+Z）')} disabled={!canRedo} onClick={redo} data-testid="redo-button">
        <Redo />
      </button>
      <span style={{ width: 26 }} />
      <button
        className={'action-pill' + (engine && !developing ? ' active' : '')}
        disabled={!engine || developing}
        onClick={() => void solveNow()}
        title={tz('Auto-exposure and the enlarger filter pack for this paper — print this frame.', '自动曝光并为这张相纸求解放大机滤色——印放这张照片。')}
        data-testid="process"
      >
        {t('actionSolve')}
      </button>
      <span style={{ width: 12 }} />
      <button className={'action-pill' + (original ? ' active' : '')} disabled={!selection} onClick={() => setOriginal(!original)} title={tz('Show the camera’s own rendering, before any film simulation (Space, while held).', '显示相机自身的渲染，未经胶片模拟（按住空格键）。')}>
        {t('actionOriginal')}
      </button>
      <span className="bar-status" data-testid="status" title={status || info}>
        {developing ? '⏳ ' : ''}
        {status || info}
      </span>
      <button className={'icon-btn' + (comparing ? ' active' : '')} style={{ width: 34 }} disabled={!selection} onClick={toggleCompare} title={t('helpBeforeAfter') + ' (Y)'}>
        <BeforeAfter />
      </button>
      <span style={{ width: 24 }} />
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild disabled={zoomLocked}>
          <button className="zoom-pill" title={view.fit ? tz('Fitted to the window (,)', '适合窗口（,）') : tz('Zoom', '缩放')} data-testid="zoom-pill">
            {selection ? `${pct} %` : '—'}
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content className="menu" sideOffset={4}>
            <DropdownMenu.Item className="menu-item" onSelect={zoomToFit}>
              <span className="check">{view.fit ? '✓' : ''}</span>
              {t('helpFit')}
            </DropdownMenu.Item>
            {[0.25, 0.5, 1, 2, 4].map((f) => (
              <DropdownMenu.Item key={f} className="menu-item" onSelect={() => zoomTo(f)}>
                <span className="check">{!view.fit && view.zoom === f ? '✓' : ''}</span>
                {f * 100} %
              </DropdownMenu.Item>
            ))}
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      <span style={{ width: 16 }} />
      <button className="icon-btn" disabled={zoomLocked || !selection} title={t('helpZoomOut') + ' (Ctrl+−)'} onClick={() => zoomStep(-1, currentFitZoom)}>
        <ZoomOut />
      </button>
      <button className="icon-btn" disabled={zoomLocked || !selection} title={t('helpZoomIn') + ' (Ctrl++)'} onClick={() => zoomStep(1, currentFitZoom)}>
        <ZoomIn />
      </button>
      <span style={{ width: 14 }} />
      <button className="icon-btn" title={rightCollapsed ? t('helpEditRailShow') : t('helpEditRailHide')} onClick={() => settingsStore.getState().set('rightCollapsed', !rightCollapsed)}>
        <SidebarRight />
      </button>
    </div>
  );
}
