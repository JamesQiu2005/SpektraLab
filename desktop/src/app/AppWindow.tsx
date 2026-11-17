// AppWindow.tsx — the one window (README §1, board_window.svg): a 32 epx
// title bar over the left rail · the picture · the right rail; the toolbar
// over the picture only; the filmstrip under it. The Library is a workspace
// of the same window (Library | Edit), not a second window.
//
// Rails fold by the window's width (layout.ts); a folded rail comes back over
// the picture with a shadow (F7/F8), and Esc or a click on the picture puts
// it away. The walls between them drag 280–440, double-click for 320.

import { useEffect, useRef } from 'react';
import { TitleBar } from './TitleBar';
import { computeLayout } from './layout';
import { useUi } from './ui';
import { useSettings, settingsStore } from '../state/settings';
import { useSession } from '../state/session';
import { DevelopRail, EditRail } from '../edit/rails';
import { FilmstripBand, Picture, Toolbar } from '../edit/EditWorkspace';
import { LibraryWorkspace } from '../library/LibraryWorkspace';
import { AboutDialog } from '../windows/Dialogs';
import { FolderImportDialog } from '../windows/FolderImportDialog';
import { ExportDialog } from '../export/ExportDialog';
import { SettingsWindow } from '../settings/SettingsWindow';
import { useLibrary } from '../library/store';
import { baseName } from '../platform';
import { setWindowTitle, watchWindow } from './windowChrome';
import { scheduler } from '../scheduler';
import { geometry as G } from '../theme/tokens';

function Wall({ side, x }: { side: 'left' | 'right'; x: number }) {
  const drag = useRef<{ x: number; w: number } | null>(null);
  const key = side === 'left' ? 'railLeft' : 'railRight';
  return (
    <div className="v2-wall" data-testid={`wall-${side}`} style={{ left: x - (G.wallGrip - 1) / 2 }}
      role="separator" aria-orientation="vertical" aria-label={side === 'left' ? 'Develop rail width' : 'Edit rail width'}
      onPointerDown={(e) => { (e.target as HTMLElement).setPointerCapture(e.pointerId); drag.current = { x: e.clientX, w: settingsStore.getState()[key] }; }}
      onPointerMove={(e) => { const d = drag.current; if (!d) return; const dx = e.clientX - d.x; settingsStore.getState().set(key, d.w + (side === 'left' ? dx : -dx)); }}
      onPointerUp={() => { drag.current = null; }}
      onDoubleClick={() => settingsStore.getState().set(key, G.rail)} />
  );
}

export function AppWindow() {
  const ui = useUi((s) => s);
  const st = useSettings((s) => s);
  const selection = useSession((s) => s.selection);
  const cropping = useSession((s) => s.tool === 'crop');
  const batch = useSession((s) => s.batchExporting);
  const exportOpen = useSession((s) => s.exportOpen);
  const settingsOpen = useSession((s) => s.settingsOpen);
  const source = useLibrary((s) => s.source);
  const layout = computeLayout({ width: ui.window.width, height: ui.window.height, leftHidden: st.leftCollapsed, rightHidden: st.rightCollapsed,
    filmstripHidden: st.filmstripCollapsed, navigatorHidden: st.navigatorHidden, overlay: ui.overlay, railLeft: st.railLeft, railRight: st.railRight, fullScreen: ui.fullScreen });
  const library = ui.workspace === 'library';
  const title = library ? `${source?.info.name ?? 'SpektraLab'}${source ? ' — SpektraLab' : ''}` : selection ? `${baseName(selection).replace(/\.[^.]+$/, '')} — SpektraLab` : 'SpektraLab';
  useEffect(() => watchWindow(), []);
  useEffect(() => { void setWindowTitle(title); }, [title]);
  // Tell the scheduler what the window is doing (PRD-W0 §5.2).
  useEffect(() => {
    void scheduler().frontendState({ visiblePage: exportOpen ? 'export' : settingsOpen ? 'settings' : library ? (ui.libraryView === 'grid' ? 'library' : ui.libraryView) : 'edit',
      openFrame: selection, foreground: true, interaction: 'idle', dialogOpen: false });
  }, [exportOpen, settingsOpen, library, ui.libraryView, selection]);
  const leftShown = layout.left === 'docked' || layout.left === 'over';
  const rightShown = layout.right === 'docked' || layout.right === 'over';
  return (
    <div className={'v2-window' + (ui.maximized || ui.fullScreen ? ' square' : '')} data-testid="v2-window" data-workspace={ui.workspace}
      style={{ ['--v2-rail-left' as string]: `${layout.leftWidth}px`, ['--v2-rail-right' as string]: `${layout.rightWidth}px`, ['--v2-title-h' as string]: `${layout.titleBar}px` }}>
      {!ui.fullScreen && <TitleBar title={title} />}
      {library ? <LibraryWorkspace layout={layout} /> : (
        <div className="v2-body" style={{ pointerEvents: batch ? 'none' : undefined }} data-testid="editor">
          {leftShown && <DevelopRail mode={layout.left} navigator={layout.navigator} />}
          {layout.left === 'docked' && <Wall side="left" x={layout.leftWidth} />}
          <main className="v2-centre" style={{ left: layout.picture.x, width: layout.picture.width }} data-testid="centre">
            <Toolbar layout={layout} />
            <Picture layout={layout} />
            {layout.filmstrip && !cropping && <FilmstripBand />}
          </main>
          {layout.right === 'docked' && <Wall side="right" x={ui.window.width - layout.rightWidth - 1} />}
          {rightShown && <EditRail mode={layout.right} />}
        </div>
      )}
      <ExportDialog />
      <SettingsWindow />
      <FolderImportDialog />
      <AboutDialog />
    </div>
  );
}
