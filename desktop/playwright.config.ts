// The layout harness: the Vite dev server in Chromium, with the in-page mock
// host standing in for the Tauri core (Playwright cannot drive WebKitGTK).
// Chromium comes from /opt/pw-browsers (set PW_CHROMIUM to override); this
// config never downloads a browser.

import { existsSync, readdirSync } from 'node:fs';
import { defineConfig } from '@playwright/test';

function chromium(): string | undefined {
  if (process.env.PW_CHROMIUM) return process.env.PW_CHROMIUM;
  const root = '/opt/pw-browsers';
  if (existsSync(root)) {
    for (const d of readdirSync(root).filter((x) => /^chromium-\d+$/.test(x))) {
      const p = `${root}/${d}/chrome-linux/chrome`;
      if (existsSync(p)) return p;
    }
  }
  // macOS: any Chrome for Testing already in Playwright's cache (this config
  // still never downloads one). The newest revision wins.
  const mac = `${process.env.HOME ?? ''}/Library/Caches/ms-playwright`;
  if (process.platform === 'darwin' && existsSync(mac)) {
    for (const d of readdirSync(mac).filter((x) => /^chromium-\d+$/.test(x)).sort().reverse()) {
      for (const arch of ['chrome-mac-arm64', 'chrome-mac', 'chrome-mac-x64']) {
        const p = `${mac}/${d}/${arch}/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing`;
        if (existsSync(p)) return p;
      }
    }
  }
  return undefined;
}

const baseURL = process.env.PW_BASE_URL ?? 'http://127.0.0.1:5173';
export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 60_000,
  workers: 1,
  use: {
    baseURL,
    viewport: { width: 1600, height: 960 },
    // Current Chromium selects the software backend through ANGLE. The legacy
    // --use-gl=swiftshader flag can lose a visible canvas context on first resize.
    launchOptions: { executablePath: chromium(), args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader'] },
  },
  webServer: {
    command: process.env.PW_DEV_SERVER ?? 'npm run dev:web',
    url: baseURL,
    reuseExistingServer: true,
    timeout: 60_000,
  },
});
