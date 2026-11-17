// ui.ts — what the v2 window is showing, apart from the photograph's state
// (state/session.ts) and the persisted settings (state/settings.ts).
//
// The workspace switch (Library | Edit, README §4 and Mac HIG §4.1) changes
// only what is on screen: the open frame, its edits, the scheduler's jobs and
// the library's selection all stay where they are, so going to the Library
// and back is free. That is why none of the session lives here.

import { createStore } from 'zustand/vanilla';
import { useStore } from 'zustand';
import type { RailSide } from './layout';

export type Workspace = 'library' | 'edit';
/** The Library's centre: the grid, the light table, a contact sheet. */
export type LibraryView = 'grid' | 'lightTable' | 'contactSheet';
export type AdjustTile = 'brightness' | 'contrast' | 'tone' | 'hsl' | 'channels' | 'wheels' | 'vibrance' | 'saturation' | 'temperature' | 'curve' | 'vignette';
export type DarkroomTile = 'enlarger' | 'decode' | 'effects';
export type MenuId = 'file' | 'edit' | 'view' | 'frame' | 'go' | 'help';

export interface UiState {
  workspace: Workspace;
  /** The workspace before the last switch (Go › Back, Alt+←). */
  previous: Workspace | null;
  libraryView: LibraryView;
  lightTableActual: boolean;
  /** A rail folded by width and brought over the picture (F7/F8). */
  overlay: RailSide | null;
  fullScreen: boolean;
  /** The title bar's menu that is open, and whether Alt is showing access keys. */
  menu: MenuId | null;
  accessKeys: boolean;
  /** The toolbar's ··· and the picture's right-click flyout. */
  moreOpen: boolean;
  pictureMenu: { x: number; y: number } | null;
  copySettingsOpen: boolean;
  /** Export's flyout over the toolbar's ring while a batch runs. */
  exportFlyout: boolean;
  /** Edit's open tiles: one Adjust tile, one Darkroom tile at a time. */
  adjustTile: AdjustTile | null;
  darkroomTile: DarkroomTile | null;
  /** The Original latched by a short click on the toolbar's Original. */
  originalLatched: boolean;
  /** The window's own size in epx (the layout rule reads it). */
  window: { width: number; height: number };
  maximized: boolean;
}

export const UI_INITIAL: UiState = {
  workspace: 'edit',
  previous: null,
  libraryView: 'grid',
  lightTableActual: false,
  overlay: null,
  fullScreen: false,
  menu: null,
  accessKeys: false,
  moreOpen: false,
  pictureMenu: null,
  copySettingsOpen: false,
  exportFlyout: false,
  adjustTile: 'tone',
  darkroomTile: null,
  originalLatched: false,
  window: { width: typeof window !== 'undefined' ? window.innerWidth : 1536, height: typeof window !== 'undefined' ? window.innerHeight : 816 },
  maximized: false,
};

export const uiStore = createStore<UiState>(() => UI_INITIAL);
export const useUi = <T>(sel: (s: UiState) => T): T => useStore(uiStore, sel);
const set = (p: Partial<UiState>) => uiStore.setState(p);
const get = () => uiStore.getState();

export function setWorkspace(w: Workspace) {
  const s = get();
  if (s.workspace === w) return;
  set({ workspace: w, previous: s.workspace, overlay: null, menu: null, moreOpen: false, pictureMenu: null, copySettingsOpen: false });
}
export function goBack() {
  const p = get().previous;
  if (p) setWorkspace(p);
}
export function setLibraryView(v: LibraryView) {
  set({ libraryView: v, workspace: 'library', previous: get().workspace === 'library' ? get().previous : get().workspace });
}
export function setOverlay(overlay: RailSide | null) { set({ overlay }); }
export function openMenu(menu: MenuId | null) { set({ menu, moreOpen: false, pictureMenu: null }); }
export function setUi(p: Partial<UiState>) { set(p); }
export function toggleAdjustTile(t: AdjustTile) { set({ adjustTile: get().adjustTile === t ? null : t }); }
export function toggleDarkroomTile(t: DarkroomTile) { set({ darkroomTile: get().darkroomTile === t ? null : t }); }
/** Esc's order (README §6.2): the open flyout or menu, then the open tile. Returns whether it closed something. */
export function escapeUi(): boolean {
  const s = get();
  if (s.menu || s.moreOpen || s.pictureMenu || s.copySettingsOpen || s.exportFlyout) {
    set({ menu: null, moreOpen: false, pictureMenu: null, copySettingsOpen: false, exportFlyout: false, accessKeys: false });
    return true;
  }
  if (s.overlay) { set({ overlay: null }); return true; }
  return false;
}
