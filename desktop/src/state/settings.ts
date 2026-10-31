// settings.ts — the app's own preferences (the macOS `UserDefaults` `ui2.*`).
//
// Per-viewer conveniences live in the webview's localStorage, which Tauri
// keeps in the app's data directory. The store takes its `Storage` as an
// argument (AGENTS.md trap 24): tests inject a throwaway one and never read
// the shared store.

import { createStore, type StoreApi } from 'zustand/vanilla';
import { useStore } from 'zustand';
import type { LanguageSetting } from '../i18n';
import type { SideUnit } from '@shared/params';
import type { PreviewGamut } from '../canvas/colorSpace';
import { RENDER_PREFERENCES_DEFAULT, renderPreferences } from '@shared/renderPreferences';

export type InterfaceScale = 100 | 115 | 130;
export const INTERFACE_SCALES: InterfaceScale[] = [100, 115, 130];
export const PREVIEW_EDGES = [3840, 2560, 1920, 1080] as const;
// Declared before loadSettings runs for the module's own store below: a
// reference to a const not yet initialised throws, and loadSettings's catch
// would then hand every setting back at its default.
export const RECENT_FOLDERS_MAX = 8;
export const PANEL_WIDTHS = { leftWidth: [232, 254, 380], rightWidth: [280, 288, 364] } as const;
export function boundedPanelWidth(key: keyof typeof PANEL_WIDTHS, width: number): number {
  const [lo, normal, hi] = PANEL_WIDTHS[key];
  return Number.isFinite(width) ? Math.max(lo, Math.min(hi, width)) : normal;
}

export interface Settings {
  language: LanguageSetting;
  interfaceScale: InterfaceScale;
  previewLongEdge: number;
  previewGamut: PreviewGamut;
  sideUnit: SideUnit;
  decoupleEffects: boolean;
  recalculateEffectsAfterCrop: boolean;
  diBlueCompensation: boolean;
  parametersTab: 'preDev' | 'postDev';
  leftCollapsed: boolean;
  rightCollapsed: boolean;
  filmstripCollapsed: boolean;
  leftWidth: number;
  rightWidth: number;
  filmEdgeBodySeed: number;
  collapsedSections: Record<string, boolean>;
  lastFolder: string | null;
  /** Folders opened most recently, newest first (File › Open Recent). */
  recentFolders: string[];
  settingsPage: 'general' | 'rendering' | 'memory' | 'diagnostics' | 'agents';
}

export const SETTINGS_DEFAULT: Settings = {
  language: 'system',
  interfaceScale: 115,
  previewLongEdge: 2560,
  previewGamut: 'auto',
  sideUnit: 'mm',
  decoupleEffects: false,
  ...RENDER_PREFERENCES_DEFAULT,
  parametersTab: 'preDev',
  leftCollapsed: false,
  rightCollapsed: false,
  filmstripCollapsed: false,
  leftWidth: 254,
  rightWidth: 288,
  filmEdgeBodySeed: 0,
  collapsedSections: {},
  lastFolder: null,
  recentFolders: [],
  settingsPage: 'general',
};

const KEY = 'ui2.settings';

export function loadSettings(storage: Pick<Storage, 'getItem'> | null): Settings {
  try {
    const raw = storage?.getItem(KEY);
    if (!raw) return SETTINGS_DEFAULT;
    const o = JSON.parse(raw) as Partial<Settings>;
    const out = { ...SETTINGS_DEFAULT } as Record<string, unknown>;
    for (const k of Object.keys(SETTINGS_DEFAULT) as (keyof Settings)[]) {
      const v = o[k];
      const d = SETTINGS_DEFAULT[k];
      if (v !== undefined && (typeof v === typeof d || d === null)) out[k] = v;
    }
    const s = out as unknown as Settings;
    if (!INTERFACE_SCALES.includes(s.interfaceScale)) s.interfaceScale = SETTINGS_DEFAULT.interfaceScale;
    if (!(PREVIEW_EDGES as readonly number[]).includes(s.previewLongEdge)) s.previewLongEdge = SETTINGS_DEFAULT.previewLongEdge;
    if (!(['auto', 'srgb', 'display-p3'] as const).includes(s.previewGamut)) s.previewGamut = SETTINGS_DEFAULT.previewGamut;
    s.leftWidth = boundedPanelWidth('leftWidth', s.leftWidth);
    s.rightWidth = boundedPanelWidth('rightWidth', s.rightWidth);
    if (!Number.isInteger(s.filmEdgeBodySeed) || s.filmEdgeBodySeed < 0 || s.filmEdgeBodySeed > 2147483647) s.filmEdgeBodySeed = 0;
    if (!['general', 'rendering', 'memory', 'diagnostics', 'agents'].includes(s.settingsPage)) s.settingsPage = 'general';
    s.recentFolders = (Array.isArray(s.recentFolders) ? s.recentFolders : [])
      .filter((p): p is string => typeof p === 'string' && p.length > 0).slice(0, RECENT_FOLDERS_MAX);
    return s;
  } catch {
    return SETTINGS_DEFAULT;
  }
}

