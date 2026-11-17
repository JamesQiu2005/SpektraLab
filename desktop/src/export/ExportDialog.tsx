// ExportDialog.tsx — Export as a ContentDialog (README §6.6, PC-O1): 800 ×
// 560 over a smoke layer, the proof at the left, the recipe at the right,
// Export at the left of the buttons and Cancel at the right; Enter exports,
// Esc cancels. It is v1's export page (recipes, naming, the host's proof and
// export_frame) laid out as the dialog, so every rule the page had — the
// frozen batch, never overwriting, the refused colour spaces — still holds.
//
// While a batch runs (PC-O2) the dialog steps aside: the toolbar's Export
// wears a ring and the count, and its flyout has the file in hand, the bar of
// done frames, and Stop after this frame. The editor is look-only meanwhile.

import { useEffect, useRef } from 'react';
import { useStore } from 'zustand';
import { tz } from '../i18n';
import { ExportPage, exportRun, progressPercent } from './ExportPage';
import { setPages, useSession } from '../state/session';
import { setUi, useUi } from '../app/ui';

export function ExportDialog() {
  const open = useSession((s) => s.exportOpen);
  const batch = useSession((s) => s.batchExporting);
  const was = useRef(false);
  // The batch ended: the dialog closes (the status line says what was written).
  useEffect(() => {
    if (was.current && !batch) { setPages({ exportOpen: false }); setUi({ exportFlyout: false }); }
    was.current = batch;
  }, [batch]);
  if (!open) return null;
  return (
    <div className={'v2-smoke' + (batch ? ' away' : '')} data-testid="export-dialog"
      onKeyDown={(e) => {
        if (e.key === 'Enter' && !batch && !(e.target as HTMLElement).matches('input, textarea, select')) {
          (document.querySelector('[data-testid="export-run"]') as HTMLButtonElement | null)?.click();
        }
      }}>
      <div className="v2-content-dialog" role="dialog" aria-modal="true" aria-label={tz('Export', '导出')}>
        <ExportPage v2 />
      </div>
    </div>
  );
}

/** The toolbar's Export while a batch runs: a ring and the count. */
export function useExportRun() {
  return useStore(exportRun, (s) => s);
}

export function ExportingFlyout() {
  const run = useExportRun();
  const open = useUi((u) => u.exportFlyout);
  const batch = useSession((s) => s.batchExporting);
  if (!open || !batch || !run.progress) return null;
  const p = run.progress;
  return (
    <div className="v2-flyout export" data-testid="exporting-flyout" role="dialog" aria-label={tz('Exporting', '正在导出')}>
      <b>{tz(`Exporting ${Math.min(p.done + 1, p.total)} of ${p.total}`, `正在导出 ${Math.min(p.done + 1, p.total)} / ${p.total}`)}</b>
      {run.file && <span className="dim">{run.file}</span>}
      <div className="v2-bar" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={progressPercent(p)}><i style={{ width: `${progressPercent(p)}%` }} /></div>
      <button className="v2-button" data-testid="stop-after-frame" disabled={!run.stop} onClick={() => run.stop?.()}>{tz('Stop after this frame', '完成这张后停止')}</button>
    </div>
  );
}
