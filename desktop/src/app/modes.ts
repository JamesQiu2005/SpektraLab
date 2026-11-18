// modes.ts — the mode row's logic (PRD-W5 §2; the Mac's `MacModeSwitch` and
// `MainWindowLayout`): Library · Develop · Edit is one row for the whole
// window, and the mode is state, not a page.
//
// - Library is always there.
// - Develop and Edit open a picture: the one open already, or — pressed in the
//   Library — the browser's focus, else its first row (`MacLibraryPage.modePicture`).
//   With no picture to open they stand down and say why, in place (the owner,
//   2026-10-27: "say why in place, no silent no-op").

import { tz } from '../i18n';
import { sessionStore } from '../state/session';
import { setUi, setWorkspace, uiStore, type Workspace } from './ui';
import { browserRows, modePicture, openPicture } from '../library/browser';

export const MODES: Workspace[] = ['library', 'develop', 'edit'];

export function modeWords(m: Workspace): string {
  return m === 'library' ? tz('Library', '图库') : m === 'develop' ? tz('Develop', '冲洗') : tz('Edit', '编辑');
}

/** Why a mode cannot be entered now, or null. */
export function modeUnavailable(m: Workspace): string | null {
  if (m === 'library') return null;
  if (sessionStore.getState().selection) return null;
  if (browserRows().some((r) => r.exists)) return null;
  return tz('Open a picture first: File › Open (Ctrl+O), or add a folder in the Library.', '请先打开照片：文件 › 打开（Ctrl+O），或在图库中添加文件夹。');
}

/** The mode row pressed (or Go › Library / Develop / Edit). */
export async function chooseMode(m: Workspace): Promise<void> {
  const why = modeUnavailable(m);
  if (why) { setUi({ modeNote: why }); return; }
  const from = uiStore.getState().workspace;
  setWorkspace(m);
  if (m === 'library' || from !== 'library') return;
  // From the Library: the browser's focus (or first row) is the picture the page opens, unless it is open
  // already; the browser's chosen rows stay chosen.
  const row = modePicture();
  if (row && row.path !== sessionStore.getState().selection) await openPicture(row);
}
