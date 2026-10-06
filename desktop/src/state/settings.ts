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

export type InterfaceScale = 100 | 115 | 130;
export const INTERFACE_SCALES: InterfaceScale[] = [100, 115, 130];
export const PREVIEW_EDGES = [3840, 2560, 1920, 1080] as const;

export interface Settings {
  language: LanguageSetting;
  interfaceScale: InterfaceScale;
  previewLongEdge: number;
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
  collapsedSections: Record<string, boolean>;
  lastFolder: string | null;
  settingsPage: 'general' | 'rendering' | 'diagnostics';
}

export const SETTINGS_DEFAULT: Settings = {
  language: 'system',
  interfaceScale: 115,
  previewLongEdge: 2560,
  sideUnit: 'mm',
  decoupleEffects: false,
  recalculateEffectsAfterCrop: false,
  diBlueCompensation: false,
  parametersTab: 'preDev',
  leftCollapsed: false,
  rightCollapsed: false,
  filmstripCollapsed: false,
  leftWidth: 254,
  rightWidth: 288,
  collapsedSections: {},
  lastFolder: null,
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
export function useSettings<T>(sel: (s: SettingsStore) => T): T {
  return useStore(settingsStore, sel);
}
