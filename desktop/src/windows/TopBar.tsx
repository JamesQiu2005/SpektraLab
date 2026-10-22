// TopBar.tsx — the canvas's own bar (`Windows/TopBar.swift`, v4):
// ◧ · import · export · select · crop · [Process] [Original] … status …
// before/after · [zoom %] · zoom out · zoom in · ◨
// Selection is orange, not grey (Capture One's convention).

import * as DropdownMenu from '@radix-ui/react-dropdown-menu';
import { BeforeAfter, Crop, Cursor, Export, Import, SidebarLeft, SidebarRight, ZoomIn, ZoomOut } from '../controls/icons';
import { t, tz } from '../i18n';
import { canMakePair, makePair, currentFitZoom, pairComplete, reloadExternalEdits, setOriginal, setPages, setTool, solveNow, toggleCompare, useSession, zoomStep, zoomTo, zoomToFit } from '../state/session';
import { settingsStore, useSettings } from '../state/settings';
import { openDialog } from './actions';
import { baseName } from '../platform';
import type { PreviewGamut } from '../canvas/colorSpace';
import { sourceGeometryFor } from '@shared/filmEdge';

export function TopBar() {
  const leftCollapsed = useSettings((s) => s.leftCollapsed);
  const rightCollapsed = useSettings((s) => s.rightCollapsed);
  const previewGamut = useSettings((s) => s.previewGamut);
  const displaySpace = useSession((s) => s.displaySpace);
  const tool = useSession((s) => s.tool);
  const selection = useSession((s) => s.selection);
  const engine = useSession((s) => s.engineSession);
  const developing = useSession((s) => s.developing);
  const original = useSession((s) => s.showingOriginal);
  const comparing = useSession((s) => s.comparing);
  const filmCanvas = useSession((s) => !!sourceGeometryFor(s.sidecar.params, s.sidecar.geometry, s.gate));
  const pairPlacing = useSession((s) => s.pairPlacing);
  const exportReady = useSession((s) => pairComplete(s));
  const pairReady = useSession(() => canMakePair());
  const status = useSession((s) => s.status);
  const externalConflict = useSession((s) => s.externalEditConflict);
  const view = useSession((s) => s.view);
  const native = useSession((s) => s.nativeSize);
  const hello = useSession((s) => s.hello);
  const zoomLocked = tool === 'crop';
  const fitZoom = useSession((s) => s.fitZoom);
  const pct = Math.round((view.fit ? fitZoom : view.zoom) * 100);
  const displayLabel = displaySpace === 'display-p3' ? 'Display P3' : 'sRGB';
  const previewLabel = previewGamut === 'auto' ? `${tz('Auto', '自动')} · ${displayLabel}`
    : previewGamut === 'display-p3' && displaySpace !== 'display-p3' ? 'P3 → sRGB' : displayLabel;
  const previewHelp = tz(
    'Preview gamut only. Internal working space: ProPhoto RGB. Export uses its own recipe. Display P3 requires browser support; visible colours depend on the display. Unsupported previews use sRGB.',
    '仅切换窗口预览色域。内部工作空间：ProPhoto RGB。导出色域由导出预设决定。Display P3 需要浏览器支持，可见色域取决于显示器；不支持时回退为 sRGB。',
  );
  const info = selection
    ? [baseName(selection), native ? `${native.width}×${native.height}` : '', hello?.mock ? 'mock host' : displayLabel].filter(Boolean).join(' · ')
    : '';
  return (
    <div className="topbar editor-topbar" data-testid="topbar">
      <div className="topbar-controls">
        <div className="topbar-group">
          <button className="icon-btn" title={leftCollapsed ? t('helpDevelopRailShow') : t('helpDevelopRailHide')} onClick={() => settingsStore.getState().set('leftCollapsed', !leftCollapsed)}>
            <SidebarLeft />
          </button>
          <button className="icon-btn" title={t('helpOpen') + ' (Ctrl+O)'} onClick={() => void openDialog()} data-testid="open-button">
            <Import />
          </button>
          <button className="icon-btn" title={t('helpExport') + ' (Ctrl+E)'} disabled={!selection || !exportReady} onClick={() => setPages({ exportOpen: true })} data-testid="export-button">
            <Export />
          </button>
        </div>
        <div className="topbar-group">
          <button className="pill-menu" disabled={!pairReady} onClick={() => void makePair()} title={tz(
            'Combine photos into a half-frame pair (Ctrl+J). Uses the first two selected photos in strip order; with one photo, add the second later. Source files stay unchanged.',
            '将照片拼成双图半格画面（Ctrl+J）。按胶片条顺序使用前两张已选照片；仅选一张时，可稍后添加第二张。原始文件不会修改。',
          )} data-testid="make-pair">{tz('Pair photos', '双图拼接')}</button>
          <button className={'icon-btn ' + (tool === 'select' ? 'active' : 'dim')} title={t('helpSelect') + ' (V)'} onClick={() => setTool('select')}>
            <Cursor />
          </button>
          <button className={'icon-btn ' + (tool === 'crop' || pairPlacing ? 'active' : 'dim')} title={tz('Crop (C)', '裁剪（C）')} onClick={() => setTool(tool === 'crop' ? 'select' : 'crop')} data-testid="crop-tool">
            <Crop />
          </button>
        </div>
        <div className="topbar-group topbar-process-group">
          <button
            className={'action-pill' + (engine && !developing ? ' active' : '')}
            disabled={!engine || developing}
            onClick={() => void solveNow()}
            title={tz('Auto-exposure and the enlarger filter pack for this paper — print this frame.', '自动曝光并为这张相纸求解放大机滤色——印放这张照片。')}
            data-testid="process"
          >
            {t('actionSolve')}
          </button>
          <button className={'action-pill' + (original ? ' active' : '')} disabled={!selection || filmCanvas} onClick={() => setOriginal(!original)} title={filmCanvas ? tz('Use Framing to view the source with Film Edge or Date Back.', '使用取景功能查看带片边或日期后背的原始画面。') : tz('Show the current decode, before film simulation (hold Space).', '显示当前解码、未经胶片模拟的画面（按住空格键）。')}>
            {t('actionOriginal')}
          </button>
        </div>
        <div className="topbar-group topbar-display-group">
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <button className="zoom-pill" title={previewHelp}
                aria-label={tz('Preview gamut', '预览色域')} data-testid="preview-gamut">{previewLabel}</button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content className="menu" sideOffset={4}>
                {(['auto', 'srgb', 'display-p3'] as PreviewGamut[]).map((gamut) => (
                  <DropdownMenu.Item key={gamut} className="menu-item" onSelect={() => settingsStore.getState().set('previewGamut', gamut)}>
                    <span className="check">{previewGamut === gamut ? '✓' : ''}</span>
                    {gamut === 'auto' ? tz('Automatic', '自动') : gamut === 'srgb' ? 'sRGB' : 'Display P3'}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
          <button className={'icon-btn' + (comparing ? ' active' : '')} style={{ width: 34 }} disabled={!selection || filmCanvas} onClick={toggleCompare} title={filmCanvas ? tz('Before/after is unavailable on the film canvas.', '胶片画布暂不支持前后对照。') : t('helpBeforeAfter') + ' (Y)'}>
            <BeforeAfter />
          </button>
        </div>
        <div className="topbar-group">
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild disabled={zoomLocked}>
              <button className="zoom-pill" title={view.fit ? tz('Fitted to the window (,)', '适合窗口（,）') : tz('Zoom', '缩放')} data-testid="zoom-pill">
                {selection ? `${pct}\u00a0%` : '—'}
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
          <button className="icon-btn" disabled={zoomLocked || !selection} title={t('helpZoomOut') + ' (Ctrl+−)'} onClick={() => zoomStep(-1, currentFitZoom)}>
            <ZoomOut />
          </button>
          <button className="icon-btn" disabled={zoomLocked || !selection} title={t('helpZoomIn') + ' (Ctrl++)'} onClick={() => zoomStep(1, currentFitZoom)}>
            <ZoomIn />
          </button>
          <button className="icon-btn" title={rightCollapsed ? t('helpEditRailShow') : t('helpEditRailHide')} onClick={() => settingsStore.getState().set('rightCollapsed', !rightCollapsed)}>
            <SidebarRight />
          </button>
        </div>
      </div>
      <div className="topbar-info">
        <span className="bar-status" data-testid="status" title={status || info}>
          {developing ? '⏳ ' : ''}
          {status || info}
        </span>
        {externalConflict && <button className="pill-menu" data-testid="reload-external" onClick={() => void reloadExternalEdits()}>
          {tz('Reload external edits…', '重新加载外部编辑…')}
        </button>}
      </div>
    </div>
  );
}
