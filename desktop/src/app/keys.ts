// keys.ts — the v2 window's keyboard (README §6.2, board_keys.svg).
//
// The menu bar is the app's own (in the title bar), so every chord lands
// here, in the webview: `KEY_COMMANDS` runs the menu's command, and the v1
// table (windows/keys.ts) keeps the single keys it already had (V, H, ←, →,
// `,`, Delete). The typing guard of trap 32 stays first: a focused text field
// takes characters, arrows and Delete, and Ctrl+A/C/V/X/Z/Y.
//
// Windows' own keys are left alone (Win+…, Alt+Tab, Alt+F4 is File › Exit,
// Ctrl+Space for the IME). Alt pressed and released alone shows the menu
// bar's access keys, as F10 does.

import { chord, isEditable, isTypingKey, shortcutTable } from '../windows/keys';
import { KEY_COMMANDS, developFromLibrary, runCommand } from './commands';
import { escapeUi, openMenu, setUi, uiStore } from './ui';
import { sessionStore, setOriginal, setPages, setTool, zoomTo, zoomToFit } from '../state/session';
import { libraryStore, pick, setRating } from '../library/store';

const TEXT_KEYS = ['ctrl+a', 'ctrl+c', 'ctrl+v', 'ctrl+x', 'ctrl+z', 'ctrl+shift+z', 'ctrl+y', 'ctrl+shift+v'];

export function installV2Keys(): () => void {
  const v1 = shortcutTable();
  let altAlone = false;
  let held: string | null = null;
  const onDown = (e: KeyboardEvent) => {
    altAlone = e.key === 'Alt' && !e.ctrlKey && !e.shiftKey && !e.metaKey;
    if (isTypingKey(e)) return;
    const c = chord(e);
    const s = sessionStore.getState();
    const u = uiStore.getState();
    // A field keeps its own editing chords (Ctrl+Shift+V is "paste as plain text" there).
    if (isEditable(e.target) && TEXT_KEYS.includes(c)) return;
    if (c === 'escape') {
      e.preventDefault();
      if (escapeUi()) return;
      if (u.fullScreen) { void runCommand('fullScreen'); return; }
      v1.escape?.();
      return;
    }
    if (c === 'f10') { e.preventDefault(); setUi({ accessKeys: true }); openMenu('file'); return; }
    // Pages over the window (Settings, Export, About) take only their own keys.
    if ((s.exportOpen || s.settingsOpen || s.aboutOpen) && !c.startsWith('ctrl+')) return;
    if (s.batchExporting && !['f11', 'f7', 'f8', 'ctrl+b', 'ctrl+shift+f', 'ctrl+0', 'ctrl+1', 'ctrl+=', 'ctrl+-'].includes(c)) return;
    if (e.repeat && (c === 'delete' || c === ' ' || c === '\\')) { e.preventDefault(); return; }
    // Held keys: Space or \ shows the Original until release (README §6.2).
    if ((c === ' ' || c === '\\') && u.workspace === 'edit' && s.selection) {
      e.preventDefault(); held = c; setOriginal(true); return;
    }
    if (u.workspace === 'library') {
      const lib = libraryStore.getState();
      if (c === 'enter') { e.preventDefault(); void developFromLibrary(); return; }
      if (/^[0-5]$/.test(c)) { e.preventDefault(); void setRating(Number(c) || null); return; }
      if ((c === 'arrowleft' || c === 'arrowright') && lib.images.length) {
        e.preventDefault();
        const i = Math.max(0, lib.images.findIndex((x) => x.uuid === lib.focus));
        const next = lib.images[Math.max(0, Math.min(lib.images.length - 1, i + (c === 'arrowright' ? 1 : -1)))]!;
        pick(next.uuid);
        return;
      }
    } else {
      if (c === 'z' && s.selection) { e.preventDefault(); if (s.view.fit) zoomTo(1); else zoomToFit(); return; }
      if (c === 'enter' && s.tool === 'crop') { e.preventDefault(); setTool('select'); return; }
    }
    const id = KEY_COMMANDS[c];
    if (id) { e.preventDefault(); runCommand(id); return; }
    const a = v1[c];
    if (a && !['ctrl+q', 'ctrl+j', 'ctrl+alt+r'].includes(c)) { e.preventDefault(); a(); }
  };
  const onUp = (e: KeyboardEvent) => {
    if (e.key === 'Alt' && altAlone) { e.preventDefault(); setUi({ accessKeys: !uiStore.getState().accessKeys }); }
    altAlone = false;
    if (held && (e.key === ' ' || e.key === '\\')) { held = null; if (!uiStore.getState().originalLatched) setOriginal(false); }
  };
  window.addEventListener('keydown', onDown);
  window.addEventListener('keyup', onUp);
  return () => { window.removeEventListener('keydown', onDown); window.removeEventListener('keyup', onUp); };
}

export { setPages };
