// main.tsx — boot: theme, language, interface scale, keys, menu, session.

import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/theme.css';
import { setLanguage } from './i18n';
import { settingsStore } from './state/settings';
import { boot } from './state/session';
import { EditorWindow } from './windows/EditorWindow';
import { installKeys } from './windows/keys';
import { MENU_CHORDS, installMenu } from './windows/menus';
import { inTauri } from './host/transport';
import { useSettings } from './state/settings';

function applySettings() {
  const s = settingsStore.getState();
  setLanguage(s.language);
  document.documentElement.style.setProperty('--ui-scale', String(s.interfaceScale / 100));
}
applySettings();

let lastLanguage = settingsStore.getState().language;
settingsStore.subscribe((s) => {
  applySettings();
  if (s.language !== lastLanguage) {
    lastLanguage = s.language;
    if (inTauri()) void installMenu().catch((e) => console.error('menu', e));
  }
});

installKeys(inTauri() ? MENU_CHORDS : new Set());
if (inTauri()) void installMenu().catch((e) => console.error('menu', e));

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
