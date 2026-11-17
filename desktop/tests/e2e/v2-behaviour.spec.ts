// T3 — the v2 window's behaviour in Chromium on the mock backends (PRD-W2
// §4). No timing is asserted: a slow mock render (`renderDelay`) only makes
// an intermediate state visible long enough to see it.

import { expect, test, type Page } from '@playwright/test';

const ROLL = '/mock/Roll 01';
const status = (p: Page) => p.getByTestId('status-line');

async function open(page: Page, query = '') {
  await page.addInitScript(() => { try { localStorage.clear(); } catch { /* none */ } });
  await page.goto(`/?open=${encodeURIComponent(ROLL)}${query}`);
  await expect(page.getByTestId('frame-title')).toContainText('DSC_0001');
  await expect(status(page)).toContainText(/Developed|Edited/, { timeout: 20_000 });
}
const state = <T>(page: Page, expr: string) => page.evaluate((e) => {
  const spk = (window as unknown as { __spk: Record<string, { getState(): unknown }> }).__spk;
  return new Function('s', 'u', 'l', `return ${e}`)(spk.sessionStore!.getState(), spk.uiStore!.getState(), spk.libraryStore!.getState());
}, expr) as Promise<T>;

test.beforeEach(async ({ page }) => { await page.setViewportSize({ width: 1536, height: 816 }); });

test('open → developing → done: the status line follows the scheduler, and the last print stays meanwhile', async ({ page }) => {
  await open(page, '&renderDelay=1200');
  expect(await state(page, 's.badge')).not.toBeNull();
  await page.locator('[data-stock="kodak_gold_200"]').click();
  await expect(status(page)).toContainText('Developing · Gold 200');
  // The last print is still the picture while the new one develops.
  expect(await page.evaluate(() => !!(window as unknown as { __spk: { frameImages: { print: unknown } } }).__spk.frameImages.print)).toBe(true);
  await expect(status(page)).toContainText('Developed · Gold 200', { timeout: 20_000 });
  // The page's job is the scheduler's snapshot (WIRE.md's flat JobSnapshotWire).
  expect(await state(page, 's.job.state')).toBe('done');
});

test('a failed develop keeps the last print and offers Try Again, which develops it', async ({ page }) => {
  await open(page);
  await page.evaluate(() => (globalThis as unknown as { __spkMock: { failNextRenders(n: number): void } }).__spkMock.failNextRenders(1));
  await page.locator('[data-stock="kodak_gold_200"]').click();
  await expect(page.getByTestId('render-failed')).toContainText('The graphics device stopped responding.');
  expect(await page.evaluate(() => !!(window as unknown as { __spk: { frameImages: { print: unknown } } }).__spk.frameImages.print)).toBe(true);
  await page.getByTestId('try-again').click();
  await expect(page.getByTestId('render-failed')).toHaveCount(0);
  await expect(status(page)).toContainText('Developed · Gold 200', { timeout: 20_000 });
});

test('newer edits fold into the newest job: three quick picks, fewer develops, the last one shown', async ({ page }) => {
  await open(page, '&renderDelay=600');
  await page.evaluate(() => {
    const w = window as unknown as { __jobs: string[]; __spk: { scheduler: () => { onJob(cb: (j: { jobId: string; kind: string; state: string }) => void): void } } };
    w.__jobs = [];
    w.__spk.scheduler().onJob((j) => { if (j.kind.startsWith('canvas') && j.state === 'running' && !w.__jobs.includes(j.jobId)) w.__jobs.push(j.jobId); });
  });
  for (const id of ['kodak_gold_200', 'kodak_ektar_100', 'kodak_portra_160']) await page.locator(`[data-stock="${id}"]`).click();
  await expect(status(page)).toContainText('Developed · Portra 160', { timeout: 20_000 });
  const ran = await page.evaluate(() => (window as unknown as { __jobs: string[] }).__jobs.length);
  expect(ran).toBeGreaterThan(0);
  expect(ran).toBeLessThan(3);
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_160');
});

test('a batch export moves to the toolbar ring; Stop after this frame cancels the rest', async ({ page }) => {
  await open(page, '&renderDelay=400');
  await page.keyboard.press('Control+a');
  await page.keyboard.press('Control+e');
  await expect(page.getByTestId('export-dialog')).toBeVisible();
  await page.getByTestId('export-run').click();
  await expect(page.getByTestId('export-ring')).toBeVisible();
  await expect(status(page)).toContainText(/Exporting \d of 8/);
  await page.getByTestId('export-ring').click();
  await expect(page.getByTestId('exporting-flyout')).toBeVisible();
  await page.getByTestId('stop-after-frame').click();
  await expect(page.getByTestId('export-ring')).toHaveCount(0, { timeout: 20_000 });
  await expect(page.getByTestId('export-dialog')).toHaveCount(0);
  expect(await state(page, 's.batchExporting')).toBe(false);
});

