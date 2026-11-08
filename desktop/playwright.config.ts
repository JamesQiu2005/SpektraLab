// The layout harness: the Vite dev server in Chromium, with the in-page mock
// host standing in for the Tauri core (Playwright cannot drive WebKitGTK).
// Chromium comes from /opt/pw-browsers (set PW_CHROMIUM to override); this
// config never downloads a browser.

import { existsSync, readdirSync } from 'node:fs';
import { defineConfig } from '@playwright/test';

function chromium(): string | undefined {
  if (process.env.PW_CHROMIUM) return process.env.PW_CHROMIUM;
  const root = '/opt/pw-browsers';
  if (!existsSync(root)) return undefined;
  for (const d of readdirSync(root).filter((x) => /^chromium-\d+$/.test(x))) {
    const p = `${root}/${d}/chrome-linux/chrome`;
    if (existsSync(p)) return p;
  }
  return undefined;
}

export default defineConfig({
  testDir: 'tests/e2e',
  timeout: 60_000,
  workers: 1,
  use: {
    baseURL: 'http://127.0.0.1:5173',
    viewport: { width: 1600, height: 960 },
    launchOptions: { executablePath: chromium(), args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] },
  },
  webServer: {
    command: 'npm run dev:web',
    url: 'http://127.0.0.1:5173',
    reuseExistingServer: true,
    timeout: 60_000,
  },
});
