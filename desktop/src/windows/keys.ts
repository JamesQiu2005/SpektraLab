// keys.ts — the window's keyboard: Ctrl shortcuts (the menu's accelerators
// also land here in the browser build) and Capture One's single-key ones.
//
// AGENTS.md trap 32 / ARCHITECTURE §7.10: a single-key shortcut must never
// fire while a text field has focus. The single keys are therefore not menu
// accelerators at all (a GTK or Win32 accelerator would take the key before
// the field); they are handled here, behind `isTypingKey`, which hands
// characters, arrows and delete to a focused editable element. Ctrl/Alt
// combinations and Return/Enter/Esc/Tab are not typing keys.

import { setGeometry, selectRelative, setOriginal, setTool, toggleCompare, undo, redo, zoomStep, zoomTo, zoomToFit, currentFitZoom, copySettings, pasteSettings, selectAllFrames, sessionStore, setPages, createPair,setAdjustments,endPairPlacing } from '../state/session';
import { turned } from '@shared/geometry';
import { openDialog, openExport, restartHost } from './actions';
import { settingsStore } from '../state/settings';
import { platform } from '../platform';

export interface KeyLike {
  key: string;
  code?: string;
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
    'ctrl+j':()=>void createPair(),
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
      setAdjustments(a=>({...a,enabled:!a.enabled}));
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
    enter:()=>{if(sessionStore.getState().pairPlacing)endPairPlacing();},
    escape: () => {
      const s = sessionStore.getState();
      if (s.exportOpen && !s.batchExporting) setPages({ exportOpen: false });
      else if (s.settingsOpen) setPages({ settingsOpen: false });
      else if (s.aboutOpen) setPages({ aboutOpen: false });
      else if(s.pairPlacing)endPairPlacing();
      else if (s.tool === 'crop') setTool('select');
      else setOriginal(false);
    },
  };
}

export function chord(e: KeyLike): string {
  // Windows IMEs report Process/229 for physical letters even when a canvas
  // (not a text editor) owns focus. Keep photo shortcuts usable in that mode;
  // composition in an editable field still belongs entirely to the field.
  const physical=!isEditable(e.target)&&['Process','Unidentified'].includes(e.key)&&/^Key[A-Z]$/.test(e.code??'');
  const k = physical ? e.code!.slice(3).toLowerCase() : e.key.toLowerCase();
  return (e.ctrlKey || e.metaKey ? 'ctrl+' : '') + (e.altKey ? 'alt+' : '') + (e.shiftKey && k.length > 1 ? 'shift+' : e.shiftKey && /[a-z]/.test(k) ? 'shift+' : '') + k;
}

/** Whether this event can be left to the platform's native menu. */
export function nativeMenuOwnsKey(e:KeyLike,menuOwns:Set<string>,userAgent:string):boolean {
  // WebView2 can deliver Ctrl keydowns without forwarding them to the Win32
  // menu. An accelerator consumed before the webview never reaches this
  // handler, so handle delivered Windows events here instead of dropping them.
  return !/Windows/i.test(userAgent)&&menuOwns.has(chord(e));
}

export function installKeys(menuOwns: Set<string> = new Set()): () => void {
  const table = shortcutTable();
  const onKey = (e: KeyboardEvent) => {
    if (isTypingKey(e)) return;
    // The native menu's accelerators: the menu runs them, not this handler.
    if (nativeMenuOwnsKey(e,menuOwns,navigator.userAgent)) return;
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
