// main.tsx — boot: theme, language, interface scale, keys, session.
//
// v2 (SpektraLab 2 for Windows): the window is `AppWindow` — an app-drawn
// title bar with the in-window menu bar over the Library | Edit workspaces.
// The native menu bar of v1 (menus.ts) is no longer installed: it would add
// a second menu row under the frameless window's own title bar.

import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './styles/theme.css';
import './styles/v2.css';
import { applyTokens } from './theme/tokens';
import { resolveLanguage } from './i18n';
import { AppWindow } from './app/AppWindow';
import { installV2Keys } from './app/keys';
import { EditorWindow } from './windows/EditorWindow';
import { installKeys } from './windows/keys';
import { setLanguage } from './i18n';
import { settingsStore } from './state/settings';
import { boot } from './state/session';
import { useSettings } from './state/settings';

// v1's one-window editor, kept for v1's browser cases only (Playwright's
// `v1` project sets this flag): a development build, never a release one.
// Its session logic is the v2 window's; only the frame around it differs.
const legacyWindow = import.meta.env.DEV && (() => { try { return localStorage.getItem('spk.legacyWindow') === '1'; } catch { return false; } })();

function applySettings() {
  const s = settingsStore.getState();
  setLanguage(s.language);
  if (!legacyWindow) applyTokens(document.documentElement, resolveLanguage(s.language, navigator.languages ?? [navigator.language]));
  document.documentElement.style.setProperty('--ui-scale', String(s.interfaceScale / 100));
  document.documentElement.style.setProperty('--left-width', `${s.leftWidth}px`);
  document.documentElement.style.setProperty('--right-width', `${s.rightWidth}px`);
}
applySettings();

settingsStore.subscribe(() => applySettings());

if (legacyWindow) installKeys(new Set());
else installV2Keys();

// The webview's own context menu (Reload / Inspect) is not the app's.
if (import.meta.env.PROD) window.addEventListener('contextmenu', (e) => e.preventDefault());

function App() {
  // Re-render everything on a language change: strings are looked up at render.
  useSettings((s) => s.language);
  return legacyWindow ? <EditorWindow /> : <AppWindow />;
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
import { uiStore } from './app/ui';
import { libraryStore } from './library/store';
import { localScheduler } from './scheduler';
(window as unknown as Record<string, unknown>).__spk = { sessionStore, settingsStore, frameImages, uiStore, libraryStore, scheduler: localScheduler };
