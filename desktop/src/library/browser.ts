// browser.ts — the window's browser (PRD-W5 §2, R3; the Mac's `MacLibraryBrowser`,
// `MacDevelopBrowser`): one set of rows, one selection, in every mode.
//
// With a library open the rows are the library's own (its query, filter and
// sort; `libraryStore.images`) and the selection is the library's (`picked`,
// `focus`). With none open — a file opened from Explorer, a folder dragged in —
// the rows are that folder's frames (`sessionStore.frames`), as the filmstrip
// had them, and the selection is the session's (`picked`, `selection`).
//
// A row pressed in Develop or Edit opens that picture on the page: the editing
// session moves to it through the scheduler (`select`), and a library row the
// editor's roll does not hold yet brings the library's rows in first, as
// Develop ↵ does. ← → walk the rows. Export takes the chosen rows; with fewer
// than two, the open picture alone — one chosen is no batch (`MacDevelopExport`).

import { libraryStore, pick } from './store';
import { click, openPaths, select, sessionStore } from '../state/session';
import { uiStore } from '../app/ui';
import { baseName } from '../platform';

export interface BrowserRow {
  /** The library image's uuid, or the frame's path. */
  id: string;
  path: string;
  name: string;
  exists: boolean;
}

export type BrowserSource = 'library' | 'folder';

export function browserSource(): BrowserSource {
  return libraryStore.getState().source ? 'library' : 'folder';
}

export function browserRows(): BrowserRow[] {
  const lib = libraryStore.getState();
  if (lib.source) return lib.images.map((i) => ({ id: i.uuid, path: i.path, name: i.file_name, exists: i.exists !== false }));
  return sessionStore.getState().frames.map((f) => ({ id: f.path, path: f.path, name: f.name ?? baseName(f.path), exists: true }));
}

/** The rows chosen in the browser, in its order. */
export function chosenIds(): string[] {
  const lib = libraryStore.getState();
  if (lib.source) return lib.picked;
  const s = sessionStore.getState();
  return s.picked.length ? s.picked : s.selection ? [s.selection] : [];
}

/** The row the browser is on: the library's focus, or the open frame. */
export function focusId(): string | null {
  const lib = libraryStore.getState();
  return lib.source ? lib.focus : sessionStore.getState().selection;
}

/** Open a library row's picture on the editing page (the scheduler's editing session moves to it). */
export async function openOnPage(path: string) {
  const s = sessionStore.getState();
  if (s.frames.some((f) => f.path === path)) { click(path); return; }
  // The editor's roll is not the browser's rows yet: bring them in (Develop ↵'s path), then this one.
  const rows = browserRows().filter((r) => r.exists).map((r) => r.path);
  await openPaths(rows.includes(path) ? rows : [...rows, path]);
  if (sessionStore.getState().selection !== path) await select(path);
}

/** Open a row's picture on the page and leave the browser's selection as it is (a mode press). */
export async function openPicture(row: BrowserRow) {
  if (browserSource() === 'library') {
    const s = sessionStore.getState();
    if (s.frames.some((f) => f.path === row.path)) await select(row.path);
    else await openOnPage(row.path);
    return;
  }
  await select(row.path);
}

/** A press on a row: alone, Ctrl (toggle) or Shift (range). Alone in Develop or Edit it opens that picture. */
export async function pressRow(row: BrowserRow, mods: { ctrl?: boolean; shift?: boolean } = {}) {
  const editing = uiStore.getState().workspace !== 'library';
  if (browserSource() === 'library') {
    pick(row.id, mods);
    if (editing && !mods.ctrl && !mods.shift && row.exists) await openOnPage(row.path);
    return;
  }
  // The folder's frames: the filmstrip's rules (a press opens, Ctrl toggles one in the chosen set).
  click(row.path, !!mods.ctrl);
}

/** ← → on the browser's rows, in every mode. */
export async function stepRow(delta: number) {
  const rows = browserRows();
  if (!rows.length) return;
  const at = rows.findIndex((r) => r.id === focusId());
  const next = rows[Math.max(0, Math.min(rows.length - 1, (at < 0 ? (delta > 0 ? -1 : rows.length) : at) + delta))]!;
  if (at >= 0 && next.id === rows[at]!.id) return;
  await pressRow(next);
}

/**
 * What Export takes (`MacDevelopExport.ids`): the frames chosen in the browser, in its order;
 * with fewer than two, the open picture alone.
 */
export function exportPaths(current: string | null): string[] {
  const rows = browserRows();
  const chosen = new Set(chosenIds());
  const paths = rows.filter((r) => chosen.has(r.id) && r.exists).map((r) => r.path);
  return paths.length < 2 ? (current ? [current] : []) : paths;
}

/**
 * The picture a mode press opens (`MacLibraryPage.modePicture`): the browser's focus, else the
 * picture open already, else the first row.
 */
export function modePicture(): BrowserRow | null {
  const rows = browserRows().filter((r) => r.exists);
  const open = sessionStore.getState().selection;
  return rows.find((r) => r.id === focusId()) ?? rows.find((r) => r.path === open) ?? rows[0] ?? null;
}
