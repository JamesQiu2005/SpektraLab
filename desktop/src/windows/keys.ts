// keys.ts — the window's keyboard: Ctrl shortcuts (the menu's accelerators
// also land here in the browser build) and Capture One's single-key ones.
//
// AGENTS.md trap 32 / ARCHITECTURE §7.10: a single-key shortcut must never
// fire while a text field has focus. The single keys are therefore not menu
// accelerators at all (a GTK or Win32 accelerator would take the key before
// the field); they are handled here, behind `isTypingKey`, which hands
// characters, arrows and delete to a focused editable element. Ctrl/Alt
// combinations and Return/Enter/Esc/Tab are not typing keys.

import { setGeometry, selectRelative, setOriginal, setTool, toggleCompare, undo, redo, zoomStep, zoomTo, zoomToFit, currentFitZoom, copySettings, pasteSettings, selectAllFrames, sessionStore, setPages } from '../state/session';
import { turned } from '@shared/geometry';
import { openDialog, openExport, restartHost } from './actions';
import { settingsStore } from '../state/settings';
import { platform } from '../platform';

export interface KeyLike {
  key: string;
  ctrlKey: boolean;
  metaKey: boolean;
  altKey: boolean;
  shiftKey: boolean;
  target: EventTarget | null;
}

export function isEditable(t: EventTarget | null): boolean {
  const el = t as HTMLElement | null;
  if (!el || typeof el.tagName !== 'string') return false;
  if (el.isContentEditable) return true;
  if (el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') return true;
  if (el.tagName === 'INPUT') {
    const type = ((el as HTMLInputElement).type || 'text').toLowerCase();
    return !['checkbox', 'radio', 'button', 'range', 'submit', 'reset', 'color', 'file'].includes(type);
  }
  return false;
}

/** The guard: true when the key belongs to a focused text field. */
export function isTypingKey(e: KeyLike): boolean {
  if (!isEditable(e.target)) return false;
  if (e.ctrlKey || e.metaKey) return false;
  if (['Enter', 'Escape', 'Tab'].includes(e.key)) return false;
  return true;
}

type Action = () => void;

/** The shortcut table. Keys are `[ctrl+][alt+][shift+]<key>` with `key` lower-cased. */
export function shortcutTable(): Record<string, Action> {
  const geo = (fn: Parameters<typeof setGeometry>[0]) => () => setGeometry(fn);
  return {
    // Ctrl (Cmd on a Mac keyboard) — also menu accelerators in the app.
    'ctrl+o': () => void openDialog(),
    'ctrl+e': openExport,
    'ctrl+z': undo,
    'ctrl+shift+z': redo,
    'ctrl+y': redo,
    'ctrl+shift+c': copySettings,
    'ctrl+shift+v': () => void pasteSettings(),
    'ctrl+a': selectAllFrames,
    'ctrl+=': () => zoomStep(1, currentFitZoom),
    'ctrl++': () => zoomStep(1, currentFitZoom),
    'ctrl+-': () => zoomStep(-1, currentFitZoom),
    'ctrl+0': zoomToFit,
    'ctrl+b': () => {
      const s = settingsStore.getState();
      const c = !(s.leftCollapsed && s.rightCollapsed);
      s.set('leftCollapsed', c);
      s.set('rightCollapsed', c);
    },
    'ctrl+shift+f': () => settingsStore.getState().set('filmstripCollapsed', !settingsStore.getState().filmstripCollapsed),
    'ctrl+shift+b': () => {
      const s = sessionStore.getState();
      sessionStore.setState({ sidecar: { ...s.sidecar, adjustments: { ...s.sidecar.adjustments, enabled: !s.sidecar.adjustments.enabled } } });
    },
    'ctrl+alt+[': geo((g) => turned(g, -1)),
    'ctrl+alt+]': geo((g) => turned(g, 1)),
    'ctrl+alt+r': () => void restartHost(),
    'ctrl+,': () => setPages({ settingsOpen: true }),
    f11: () => void platform().toggleFullscreen(),
    // Capture One's single keys.
    v: () => setTool('select'),
    h: () => setTool('hand'),
    c: () => setTool(sessionStore.getState().tool === 'crop' ? 'select' : 'crop'),
    y: toggleCompare,
    ',': zoomToFit,
    '.': () => zoomTo(1),
    arrowleft: () => selectRelative(-1),
    arrowright: () => selectRelative(1),
    escape: () => {
      const s = sessionStore.getState();
      if (s.exportOpen && !s.batchExporting) setPages({ exportOpen: false });
      else if (s.settingsOpen) setPages({ settingsOpen: false });
      else if (s.aboutOpen) setPages({ aboutOpen: false });
      else if (s.tool === 'crop') setTool('select');
      else setOriginal(false);
    },
  };
}

export function chord(e: KeyLike): string {
  const k = e.key.length === 1 ? e.key.toLowerCase() : e.key.toLowerCase();
  return (e.ctrlKey || e.metaKey ? 'ctrl+' : '') + (e.altKey ? 'alt+' : '') + (e.shiftKey && k.length > 1 ? 'shift+' : e.shiftKey && /[a-z]/.test(k) ? 'shift+' : '') + k;
}

export function installKeys(menuOwns: Set<string> = new Set()): () => void {
  const table = shortcutTable();
  const onKey = (e: KeyboardEvent) => {
    if (isTypingKey(e)) return;
    // The native menu's accelerators: the menu runs them, not this handler.
    if (menuOwns.has(chord(e))) return;
    // Pages over the editor take only their own keys (and Escape).
    const s = sessionStore.getState();
    const c = chord(e);
    if ((s.exportOpen || s.settingsOpen || s.aboutOpen) && c !== 'escape' && !c.startsWith('ctrl+')) return;
    const a = table[c];
    if (a) {
      e.preventDefault();
      a();
    }
  };
  window.addEventListener('keydown', onKey);
  return () => window.removeEventListener('keydown', onKey);
}