export interface SettingsStore extends Settings {
  set<K extends keyof Settings>(key: K, value: Settings[K]): void;
  toggleSection(key: string): void;
}

export function createSettingsStore(storage: Pick<Storage, 'getItem' | 'setItem'> | null): StoreApi<SettingsStore> {
  return createStore<SettingsStore>((set, get) => ({
    ...loadSettings(storage),
    set(key, value) {
      if (key === 'leftWidth' || key === 'rightWidth') value = boundedPanelWidth(key, value as number) as Settings[typeof key];
      set({ [key]: value } as Partial<SettingsStore>);
      persist(get());
    },
    toggleSection(key) {
      const c = { ...get().collapsedSections };
      c[key] = !c[key];
      set({ collapsedSections: c });
      persist(get());
    },
  }));
  function persist(s: SettingsStore) {
    queueMicrotask(() => {
      try {
        const out: Record<string, unknown> = {};
        for (const k of Object.keys(SETTINGS_DEFAULT)) out[k] = (s as unknown as Record<string, unknown>)[k];
        storage?.setItem(KEY, JSON.stringify(out));
      } catch {
        /* private window, blocked storage: the setting lasts the session */
      }
    });
  }
}

function defaultStorage(): Storage | null {
  try {
    return typeof window !== 'undefined' ? window.localStorage : null;
  } catch {
    return null;
  }
}

export const settingsStore = createSettingsStore(defaultStorage());


/** One folder, one entry: slashes and a trailing separator do not make a
 * second one, nor does letter case on a Windows path. */
function sameFolder(a: string, b: string): boolean {
  const key = (p: string) => {
    const n = p.replace(/\\/g, '/').replace(/\/+$/, '');
    return /^([a-z]:|\/\/)/i.test(n) ? n.toLowerCase() : n;
  };
  return key(a) === key(b);
}

/** `recent` with `dir` in front, once, and no more than RECENT_FOLDERS_MAX. */
export function withRecentFolder(recent: readonly string[], dir: string): string[] {
  return [dir, ...recent.filter((p) => !sameFolder(p, dir))].slice(0, RECENT_FOLDERS_MAX);
}

export function rememberFolder(dir: string) {
  const s = settingsStore.getState();
  s.set('recentFolders', withRecentFolder(s.recentFolders, dir));
}

export function forgetRecentFolders() {
  settingsStore.getState().set('recentFolders', []);
}
// The headless CLI has no WebView localStorage. Mirror only the two switches
// that affect pixels, via an atomic native write independent of batch leases.
// Serialize writes so a slow startup save cannot replace a newer selection.
let renderingSave: Promise<void> = Promise.resolve();
export function syncAgentRenderingPreferences(): Promise<void> {
  if (typeof window === 'undefined' || !('__TAURI_INTERNALS__' in window)) return Promise.resolve();
  const preferences = renderPreferences(settingsStore.getState());
  renderingSave = renderingSave.catch(() => undefined).then(async () => {
    const { invoke } = await import('@tauri-apps/api/core');
    await invoke('agent_rendering_set', { preferences });
  });
  return renderingSave;
}
function mirrorRenderingPreferences() {
  void syncAgentRenderingPreferences().catch(async (error: unknown) => {
    console.error('Could not save shared rendering preferences:', error);
    const { message } = await import('@tauri-apps/plugin-dialog');
    await message(`Could not save rendering preferences for command-line tools. Retry changing the setting before using agent export.\n${String(error)}`,
      { title: 'SpektraLab', kind: 'error' }).catch((dialogError: unknown) => console.error(dialogError));
  });
}
mirrorRenderingPreferences();
settingsStore.subscribe((next, previous) => {
  if (next.recalculateEffectsAfterCrop !== previous.recalculateEffectsAfterCrop || next.diBlueCompensation !== previous.diBlueCompensation)
    mirrorRenderingPreferences();
});
export function useSettings<T>(sel: (s: SettingsStore) => T): T {
  return useStore(settingsStore, sel);
}
