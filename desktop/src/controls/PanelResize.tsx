import { useRef } from 'react';
import { PANEL_WIDTHS, settingsStore, useSettings } from '../state/settings';
import { tz } from '../i18n';

export function PanelResize({ side }: { side: 'left' | 'right' }) {
  const key = side === 'left' ? 'leftWidth' : 'rightWidth';
  const width = useSettings((s) => s[key]);
  const drag = useRef<{ x: number; width: number } | null>(null);
  const [lo, standard, hi] = PANEL_WIDTHS[key];
  return <div className={`panel-resize ${side}`} role="separator" tabIndex={0} aria-orientation="vertical"
    aria-label={tz(`Resize ${side} panel`, side === 'left' ? '调整左侧栏宽度' : '调整右侧栏宽度')}
    aria-valuemin={lo} aria-valuemax={hi} aria-valuenow={width}
    onPointerDown={(e) => {
      if (e.button !== 0) return;
      e.preventDefault(); e.stopPropagation(); e.currentTarget.setPointerCapture?.(e.pointerId);
      drag.current = { x: e.clientX, width };
    }}
    onPointerMove={(e) => {
      if (!drag.current) return;
      settingsStore.getState().set(key, drag.current.width + (e.clientX - drag.current.x) * (side === 'left' ? 1 : -1));
    }}
    onPointerUp={() => { drag.current = null; }} onPointerCancel={() => { drag.current = null; }}
    onDoubleClick={() => settingsStore.getState().set(key, standard)}
    onKeyDown={(e) => {
      if (!['ArrowLeft', 'ArrowRight', 'Home'].includes(e.key)) return;
      e.preventDefault(); e.stopPropagation();
      settingsStore.getState().set(key, e.key === 'Home' ? standard : width
        + (e.key === 'ArrowRight' ? 10 : -10) * (side === 'left' ? 1 : -1));
    }} />;
}
