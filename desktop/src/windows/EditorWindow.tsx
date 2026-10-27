// EditorWindow.tsx — three regions and a filmstrip (ARCHITECTURE §7.1):
// Film and Print (left) | top bar + canvas + filmstrip | Parameters (right).

import { Canvas } from '../canvas/Canvas';
import { LeftRail } from '../panels/LeftRail';
import { RightRail } from '../panels/RightRail';
import { useRef } from 'react';
import { useSettings, settingsStore, panelWidth, PANEL_WIDTHS } from '../state/settings';
import { useSession, sessionStore } from '../state/session';
import { tz } from '../i18n';
import { Filmstrip } from './Filmstrip';
import { TopBar } from './TopBar';
import { AboutDialog, HostFailure, SettingsDialog } from './Dialogs';
import { ExportPage } from '../export/ExportPage';

export function EditorWindow() {
  const left = useSettings((s) => s.leftCollapsed);
  const right = useSettings((s) => s.rightCollapsed);
  const strip = useSettings((s) => s.filmstripCollapsed);
  const leftWidth = useSettings((s) => s.leftWidth);
  const rightWidth = useSettings((s) => s.rightWidth);
  const batch = useSession((s) => s.batchExporting);
  return (
    <>
      <div
        className="editor"
        style={{ ['--left-col' as string]: left ? '0px' : `${panelWidth('left', leftWidth)}px`, ['--right-col' as string]: right ? '0px' : `${panelWidth('right', rightWidth)}px`, pointerEvents: batch ? 'none' : undefined }}
        data-testid="editor"
      >
        {left ? <div /> : <div className="rail-shell"><LeftRail /><RailResize side="left" /></div>}
        <main className="centre" style={{ position: 'relative' }}>
          <TopBar />
          <Canvas />
          {!strip && <Filmstrip />}
          <HostFailure />
        </main>
        {right ? <div /> : <div className="rail-shell"><RightRail /><RailResize side="right" /></div>}
      </div>
      <SettingsDialog />
      <AboutDialog />
      <ExportPage />
    </>
  );
}

function RailResize({ side }: { side: 'left' | 'right' }) {
  const key = side === 'left' ? 'leftWidth' : 'rightWidth';
  const width = useSettings((s) => s[key]);
  const range = PANEL_WIDTHS[side];
  const direction = side === 'left' ? 1 : -1;
  const drag = useRef<{ x: number; width: number; pointer: number } | null>(null);
  const change = (v: number) => {
    if (sessionStore.getState().batchExporting) return;
    const next = panelWidth(side, v);
    if (settingsStore.getState()[key] !== next) settingsStore.getState().set(key, next);
  };
  return <div className={`rail-resize ${side}`} role="separator" tabIndex={0}
    aria-label={side === 'left' ? tz('Resize film and print panel', '调整胶片与相纸栏宽度') : tz('Resize parameters panel', '调整参数栏宽度')}
    aria-orientation="vertical" aria-valuemin={range.min} aria-valuemax={range.max} aria-valuenow={panelWidth(side, width)}
    onDoubleClick={() => change(range.standard)}
    onPointerDown={(e) => {
      if (e.button !== 0 || sessionStore.getState().batchExporting) return;
      e.preventDefault(); e.currentTarget.focus();
      drag.current = { x: e.clientX, width: panelWidth(side, width), pointer: e.pointerId };
      e.currentTarget.setPointerCapture(e.pointerId);
    }}
    onPointerMove={(e) => {
      const start = drag.current;
      if (start?.pointer === e.pointerId) change(start.width + direction*(e.clientX-start.x));
    }}
    onPointerUp={(e) => { drag.current = null; if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId); }}
    onLostPointerCapture={() => { drag.current = null; }}
    onKeyDown={(e) => {
      const delta = (e.shiftKey ? 1 : 10)*direction;
      if (e.key === 'Home') change(range.min);
      else if (e.key === 'End') change(range.max);
      else if (e.key === 'ArrowLeft') change(width-delta);
      else if (e.key === 'ArrowRight') change(width+delta);
      else return;
      e.preventDefault(); e.stopPropagation();
    }} />;
}
