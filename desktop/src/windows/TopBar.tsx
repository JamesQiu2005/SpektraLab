// TopBar.tsx — the canvas's own bar (`Windows/TopBar.swift`, v4):
// ◧ · import · export · select · crop · [Process] [Original] … status …
// before/after · [zoom %] · zoom out · zoom in · ◨
// Selection is orange, not grey (Capture One's convention).

import * as DropdownMenu from '@radix-ui/react-dropdown-menu';
import { BeforeAfter, Crop, Cursor, Export, Import, SidebarLeft, SidebarRight, ZoomIn, ZoomOut } from '../controls/icons';
import { t, tz } from '../i18n';
import { currentFitZoom, setOriginal, setPages, setTool, solveNow, toggleCompare, useSession, zoomStep, zoomTo, zoomToFit } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { openDialog } from './actions';
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
      <button className="icon-btn" title={t('helpOpen') + ' (Ctrl+O)'} onClick={() => void openDialog()} data-testid="open-button">
        <Import />
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
      <span style={{ width: 40 }} />
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
