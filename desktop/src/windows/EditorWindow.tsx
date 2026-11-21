// EditorWindow.tsx — three regions and a filmstrip (ARCHITECTURE §7.1):
// Film and Print (left) | top bar + canvas + filmstrip | Parameters (right). Narrow screens: CompactEditor.

import { Canvas } from '../canvas/Canvas';
import { LeftRail } from '../panels/LeftRail';
import { RightRail } from '../panels/RightRail';
import { useSettings } from '../state/settings';
import { useSession } from '../state/session';
import { Filmstrip } from './Filmstrip';
import { TopBar } from './TopBar';
import { AboutDialog, HostFailure, SettingsDialog } from './Dialogs';
import { LayoutPage } from './LayoutPage';
import { ExportPage } from '../export/ExportPage';
import { CompactEditor, useCompact } from './CompactEditor';

export function EditorWindow() {
  const left = useSettings((s) => s.leftCollapsed);
  const right = useSettings((s) => s.rightCollapsed);
  const strip = useSettings((s) => s.filmstripCollapsed);
  const batch = useSession((s) => s.batchExporting);
  // A narrow screen (a phone, the Fold folded) gets the one-thumb editor; the same controls, rearranged.
  const compact = useCompact();
  if (compact) {
    return (
      <>
        <CompactEditor />
        <SettingsDialog />
        <AboutDialog />
        <ExportPage />
        <LayoutPage />
      </>
    );
  }
  return (
    <>
      <div
        className="editor"
        style={{ ['--left-col' as string]: left ? '0px' : 'var(--left-width)', ['--right-col' as string]: right ? '0px' : 'var(--right-width)', pointerEvents: batch ? 'none' : undefined }}
        data-testid="editor"
      >
        {left ? <div /> : <LeftRail />}
        <main className="centre" style={{ position: 'relative' }}>
          <TopBar />
          <Canvas />
          {!strip && <Filmstrip />}
          <HostFailure />
        </main>
        {right ? <div /> : <RightRail />}
      </div>
      <SettingsDialog />
      <AboutDialog />
      <ExportPage />
      <LayoutPage />
    </>
  );
}
