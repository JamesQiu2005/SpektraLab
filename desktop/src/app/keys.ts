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
import { KEY_COMMANDS, developFromLibrary, menuBar, runCommand } from './commands';
import { escapeUi, openMenu, setUi, uiStore } from './ui';
import { sessionStore, setOriginal, setPages, setTool, zoomTo, zoomToFit } from '../state/session';
import { libraryStore, setLibrary, setRating } from '../library/store';
import { stepRow } from '../library/browser';
import { platform } from '../platform';

const TEXT_KEYS = ['ctrl+a', 'ctrl+c', 'ctrl+v', 'ctrl+x', 'ctrl+z', 'ctrl+shift+z', 'ctrl+y', 'ctrl+shift+v'];

export function installV2Keys(): () => void {
  const v1 = shortcutTable();
  let altAlone = false;
  let held: string | null = null;
  const onDown = (e: KeyboardEvent) => {
    altAlone = e.key === 'Alt' && !e.ctrlKey && !e.shiftKey && !e.metaKey;
    const c = chord(e);
    // SpektraLab exports photos; WebView2's Print would print the editor itself.
    if (c === 'ctrl+p') { e.preventDefault(); return; }
    const u = uiStore.getState();
    // Alt+letter opens the matching menu directly, including from a text field.
    const access = /^alt\+([a-z])$/.exec(c)?.[1];
    if (access) {
      const menu = menuBar().find((item) => item.access.toLowerCase() === access);
      if (menu) {
        e.preventDefault();
        setUi({ accessKeys: false });
        openMenu(menu.id);
        return;
      }
    }
    // F5 belongs to the Library, including when its search field has focus.
    if (c === 'f5') e.preventDefault();
    else if (isTypingKey(e)) return;
    // A field keeps its own editing chords (Ctrl+Shift+V is "paste as plain text" there).
    if (isEditable(e.target) && TEXT_KEYS.includes(c)) return;
    // After Alt or F10, a bare menu letter also opens it.
    if (u.accessKeys && /^[a-z]$/.test(c)) {
      const menu = menuBar().find((item) => item.access.toLowerCase() === c);
      e.preventDefault();
      setUi({ accessKeys: false });
      if (menu) openMenu(menu.id);
      return;
    }
    const s = sessionStore.getState();
    if (c === 'escape') {
      e.preventDefault();
      if (escapeUi()) return;
      if (libraryStore.getState().sourceMenu) { setLibrary({ sourceMenu: false }); return; }
      if (u.fullScreen) { void runCommand('fullScreen'); return; }
      v1.escape?.();
      return;
    }
    if (c === 'f10') { e.preventDefault(); setUi({ accessKeys: true }); openMenu('file'); return; }
    // Pages over the window (Settings, Export, About) take only their own keys.
    if ((s.exportOpen || s.settingsOpen || s.aboutOpen) && !c.startsWith('ctrl+')) return;
    if (s.batchExporting && !['f11', 'f7', 'f8', 'ctrl+b', 'ctrl+alt+v', 'ctrl+0', 'ctrl+1', 'ctrl+=', 'ctrl+-'].includes(c)) return;
    if (e.repeat && (c === 'delete' || c === ' ' || c === '\\')) { e.preventDefault(); return; }
    // Held keys: Space or \ shows the Original until release (README §6.2).
    if ((c === ' ' || c === '\\') && u.workspace !== 'library' && s.selection) {
      e.preventDefault(); held = c; setOriginal(true); return;
    }
    // ← → walk the browser's rows in every mode (PRD-W5 §2): in Develop and Edit the picture follows.
    if (c === 'arrowleft' || c === 'arrowright') { e.preventDefault(); void stepRow(c === 'arrowright' ? 1 : -1); return; }
    if (u.workspace === 'library') {
      if (c === 'enter') { e.preventDefault(); void developFromLibrary(); return; }
      if (/^[0-5]$/.test(c)) { e.preventDefault(); void setRating(Number(c) || null); return; }
    } else {
      if (c === 'z' && s.selection) { e.preventDefault(); if (s.view.fit) zoomTo(1); else zoomToFit(); return; }
      if (c === 'enter' && s.tool === 'crop') { e.preventDefault(); setTool('select'); return; }
    }
    const id = KEY_COMMANDS[c];
    if (id) { e.preventDefault(); runCommand(id); return; }
    const a = v1[c];
    if (a && !['ctrl+q', 'ctrl+j', 'ctrl+alt+r'].includes(c)) { e.preventDefault(); a(); }
  };
  const releaseOriginal = () => {
    if (!held) return;
    held = null;
    if (!uiStore.getState().originalLatched) setOriginal(false);
  };
  const onUp = (e: KeyboardEvent) => {
    if (e.key === 'Alt' && altAlone) { e.preventDefault(); setUi({ accessKeys: !uiStore.getState().accessKeys }); }
    altAlone = false;
    if (e.key === ' ' || e.key === '\\') releaseOriginal();
  };
  const onBlur = () => {
    // The next focused window can receive the keyup.
    altAlone = false;
    releaseOriginal();
  };
  window.addEventListener('keydown', onDown);
  window.addEventListener('keyup', onUp);
  const unlistenBlur = platform().onWindowBlur(onBlur);
  return () => {
    window.removeEventListener('keydown', onDown);
    window.removeEventListener('keyup', onUp);
    unlistenBlur();
    releaseOriginal();
  };
}

export { setPages };
