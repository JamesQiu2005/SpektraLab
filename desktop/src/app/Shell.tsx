// Shell.tsx — the one window's own pieces (PRD-W5 §2): the mode row at the
// top of the left column, the shared bar at the leading edge of the picture
// bar, and the walls the column and the browser are dragged by.
//
// Placement is the Mac's (`MacModeSwitch`, `MacSharedControls`,
// `MacBrowserSplit`); the look of every piece is the Windows drawing's — the
// mode row is the drawn workspace switch's capsule (PC-E1, x 14–306), the
// shared bar's glyphs are cut from the SVGs, the sort is the drawn capsule.

import { useRef } from 'react';
import { tz } from '../i18n';
import { Glyph as G } from '../theme/Glyph';
import { geometry as GEO } from '../theme/tokens';
import { settingsStore } from '../state/settings';
import { useSession, setTool } from '../state/session';
import { LIBRARY_SORTS, setSort, sortWords, useLibrary } from '../library/store';
import { MenuButton } from '../edit/rails';
import { chooseMode, MODES, modeUnavailable, modeWords } from './modes';
import { setLibraryView, setUi, useUi } from './ui';
import { toggleFullGrid, toggleRailCommand } from './commands';
import { BROWSER, MIN_PICTURE, type Layout } from './layout';

/**
 * Library · Develop · Edit (`MacModeSwitch`): one row for the whole window, in the column's head in
 * every mode. The white capsule is the mode in front; a mode that cannot be entered is dimmed, and a
 * press on it says why under the row.
 */
export function ModeRow() {
  const current = useUi((u) => u.workspace);
  const note = useUi((u) => u.modeNote);
  // Read so the row redraws when what makes a mode available changes.
  useSession((s) => s.selection);
  useSession((s) => s.frames.length);
  useLibrary((l) => l.images.length);
  return (
    <div className="v2-mode-wrap">
      <div className="v2-switch modes" role="tablist" aria-label={tz('Mode', '模式')} data-testid="mode-row">
        {MODES.map((m) => {
          const why = modeUnavailable(m);
          return (
            <button key={m} role="tab" aria-selected={current === m} aria-disabled={!!why || undefined} className={(current === m ? 'on' : '') + (why ? ' off' : '')}
              data-testid={`mode-${m}`} title={why ?? undefined} onClick={() => void chooseMode(m)}>{modeWords(m)}</button>
          );
        })}
      </div>
      {note && <div className="v2-mode-note" role="status" data-testid="mode-note">{note}</div>}
    </div>
  );
}

/** A pane's wall: dragged, the pane's width; double-click, its default. `left` is the column's, `right` the browser's. */
export function Wall({ side, x, layout }: { side: 'left' | 'right'; x: number; layout: Layout }) {
  const drag = useRef<{ x: number; w: number } | null>(null);
  const key = side === 'left' ? 'railLeft' : 'browserWidth';
  const set = (w: number) => {
    const st = settingsStore.getState();
    if (side === 'right') {
      // The picture keeps its least width: the browser is not dragged over it (`MacImportFlow`'s `most`).
      const room = layout.picture.width + layout.rightWidth - MIN_PICTURE;
      st.set('browserWidth', Math.min(w, Math.max(BROWSER.min, room)));
    } else st.set('railLeft', w);
  };
  return (
    <div className="v2-wall" data-testid={`wall-${side}`} style={{ left: x - (GEO.wallGrip - 1) / 2 }}
      role="separator" aria-orientation="vertical" aria-label={side === 'left' ? tz('Left column width', '左栏宽度') : tz('Browser width', '浏览器宽度')}
      onPointerDown={(e) => { (e.target as HTMLElement).setPointerCapture(e.pointerId); drag.current = { x: e.clientX, w: side === 'left' ? layout.leftWidth : layout.rightWidth }; }}
      onPointerMove={(e) => { const d = drag.current; if (!d) return; const dx = e.clientX - d.x; set(d.w + (side === 'left' ? dx : -dx)); }}
      onPointerUp={() => { drag.current = null; }}
      onDoubleClick={() => settingsStore.getState().set(key, side === 'left' ? GEO.rail : BROWSER.width)} />
  );
}

function Btn({ label, keys, on, disabled, onClick, testId, children }: { label: string; keys?: string; on?: boolean; disabled?: boolean; onClick: () => void; testId: string; children: React.ReactNode }) {
  return (
    <button className={'v2-glyph' + (on ? ' on' : '')} title={keys ? `${label} (${keys})` : label} aria-label={label} aria-pressed={on} disabled={disabled}
      onClick={onClick} data-testid={testId}>{children}</button>
  );
}

/**
 * The window's one control group (`MacSharedControls`), the same in all three modes: the left
 * column's toggle · the viewer | browser split · the full grid · the loupe (the chosen pictures on
 * the Light Table) · Crop · the sort and its direction.
 */
export function SharedBar({ layout }: { layout: Layout }) {
  const ws = useUi((u) => u.workspace);
  const lib = useLibrary((l) => l);
  const has = useSession((s) => !!s.selection);
  const cropping = useSession((s) => s.tool === 'crop');
  const column = layout.left === 'docked' || layout.left === 'over';
  const split = !layout.fullGrid && (layout.right === 'docked' || layout.right === 'over');
  const folder = !lib.source;
  return (
    <div className="v2-shared" role="group" aria-label={tz('Window', '窗口')} data-testid="shared-bar">
      <Btn label={tz('Left Column', '左栏')} keys="Ctrl+B" on={column} onClick={() => toggleRailCommand('left')} testId="bar-column"><G name="dockLeft" /></Btn>
      <Btn label={tz('Browser', '浏览器')} keys="F8" on={split} onClick={() => toggleRailCommand('right')} testId="bar-split"><G name="dockRight" /></Btn>
      <Btn label={tz('Grid', '网格')} keys="G" on={layout.fullGrid} onClick={toggleFullGrid} testId="bar-grid"><G name="gridView" /></Btn>
      <Btn label={tz('Light Table', '看片台')} keys="Ctrl+Shift+L" disabled={folder} onClick={() => setLibraryView('lightTable')} testId="bar-loupe"><G name="table" /></Btn>
      <Btn label={tz('Crop', '裁剪')} keys="C" on={cropping && ws !== 'library'} disabled={!has}
        onClick={() => { if (ws === 'library') void chooseMode('develop').then(() => setTool('crop')); else setTool(cropping ? 'select' : 'crop'); }} testId="bar-crop"><G name="crop" /></Btn>
      <MenuButton className={'v2-pill sort' + (folder ? ' off' : '')} label={`${tz('Sort', '排序')}: ${sortWords(lib.sort)}`} testId="bar-sort" items={() => LIBRARY_SORTS.map((k) => ({
        id: `sort-${k}`, label: sortWords(k), enabled: !folder, checked: lib.sort === k, run: () => void setSort(k),
      }))}><span>{sortWords(lib.sort)}</span><G name="dropDown" /></MenuButton>
      <Btn label={lib.descending ? tz('Descending', '降序') : tz('Ascending', '升序')} disabled={folder} onClick={() => void setSort(lib.sort, !lib.descending)} testId="bar-direction">
        <span className={'v2-direction' + (lib.descending ? '' : ' up')}><G name="chevronDown" /></span>
      </Btn>
    </div>
  );
}

export { setUi };