test('the workspace switch keeps the frame, its edits and its undo', async ({ page }) => {
  await open(page);
  await page.locator('[data-stock="kodak_gold_200"]').click();
  await expect(status(page)).toContainText('Gold 200');
  const undo = await state<number>(page, 's.undo.length');
  await page.keyboard.press('Control+Alt+1');
  await expect(page.getByTestId('library')).toBeVisible();
  await page.keyboard.press('Control+Alt+2');
  await expect(page.getByTestId('editor')).toBeVisible();
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_gold_200');
  expect(await state(page, 's.undo.length')).toBe(undo);
  await expect(page.getByTestId('frame-title')).toContainText('DSC_0001');
  await page.keyboard.press('Alt+ArrowLeft');
  await expect(page.getByTestId('library')).toBeVisible();
});

test('the Library on the mock helper: open a catalog, pick three, Develop 3 opens them as the filmstrip', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('workspace-library').click();
  await expect(page.getByTestId('first-run')).toBeVisible();
  await page.getByTestId('recent-libraries').getByText('Darkroom 2026', { exact: true }).click();
  const tiles = page.getByTestId('library-tile');
  await expect(tiles.first()).toBeVisible();
  await tiles.nth(0).click();
  await expect(page.getByTestId('info-one')).toContainText('_DSC0061.ARW');
  await tiles.nth(1).click({ modifiers: ['ControlOrMeta'] });
  await tiles.nth(2).click({ modifiers: ['ControlOrMeta'] });
  await expect(page.getByTestId('info-picked')).toContainText('3 frames');
  await page.getByTestId('develop-picked').click();
  await expect(page.getByTestId('editor')).toBeVisible();
  await expect.poll(() => state<number>(page, 's.frames.length')).toBe(3);
  await expect(page.getByTestId('frame-title')).toContainText('of 3');
});

test('a Capture One source is read-only: a rating key says so and writes nothing', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('workspace-library').click();
  await page.getByTestId('recent-libraries').getByText('Archive', { exact: true }).click();
  await page.getByTestId('library-tile').first().click();
  await expect(page.getByTestId('source-well')).toContainText('Read-only');
  const before = await state(page, 'l.images[0].rating');
  await page.keyboard.press('3');
  await expect(page.getByTestId('library-message')).toContainText('Ratings are set in Capture One');
  expect(await state(page, 'l.images[0].rating')).toBe(before);
});

test('the source menu, the light table and the contact sheet', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('workspace-library').click();
  await page.getByTestId('recent-libraries').getByText('Darkroom 2026', { exact: true }).click();
  await page.getByTestId('source-well').click();
  await expect(page.getByTestId('source-menu')).toContainText('Open Capture One Catalog…');
  await page.keyboard.press('Escape');
  await page.keyboard.press('Control+Shift+L');
  await expect(page.getByTestId('light-table')).toBeVisible();
  await page.getByTestId('new-contact-sheet').click();
  await expect(page.getByTestId('contact-sheet')).toBeVisible();
});

test('menus and keys: Alt shows access keys, F10 opens File, a checked View item toggles, a field keeps its keys', async ({ page }) => {
  await open(page);
  await page.keyboard.press('Alt');
  await expect(page.locator('.access.shown').first()).toBeVisible();
  await page.keyboard.press('v');
  await expect(page.getByTestId('menu-view-list')).toBeVisible();
  await page.locator('[data-command="filmstrip"]').click();
  await expect(page.getByTestId('v2-filmstrip')).toHaveCount(0);
  await page.keyboard.press('Control+Shift+F');
  await expect(page.getByTestId('v2-filmstrip')).toBeVisible();
  await page.keyboard.press('F10');
  await expect(page.getByTestId('menu-file-list')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('menu-file-list')).toHaveCount(0);
  // F8 hides the Edit rail; Ctrl+B hides both and brings them back.
  await page.keyboard.press('F8');
  await expect(page.getByTestId('rail-right')).toHaveCount(0);
  await page.keyboard.press('F8');
  await expect(page.getByTestId('rail-right')).toBeVisible();
  await page.keyboard.press('Control+b');
  await expect(page.getByTestId('rail-left')).toHaveCount(0);
  await page.keyboard.press('Control+b');
  await expect(page.getByTestId('rail-left')).toBeVisible();
  // Trap 32: a focused field takes ← → and letters; the frame does not change.
  await page.getByLabel('Film Exposure, value').focus();
  await page.keyboard.press('ArrowRight');
  await page.keyboard.press('c');
  expect(await state(page, 's.selection')).toContain('DSC_0001');
  expect(await state(page, 's.tool')).toBe('select');
});

