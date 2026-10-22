// Tauri's native Windows file-drop handler consumes HTML5 drag/drop. Keep
// that handler for Explorer imports and use pointer gestures for our own
// thumbnails, which never need to leave this window.
export const FRAME_DROP = 'spektralab-frame-drop';
export interface FrameDrop { path: string; clientX: number; clientY: number }

export function onFrameDrop(element: HTMLElement, receive: (drop: FrameDrop) => boolean): () => void {
  const listener = (event: Event) => {
    const e = event as CustomEvent<FrameDrop>;
    if (receive(e.detail)) { e.preventDefault(); e.stopPropagation(); }
  };
  element.addEventListener(FRAME_DROP, listener);
  return () => element.removeEventListener(FRAME_DROP, listener);
}

export function installFrameDrag(strip: HTMLElement, callbacks: {
  enabled: () => boolean;
  reorder: (path: string, target: string) => void;
  save: () => void;
}): () => void {
  let gesture: { id: number; path: string; x: number; y: number; active: boolean } | null = null;
  let suppressClick = false;
  let resetClick: ReturnType<typeof setTimeout> | undefined;
  const hit = (target: EventTarget | null) => target instanceof Element ? target.closest<HTMLElement>('.thumb[data-path]') : null;
  const reset = () => {
    const old = gesture; gesture = null;
    strip.style.cursor = '';
    if (old && strip.hasPointerCapture?.(old.id)) strip.releasePointerCapture(old.id);
    clearTimeout(resetClick);
    // A completed drag can still generate a click in WebView2. Suppress that
    // one dispatch, but never eat a later intentional selection.
    resetClick = setTimeout(() => { suppressClick = false; }, 0);
  };
  const down = (e: PointerEvent) => {
    if (e.button !== 0 || !callbacks.enabled()) return;
    const thumb = hit(e.target);
    if (!thumb || !strip.contains(thumb)) return;
    gesture = { id: e.pointerId, path: thumb.dataset.path!, x: e.clientX, y: e.clientY, active: false };
  };
  const move = (e: PointerEvent) => {
    const g = gesture;
    if (!g || g.id !== e.pointerId) return;
    if (!callbacks.enabled()) { reset(); return; }
    if (!g.active && Math.hypot(e.clientX - g.x, e.clientY - g.y) >= 6) {
      g.active = true; suppressClick = true;
      strip.setPointerCapture?.(e.pointerId);
      strip.style.cursor = 'grabbing';
    }
    if (g.active) e.preventDefault();
  };
  const up = (e: PointerEvent) => {
    const g = gesture;
    if (!g || g.id !== e.pointerId) return;
    if (g.active && callbacks.enabled()) {
      e.preventDefault();
      // Hit-test the release position rather than the captured event target.
      // Canvas listeners read the current geometry, including zoom and crop.
      const target = document.elementFromPoint(e.clientX, e.clientY);
      const consumed = target && !target.dispatchEvent(new CustomEvent<FrameDrop>(FRAME_DROP, {
        bubbles: true, cancelable: true, detail: { path: g.path, clientX: e.clientX, clientY: e.clientY },
      }));
      const thumb = hit(target);
      if (!consumed && thumb && strip.contains(thumb) && thumb.dataset.path !== g.path) {
        callbacks.reorder(g.path, thumb.dataset.path!); callbacks.save();
      }
    }
    reset();
  };
  const cancel = () => reset();
  const key = (e: KeyboardEvent) => { if (e.key === 'Escape') reset(); };
  const click = (e: MouseEvent) => {
    if (suppressClick) { e.preventDefault(); e.stopImmediatePropagation(); suppressClick = false; }
  };
  const nativeDrag = (e: DragEvent) => e.preventDefault();
  strip.addEventListener('pointerdown', down);
  strip.addEventListener('click', click, true);
  strip.addEventListener('dragstart', nativeDrag);
  window.addEventListener('pointermove', move, { passive: false });
  window.addEventListener('pointerup', up);
  window.addEventListener('pointercancel', cancel);
  window.addEventListener('blur', cancel);
  window.addEventListener('keydown', key);
  return () => {
    reset(); clearTimeout(resetClick); suppressClick = false;
    strip.removeEventListener('pointerdown', down);
    strip.removeEventListener('click', click, true);
    strip.removeEventListener('dragstart', nativeDrag);
    window.removeEventListener('pointermove', move);
    window.removeEventListener('pointerup', up);
    window.removeEventListener('pointercancel', cancel);
    window.removeEventListener('blur', cancel);
    window.removeEventListener('keydown', key);
  };
}
