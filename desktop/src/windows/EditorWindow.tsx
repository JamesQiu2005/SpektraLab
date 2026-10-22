// EditorWindow.tsx — three regions and a filmstrip (ARCHITECTURE §7.1):
// Film and Print (left) | top bar + canvas + filmstrip | Parameters (right).

import { Canvas } from '../canvas/Canvas';
import { LeftRail } from '../panels/LeftRail';
import { RightRail } from '../panels/RightRail';
import { useSettings } from '../state/settings';
import { importPreviews, useSession } from '../state/session';
import { PreviewBuildStatus } from './PreviewBuildStatus';
import { Filmstrip } from './Filmstrip';
import { TopBar } from './TopBar';
import { AboutDialog, HostFailure, SettingsDialog } from './Dialogs';
import { ExportPage } from '../export/ExportPage';
import { PanelResize } from '../controls/PanelResize';

export function EditorWindow() {
  const left = useSettings((s) => s.leftCollapsed);
  const right = useSettings((s) => s.rightCollapsed);
  const strip = useSettings((s) => s.filmstripCollapsed);
  const batch = useSession((s) => s.batchExporting);
  return (
    <>
      <div
        className="editor"
        style={{ ['--left-col' as string]: left ? '0px' : 'var(--left-width)', ['--right-col' as string]: right ? '0px' : 'var(--right-width)', pointerEvents: batch ? 'none' : undefined }}
        data-testid="editor"
      >
        {left ? <div /> : <LeftRail />}
        <main className="centre" style={{ position: 'relative' }}>
          {!left && <PanelResize side="left" />}
          {!right && <PanelResize side="right" />}
          <TopBar />
          <Canvas />
          <PreviewBuildStatus queue={importPreviews} />
          {!strip && <Filmstrip />}
          <HostFailure />
        </main>
        {right ? <div /> : <RightRail />}
      </div>
      <SettingsDialog />
      <AboutDialog />
      <ExportPage />
    </>
  );
}
