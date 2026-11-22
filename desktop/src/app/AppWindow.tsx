// AppWindow.tsx — the one window (PRD-W5 §2; the Mac's `MainWindowLayout`):
// a 32 epx title bar over the LEFT COLUMN (the mode row, then the mode's
// tools) · the picture (the picture bar over it, the info strip under it) ·
// the BROWSER (the library's rows, in every mode). The mode is state, not a
// page: the shell is mounted once, so going to the Library and back has no
// page transition and the browser's scroll and selection are as they were.
// The light table and the contact sheet are full-window pages above it.
//
// Panes fold by the window's width (layout.ts: the browser first, then the
// column); a folded pane comes back over the picture with a shadow (F7/F8),
// and Esc or a press on the picture puts it away. The column's wall drags
// 280–440, the browser's 240–900; double-click for the default.

import { useEffect, useLayoutEffect } from 'react';
import { TitleBar } from './TitleBar';
import { computeLayout } from './layout';
import { setUi, useUi } from './ui';
import { useSettings } from '../state/settings';
import { useSession } from '../state/session';
import { DevelopTools, EditTools, LatitudeMeter } from '../edit/rails';
import { InfoStrip, Picture, Toolbar } from '../edit/EditWorkspace';
import { FullWindowPage, LibraryCentre, LibraryColumn } from '../library/LibraryWorkspace';
import { LibraryBrowser } from '../library/LibraryBrowser';
import { AboutDialog } from '../windows/Dialogs';
import { FolderImportDialog } from '../windows/FolderImportDialog';
import { ExportDialog } from '../export/ExportDialog';
import { SettingsWindow } from '../settings/SettingsWindow';
import { useLibrary } from '../library/store';
import { baseName } from '../platform';
import { setWindowTitle, watchWindow } from './windowChrome';
import { scheduler } from '../scheduler';
import { tz } from '../i18n';
import { ModeRow, Wall } from './Shell';
import type { Layout, RailMode } from './layout';

/** The left column: the mode row in its head, then the mode's tools (the Library's, or the meter and Develop's or Edit's). */
function Column({ mode, layout }: { mode: RailMode; layout: Layout }) {
  const ws = useUi((u) => u.workspace);
  return (
    <aside className={`v2-rail left ${mode}`} data-testid="rail-left" data-mode={mode} data-column={ws} aria-label={tz('Left column', '左栏')}>
      <div className="v2-rail-head modes" data-testid="rail-left-head"><ModeRow /></div>
      {/* Every mode's tools stay mounted (their scroll and open sections are kept); the one in front shows. */}
      <div className="v2-column-page" hidden={ws !== 'library'} data-testid="column-library"><LibraryColumn /></div>
      {ws !== 'library' && <div className="v2-rail-fixed latitude" data-testid="latitude-meter"><LatitudeMeter /></div>}
      <div className="v2-column-page" hidden={ws !== 'develop'} data-testid="column-develop"><DevelopTools navigator={layout.navigator} /></div>
      <div className="v2-column-page" hidden={ws !== 'edit'} data-testid="column-edit"><EditTools /></div>
    </aside>
  );
}

export function AppWindow() {
  const ui = useUi((s) => s);
  const st = useSettings((s) => s);
  const selection = useSession((s) => s.selection);
  const batch = useSession((s) => s.batchExporting);
  const exportOpen = useSession((s) => s.exportOpen);
  const settingsOpen = useSession((s) => s.settingsOpen);
  const source = useLibrary((s) => s.source);
  const layout = computeLayout({ width: ui.window.width, height: ui.window.height, leftHidden: st.leftCollapsed, rightHidden: st.rightCollapsed,
    fullGrid: ui.fullGrid, navigatorHidden: st.navigatorHidden, overlay: ui.overlay, railLeft: st.railLeft, browserWidth: st.browserWidth, fullScreen: ui.fullScreen });
  const library = ui.workspace === 'library';
  const title = library ? `${source?.info.name ?? 'SpektraLab'}${source ? ' — SpektraLab' : ''}` : selection ? `${baseName(selection).replace(/\.[^.]+$/, '')} — SpektraLab` : 'SpektraLab';
  const overlayDocked = ui.overlay !== null && layout[ui.overlay] === 'docked';
  useLayoutEffect(() => {
    // Once the pane fits beside the picture, its temporary overlay is over.
    if (overlayDocked) setUi({ overlay: null });
  }, [overlayDocked]);
  useEffect(() => watchWindow(), []);
  useEffect(() => { void setWindowTitle(title); }, [title]);
  // Tell the scheduler what the window is doing (PRD-W0 §5.2).
  useEffect(() => {
    void scheduler().frontendState({ visiblePage: exportOpen ? 'export' : settingsOpen ? 'settings' : library ? (ui.libraryView === 'grid' ? 'library' : ui.libraryView) : 'edit',
      openFrame: selection, foreground: true, interaction: 'idle', dialogOpen: false });
  }, [exportOpen, settingsOpen, library, ui.libraryView, selection]);
  const leftShown = layout.left === 'docked' || layout.left === 'over';
  const rightShown = layout.fullGrid || layout.right === 'docked' || layout.right === 'over';
  const W = ui.window.width;
  return (
    <div className={'v2-window' + (ui.maximized || ui.fullScreen ? ' square' : '')} data-testid="v2-window" data-workspace={ui.workspace}
      style={{ ['--v2-rail-left' as string]: `${layout.leftWidth}px`, ['--v2-rail-right' as string]: `${layout.rightWidth}px`, ['--v2-title-h' as string]: `${layout.titleBar}px` }}>
      {!ui.fullScreen && <TitleBar title={title} />}
      <div className="v2-body" style={{ pointerEvents: batch ? 'none' : undefined }} data-testid="editor">
        {leftShown && <Column mode={layout.left} layout={layout} />}
        {layout.left === 'docked' && <Wall side="left" x={layout.leftWidth} layout={layout} />}
        {!layout.fullGrid && (
          <main className="v2-centre" style={{ left: layout.picture.x, width: layout.picture.width }} data-testid="centre">
            <Toolbar layout={layout} />
            {library ? <LibraryCentre /> : <><Picture layout={layout} /><InfoStrip layout={layout} /></>}
          </main>
        )}
        {layout.right === 'docked' && !layout.fullGrid && <Wall side="right" x={W - layout.rightWidth - 1} layout={layout} />}
        {/* The browser is mounted in every mode (folded, it is only out of sight), so its scroll is kept. */}
        <div className="v2-browser-slot" hidden={!rightShown} style={layout.fullGrid ? { left: layout.picture.x } : { width: layout.rightWidth }}>
          {layout.fullGrid && <div className="v2-full-grid-bar"><Toolbar layout={layout} /></div>}
          <LibraryBrowser mode={layout.fullGrid ? 'full' : layout.right} width={layout.fullGrid ? W - layout.picture.x : layout.rightWidth} full={layout.fullGrid} />
        </div>
      </div>
      <FullWindowPage />
      <ExportDialog />
      <SettingsWindow />
      <FolderImportDialog />
      <AboutDialog />
    </div>
  );
}
