// main.tsx — boot: theme, language, interface scale, keys, menu, session.

import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/theme.css';
import { setLanguage } from './i18n';
import { settingsStore } from './state/settings';
import { boot } from './state/session';
import { EditorWindow } from './windows/EditorWindow';
import { installKeys, webviewOwnsMenuKeys } from './windows/keys';
import { MENU_CHORDS, installMenu, refreshRecentMenu } from './windows/menus';
import { inTauri } from './host/transport';
import { useSettings } from './state/settings';

function applySettings() {
  const s = settingsStore.getState();
  setLanguage(s.language);
  document.documentElement.style.setProperty('--ui-scale', String(s.interfaceScale / 100));
  document.documentElement.style.setProperty('--left-width', `${s.leftWidth}px`);
  document.documentElement.style.setProperty('--right-width', `${s.rightWidth}px`);
}
applySettings();

// The native menu is built once per language; a change to the recent-folder
// list only swaps the entries under File › Open Recent. Both are queued in
// menus.ts, so they apply in the order they happened.
let lastLanguage = settingsStore.getState().language;
let lastRecent = settingsStore.getState().recentFolders;
settingsStore.subscribe((s) => {
  applySettings();
  if (!inTauri()) return;
  if (s.language !== lastLanguage) {
    lastLanguage = s.language;
    lastRecent = s.recentFolders;
    void installMenu();
  } else if (s.recentFolders !== lastRecent) {
    lastRecent = s.recentFolders;
    void refreshRecentMenu();
  }
});

installKeys(inTauri() && !webviewOwnsMenuKeys() ? MENU_CHORDS : new Set());
if (inTauri()) void installMenu();

// The webview's own context menu (Reload / Inspect) is not the app's.
if (import.meta.env.PROD) window.addEventListener('contextmenu', (e) => e.preventDefault());

function App() {
  // Re-render everything on a language change: strings are looked up at render.
  useSettings((s) => s.language);
  return <EditorWindow />;
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

void boot();

// For the layout harness and for debugging from the webview inspector.
import { sessionStore } from './state/session';
import { frameImages } from './state/frames';
(window as unknown as Record<string, unknown>).__spk = { sessionStore, settingsStore, frameImages };