test('capability gating: a refused feature is absent, a supported one is in its place', async ({ page }) => {
  await open(page);
  // The mock refuses overscan/date_imprint by default, as the Windows host does.
  await expect(page.getByTestId('section-filmEdge')).toHaveCount(0);
  await expect(page.getByTestId('section-dateBack')).toHaveCount(0);
  await page.goto(`/?open=${encodeURIComponent(ROLL)}&allFeatures=1`);
  await expect(page.getByTestId('section-filmEdge')).toBeVisible({ timeout: 20_000 });
  await page.goto(`/?open=${encodeURIComponent(ROLL)}&unsupported=scene_latitude_mapping`);
  await expect(status(page)).toContainText(/Developed|Edited/, { timeout: 20_000 });
  await page.keyboard.press('Control+Alt+Shift+C');
  await expect(page.getByTestId('copy-settings')).toBeVisible();
  await expect(page.getByTestId('copy-settings')).not.toContainText('Scene Placement');
  await page.keyboard.press('Escape');
  await page.keyboard.press('Control+,');
  await page.getByTestId('pane-engine').click();
  await expect(page.getByTestId('settings-engine')).toContainText('Scene Placement');
  await expect(page.getByTestId('settings-engine')).toContainText('scene_latitude_mapping');
});

test('the engine cannot start: the card, the words, Export dimmed, the Library still opens', async ({ page }) => {
  await page.goto(`/?open=${encodeURIComponent(ROLL)}&hostFail=1`);
  await expect(page.getByTestId('engine-stopped')).toContainText('The engine cannot start');
  await expect(page.getByTestId('engine-stopped')).toContainText('No Vulkan device was found.');
  await expect(status(page)).toContainText('Engine stopped');
  await expect(page.getByTestId('export-button')).toBeDisabled();
  await page.getByTestId('engine-details').click();
  await expect(page.getByTestId('engine-stopped')).toContainText('vkEnumeratePhysicalDevices');
  await page.getByTestId('workspace-library').click();
  await expect(page.getByTestId('first-run')).toBeVisible();
});

test('narrow and short windows: rails fold by width and come over the picture; the Navigator and filmstrip fold by height', async ({ page }) => {
  await open(page);
  await page.setViewportSize({ width: 1000, height: 816 });
  await expect(page.getByTestId('rail-left')).toHaveCount(0);
  await expect(page.getByTestId('rail-right')).toHaveAttribute('data-mode', 'docked');
  await page.keyboard.press('F7');
  await expect(page.getByTestId('rail-left')).toHaveAttribute('data-mode', 'over');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('rail-left')).toHaveCount(0);
  await page.setViewportSize({ width: 640, height: 816 });
  await expect(page.getByTestId('rail-right')).toHaveCount(0);
  await page.keyboard.press('F8');
  await expect(page.getByTestId('rail-right')).toHaveAttribute('data-mode', 'over');
  await page.keyboard.press('F7');
  // One at a time.
  await expect(page.getByTestId('rail-left')).toHaveAttribute('data-mode', 'over');
  await expect(page.getByTestId('rail-right')).toHaveCount(0);
  await page.keyboard.press('Escape');
  await page.setViewportSize({ width: 1536, height: 700 });
  await expect(page.getByTestId('navigator-line')).toBeVisible();
  await page.setViewportSize({ width: 1536, height: 580 });
  await expect(page.getByTestId('v2-filmstrip')).toHaveCount(0);
  // The toolbar's overflow (README §1.3): under 820 of picture the zoom, Crop and Original go into ···;
  // under 620, ‹ › and Compare as well. At 1100 wide the picture is 779 (the left rail folded); at 930, 609.
  await page.setViewportSize({ width: 1100, height: 816 });
  await expect(page.getByTestId('tb-zoom')).toHaveCount(0);
  await expect(page.getByTestId('tb-compare')).toBeVisible();
  await page.setViewportSize({ width: 930, height: 816 });
  await expect(page.getByTestId('tb-compare')).toHaveCount(0);
  await page.getByTestId('tb-more').click();
  await expect(page.getByTestId('more-menu')).toContainText('Compare');
});

test('1080p at 150 %: both rails, the Navigator folded to one line', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 672 }, deviceScaleFactor: 1.5 });
  const page = await context.newPage();
  try {
    await open(page);
    await expect(page.getByTestId('rail-left')).toHaveAttribute('data-mode', 'docked');
    await expect(page.getByTestId('rail-right')).toHaveAttribute('data-mode', 'docked');
    await expect(page.getByTestId('navigator-line')).toBeVisible();
    const t = await page.getByTestId('titlebar').boundingBox();
    expect(Math.round(t!.height)).toBe(32);
  } finally { await context.close(); }
});

test('the rails drag between 280 and 440 and a double-click puts them back to 320', async ({ page }) => {
  await open(page);
  const wall = page.getByTestId('wall-left');
  const box = (await wall.boundingBox())!;
  await page.mouse.move(box.x + 3, box.y + 300);
  await page.mouse.down();
  await page.mouse.move(box.x + 300, box.y + 300);
  await page.mouse.up();
  expect(Math.round((await page.getByTestId('rail-left').boundingBox())!.width)).toBe(440);
  await wall.dblclick();
  expect(Math.round((await page.getByTestId('rail-left').boundingBox())!.width)).toBe(320);
});
