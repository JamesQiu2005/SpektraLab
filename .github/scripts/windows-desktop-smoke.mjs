import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { createRequire } from 'node:module';
import { dirname, resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const [executable, profile] = process.argv.slice(2);
if (!executable || !profile) throw new Error('Usage: node windows-desktop-smoke.mjs <app.exe> <WebView2 profile>');
const app = resolve(executable);
const isAppUrl = (url) => URL.canParse(url) && new URL(url).hostname === 'tauri.localhost';
const require = createRequire(new URL('../../desktop/package.json', import.meta.url));
const { chromium } = require('playwright');

const listener = createServer();
await new Promise((resolve, reject) => listener.listen(0, '127.0.0.1', resolve).once('error', reject));
const endpoint = 'http://127.0.0.1:' + listener.address().port;
await new Promise((resolve, reject) => listener.close((error) => error ? reject(error) : resolve()));

const processHandle = spawn(app, [], {
  cwd: dirname(app),
  env: {
    ...process.env,
    WEBVIEW2_USER_DATA_FOLDER: resolve(profile),
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: '--remote-debugging-port=' + new URL(endpoint).port,
  },
  stdio: 'ignore',
});
const result = new Promise((resolve) => {
  processHandle.once('error', (error) => resolve({ error }));
  processHandle.once('exit', (code, signal) => resolve({ code, signal }));
});
let exit;
void result.then((value) => { exit = value; });
let browser;
try {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (exit) throw new Error('Desktop exited before starting WebView2', { cause: exit.error ?? exit });
    const response = await fetch(endpoint + '/json/list', { signal: AbortSignal.timeout(1_000) })
      .then((value) => value.json()).catch(() => []);
    if (response.some((target) => target.type === 'page' && isAppUrl(target.url))) break;
    await sleep(200);
  }
  if (Date.now() >= deadline) throw new Error('Desktop did not start its WebView2 page');
  browser = await chromium.connectOverCDP(endpoint, { timeout: 5_000 });
  let page;
  // The debugging endpoint can list the page before Playwright exposes it.
  while (Date.now() < deadline) {
    if (exit) throw new Error('Desktop exited before WebView2 attached', { cause: exit.error ?? exit });
    page = browser.contexts().flatMap((context) => context.pages())
      .find((candidate) => isAppUrl(candidate.url()));
    if (page) break;
    await sleep(100);
  }
  if (!page) throw new Error('The desktop page was not found in WebView2');
  await page.getByTestId('v2-window').waitFor({ timeout: 15_000 });
  await page.getByTestId('caption-close').click({ timeout: 10_000 });
  const termination = await Promise.race([result, sleep(12_000, null, { ref: false })]);
  if (!termination || termination.code !== 0) {
    throw new Error('Desktop did not exit cleanly after closing its window', { cause: termination });
  }
  console.log('Verified WebView2 startup and clean desktop shutdown: ' + app);
} finally {
  if (!exit) {
    processHandle.kill();
    await Promise.race([result, sleep(3_000, null, { ref: false })]);
  }
  await browser?.close().catch(() => {});
}
