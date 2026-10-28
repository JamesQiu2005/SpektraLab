import { useSyncExternalStore } from 'react';
import { useI18n } from '../i18n';
import type { PreviewQueue } from '../state/previewQueue';
import './previewBuildStatus.css';

/** Camera previews are a browsing aid, never the processed film or export. */
export function PreviewBuildStatus({ queue }: { queue: PreviewQueue }) {
  const state = useSyncExternalStore(queue.subscribe, queue.getSnapshot, queue.getSnapshot);
  const { tz } = useI18n();
  if (state.total === 0) return null;
  const finished = !state.current && state.completed + state.failed + state.skipped === state.total;
  const heading = finished
    ? tz('Camera preview preparation complete', '相机预览准备完成')
    : state.paused
      ? tz('Camera previews paused', '相机预览已暂停')
      : state.foregroundBusy
        ? tz('Camera previews waiting for editing', '相机预览等待编辑完成')
        : tz('Preparing camera previews', '正在准备相机预览');
  return (
    <div
      className="preview-build-status"
      data-testid="preview-build-status"
      title={tz('Camera previews appear while film effects load. Finished previews keep their film effects.', '加载胶片效果期间先显示相机预览，已有胶片预览会保留其效果。')}
    >
      <span className="preview-build-summary" role="status" aria-live="polite">
        {heading} · {tz('Prepared', '已准备')} {state.completed}/{state.total}
        {state.skipped > 0 && ` · ${state.skipped} ${tz('not cached', '张未缓存')}`}
        {state.failed > 0 && ` · ${state.failed} ${tz('could not be generated', '张未能生成')}`}
      </span>
      {!finished && <div className="preview-build-actions">
        <button type="button" onClick={() => queue.setPaused(!state.paused)}>
          {state.paused ? tz('Resume', '继续') : tz('Pause', '暂停')}
        </button>
        <button type="button" onClick={() => queue.cancel()}>{tz('Cancel', '取消')}</button>
      </div>}
    </div>
  );
}
