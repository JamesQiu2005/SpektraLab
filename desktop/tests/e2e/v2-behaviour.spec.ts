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

test('the mode row keeps the frame, its edits and its undo; the mode is state, not a page', async ({ page }) => {
  await open(page);
  await page.locator('[data-stock="kodak_gold_200"]').click();
  await expect(status(page)).toContainText('Gold 200');
  const undo = await state<number>(page, 's.undo.length');
  await page.keyboard.press('Control+Alt+1');
  await expect(page.getByTestId('v2-window')).toHaveAttribute('data-workspace', 'library');
  await expect(page.getByTestId('mode-library')).toHaveAttribute('aria-selected', 'true');
  await page.keyboard.press('Control+Alt+3');
  await expect(page.getByTestId('v2-window')).toHaveAttribute('data-workspace', 'edit');
  await expect(page.getByTestId('edit-sections')).toBeVisible();
  await page.keyboard.press('Control+Alt+2');
  await expect(page.getByTestId('develop-sections')).toBeVisible();
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_gold_200');
  expect(await state(page, 's.undo.length')).toBe(undo);
  await expect(page.getByTestId('frame-title')).toHaveText('DSC_0001');
  await page.keyboard.press('Alt+ArrowLeft');
  await expect(page.getByTestId('v2-window')).toHaveAttribute('data-workspace', 'edit');
});

test('the left column is the mode’s tools: the Library’s rows; the meter, then Film & Paper | Format; the meter, then Edit’s tools', async ({ page }) => {
  await open(page);
  const column = page.getByTestId('rail-left');
  // Develop: the meter, then Film & Paper and Format; no Edit tools.
  await expect(column.getByTestId('latitude')).toBeVisible();
  await expect(column.getByTestId('section-filmPaper')).toBeVisible();
  await expect(column.getByTestId('section-format')).toBeVisible();
  await expect(column.getByTestId('section-adjust')).toBeHidden();
  // Edit: the meter, then Adjust, Darkroom, Crop — no second tab row.
  await page.getByTestId('mode-edit').click();
  await expect(column.getByTestId('latitude')).toBeVisible();
  await expect(column.getByTestId('section-adjust')).toBeVisible();
  await expect(column.getByTestId('section-filmPaper')).toBeHidden();
  await expect(column.locator('[role="tablist"]')).toHaveCount(1);
  // Library: the source well and its rows; no meter.
  await page.getByTestId('mode-library').click();
  await expect(column.getByTestId('source-well')).toBeVisible();
  await expect(column.getByTestId('latitude')).toHaveCount(0);
  // The right is the browser in all three, never Edit's tools.
  for (const m of ['library', 'develop', 'edit']) {
    await page.getByTestId(`mode-${m}`).click();
    await expect(page.getByTestId('browser')).toBeVisible();
    await expect(page.getByTestId('browser').getByTestId('section-adjust')).toHaveCount(0);
    await expect(page.getByTestId('v2-filmstrip')).toHaveCount(0);
  }
});

test('a mode that cannot be entered says why in place', async ({ page }) => {
  await page.addInitScript(() => { try { localStorage.clear(); } catch { /* none */ } });
  await page.goto('/');
  await page.getByTestId('mode-library').click();
  await expect(page.getByTestId('mode-develop')).toHaveAttribute('aria-disabled', 'true');
  // Dimmed, not dead: a press says why (Playwright's actionability treats aria-disabled as disabled).
  await page.getByTestId('mode-edit').click({ force: true });
  await expect(page.getByTestId('mode-note')).toContainText('Open a picture first');
  await expect(page.getByTestId('v2-window')).toHaveAttribute('data-workspace', 'library');
});

async function openCatalog(page: Page, name = 'Darkroom 2026') {
  await page.getByTestId('mode-library').click();
  await page.getByTestId('recent-libraries').getByText(name, { exact: true }).click();
  await expect(page.getByTestId('library-tile').first()).toBeVisible();
}

test('the Library on the mock helper: open a catalog, pick three; the browser keeps them chosen in every mode', async ({ page }) => {
  await page.addInitScript(() => { try { localStorage.clear(); } catch { /* none */ } });
  await page.goto('/');
  await page.getByTestId('mode-library').click();
  await expect(page.getByTestId('first-run')).toBeVisible();
  await openCatalog(page);
  const tiles = page.getByTestId('browser').getByTestId('library-tile');
  await tiles.nth(0).click();
  await expect(page.getByTestId('info-one')).toContainText('_DSC0061.ARW');
  await tiles.nth(1).click({ modifiers: ['ControlOrMeta'] });
  await tiles.nth(2).click({ modifiers: ['ControlOrMeta'] });
  await expect(page.getByTestId('info-picked')).toContainText('3 frames');
  await expect(page.getByTestId('browser-count')).toContainText('3 of 28 selected');
  // Develop: the focus opens on the page; the browser has the same rows and the same three chosen.
  await page.getByTestId('mode-develop').click();
  await expect(page.getByTestId('v2-window')).toHaveAttribute('data-workspace', 'develop');
  await expect.poll(() => state<string>(page, 's.selection')).toContain('DSC');
  await expect(page.getByTestId('browser-count')).toContainText('3 of 28 selected');
  expect(await page.getByTestId('browser').locator('.v2-lib-tile.picked').count()).toBe(3);
  await page.getByTestId('mode-edit').click();
  expect(await page.getByTestId('browser').locator('.v2-lib-tile.picked').count()).toBe(3);
});

test('the Library shows visible source previews and the viewer follows the selected frame', async ({ page }) => {
  await page.goto('/?thumbDelay=100');
  await page.getByTestId('mode-library').click();
  await openCatalog(page);
  const tiles = page.getByTestId('browser').getByTestId('library-tile');
  const far = tiles.filter({ hasNotText: 'Offline' }).last();
  const viewer = page.getByTestId('library-viewer-image');
  await tiles.first().click();
  const first = tiles.first().locator('img');
  await expect.poll(() => first.evaluate((img: HTMLImageElement) => img.naturalWidth)).toBeGreaterThan(0);
  await expect(viewer).toHaveAttribute('src', (await first.getAttribute('src'))!);
  await expect(page.getByTestId('viewer-strip')).toContainText('Camera preview');
  await expect(far.locator('img')).toHaveCount(0);

  await tiles.nth(1).click();
  const second = tiles.nth(1).locator('img');
  await expect.poll(() => second.evaluate((img: HTMLImageElement) => img.naturalWidth)).toBeGreaterThan(0);
  await expect(viewer).toHaveAttribute('src', (await second.getAttribute('src'))!);
  expect(await viewer.getAttribute('src')).not.toBe(await first.getAttribute('src'));

  await far.scrollIntoViewIfNeeded();
  await expect.poll(() => far.locator('img').evaluate((img: HTMLImageElement) => img.naturalWidth)).toBeGreaterThan(0);
  await expect(first).toHaveCount(0);
  await expect(viewer).toBeVisible();
  const offline = tiles.filter({ hasText: 'Offline' }).first();
  await offline.scrollIntoViewIfNeeded();
  await expect(offline).toContainText('Offline');
  await expect(offline.locator('img')).toHaveCount(0);
});

test('a photo folder reopens from Recent with its rating and original identity', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('mode-library').click();
  await page.getByTestId('first-add-folder').click();
  const tiles = page.getByTestId('library-tile');
  await expect(tiles).toHaveCount(8);
  await expect(page.getByTestId('source-well')).toContainText('8 photos');
  const first = tiles.first();
  const id = (await first.getAttribute('data-uuid'))!;
  await first.click();
  await page.keyboard.press('4');
  const rating = () => state<number | null>(page, `l.images.find(i => i.uuid === ${JSON.stringify(id)})?.rating ?? null`);
  await expect.poll(rating).toBe(4);
  await page.getByTestId('source-well').click();
  await page.getByTestId('source-menu').getByRole('menuitem', { name: 'Close Library' }).click();
  await expect(page.getByTestId('first-run')).toBeVisible();
  await page.getByTestId('recent-libraries').getByRole('button', { name: /Roll 01/ }).click();
  await expect(tiles).toHaveCount(8);
  await expect.poll(rating).toBe(4);
});

test('a browser row opens its picture in Develop and in Edit; ← → walk the rows', async ({ page }) => {
  await page.addInitScript(() => { try { localStorage.clear(); } catch { /* none */ } });
  await page.goto('/');
  await openCatalog(page);
  const tiles = page.getByTestId('browser').getByTestId('library-tile');
  await tiles.nth(0).click();
  await page.getByTestId('mode-develop').click();
  const first = await state<string>(page, 'l.images[0].path');
  await expect.poll(() => state<string>(page, 's.selection')).toBe(first);
  await expect(status(page)).toContainText(/Developed|Edited/, { timeout: 20_000 });
  // A row pressed in Develop: that picture, on the page (the editing session moves to it).
  await tiles.nth(3).click();
  const fourth = await state<string>(page, 'l.images[3].path');
  await expect.poll(() => state<string>(page, 's.selection')).toBe(fourth);
  await expect(page.getByTestId('frame-title')).toHaveText(fourth.split('/').pop()!.replace(/\.[^.]+$/, ''));
  // ... and in Edit.
  await page.getByTestId('mode-edit').click();
  await tiles.nth(5).click();
  await expect.poll(() => state<string>(page, 's.selection')).toBe(await state<string>(page, 'l.images[5].path'));
  // → walks to the next row, and the picture follows.
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => state<string>(page, 's.selection')).toBe(await state<string>(page, 'l.images[6].path'));
  await expect.poll(() => state<string>(page, 'l.focus')).toBe(await state<string>(page, 'l.images[6].uuid'));
  await page.keyboard.press('ArrowLeft');
  await expect.poll(() => state<string>(page, 's.selection')).toBe(await state<string>(page, 'l.images[5].path'));
});

test('with no library open the browser is the folder’s frames: a press opens, Export takes the chosen ones', async ({ page }) => {
  await open(page);
  await expect(page.getByTestId('browser')).toHaveAttribute('data-source', 'folder');
  const frames = page.getByTestId('browser-tile');
  await expect(frames).toHaveCount(8);
  await frames.nth(2).click();
  await expect(page.getByTestId('frame-title')).toHaveText('DSC_0003');
  await frames.nth(4).click({ modifiers: ['ControlOrMeta'] });
  await expect(page.getByTestId('browser-count')).toContainText('2 of 8 selected');
  await expect(status(page)).toContainText(/Developed|Edited/, { timeout: 20_000 });
  await page.getByTestId('export-button').click();
  await expect(page.getByTestId('export-dialog')).toBeVisible();
  expect(await state<string[]>(page, 's.picked')).toHaveLength(2);
});

test('the shared bar: the column, the split and the full grid; the browser’s width is dragged and kept across a relaunch', async ({ page }) => {
  // Storage is cleared once, not on the relaunch below (`open` clears it on every load).
  await page.addInitScript(() => { if (!sessionStorage.getItem('spk.cleared')) { localStorage.clear(); sessionStorage.setItem('spk.cleared', '1'); } });
  await page.goto(`/?open=${encodeURIComponent(ROLL)}`);
  await expect(status(page)).toContainText(/Developed|Edited/, { timeout: 20_000 });
  await page.getByTestId('bar-column').click();
  await expect(page.getByTestId('rail-left')).toHaveCount(0);
  await page.getByTestId('bar-column').click();
  await expect(page.getByTestId('rail-left')).toBeVisible();
  await page.getByTestId('bar-split').click();
  await expect(page.getByTestId('browser')).toBeHidden();
  await page.keyboard.press('F8');
  await expect(page.getByTestId('browser')).toBeVisible();
  // The full grid: from Develop it goes to the Library with the browser taking the window.
  await page.getByTestId('bar-grid').click();
  await expect(page.getByTestId('v2-window')).toHaveAttribute('data-workspace', 'library');
  await expect(page.getByTestId('centre')).toHaveCount(0);
  const grid = (await page.getByTestId('browser').boundingBox())!;
  expect(Math.round(grid.x + grid.width)).toBe(1536);
  expect(Math.round(grid.x)).toBe(321);
  await page.keyboard.press('g');
  await expect(page.getByTestId('centre')).toBeVisible();
  // The browser's wall: dragged left it widens, and the width is kept across a relaunch.
  const wall = (await page.getByTestId('wall-right').boundingBox())!;
  await page.mouse.move(wall.x + 3, wall.y + 300);
  await page.mouse.down();
  await page.mouse.move(wall.x + 3 - 120, wall.y + 300);
  await page.mouse.up();
  expect(Math.round((await page.getByTestId('browser').boundingBox())!.width)).toBe(550);
  await page.goto(`/?open=${encodeURIComponent(ROLL)}`);
  await expect(page.getByTestId('frame-title')).toHaveText('DSC_0001');
  expect(Math.round((await page.getByTestId('browser').boundingBox())!.width)).toBe(550);
  await page.getByTestId('wall-right').dblclick();
  expect(Math.round((await page.getByTestId('browser').boundingBox())!.width)).toBe(430);
});

test('Ctrl+P is canceled even when a text field has focus', async ({ page }) => {
  await page.goto('/');
  await openCatalog(page);
  await page.evaluate(() => {
    document.body.dataset.printKeys = '';
    window.addEventListener('keydown', (event) => {
      if (event.ctrlKey && event.key.toLowerCase() === 'p') {
        document.body.dataset.printKeys += event.defaultPrevented ? '1' : '0';
      }
    });
  });
  await page.keyboard.press('Control+p');
  const search = page.getByTestId('browser-search');
  await search.focus();
  await page.keyboard.press('Control+p');
  await expect(page.locator('body')).toHaveAttribute('data-print-keys', '11');
  await expect(search).toBeFocused();
});

test('F5 keeps the focused library search and cancels browser reload', async ({ page }) => {
  await page.goto('/');
  await openCatalog(page);
  const search = page.getByTestId('browser-search');
  await search.fill('DSCF');
  await page.evaluate(() => {
    window.addEventListener('keydown', (event) => {
      if (event.key === 'F5') document.body.dataset.refreshCanceled = String(event.defaultPrevented);
    });
  });
  await page.keyboard.press('F5');
  await expect(page.locator('body')).toHaveAttribute('data-refresh-canceled', 'true');
  await expect(search).toHaveValue('DSCF');
  await expect(search).toBeFocused();
});

test('a window blur releases a held Original shortcut and preserves a latched Original', async ({ page }) => {
  await open(page);
  const original = page.getByTestId('tb-original');
  const showing = () => state<boolean>(page, 's.showingOriginal');
  const blur = () => page.evaluate(() => window.dispatchEvent(new Event('blur')));

  await page.keyboard.down('Space');
  await expect.poll(showing).toBe(true);
  // Windows can deliver the keyup to the next focused window instead.
  await blur();
  await expect.poll(showing, { timeout: 1000 }).toBe(false);
  await page.keyboard.up('Space');

  await page.keyboard.down('Backslash');
  await expect.poll(showing).toBe(true);
  await page.keyboard.up('Backslash');
  await expect.poll(showing).toBe(false);

  await original.click();
  await expect.poll(() => state<boolean>(page, 'u.originalLatched')).toBe(true);
  await page.keyboard.down('Space');
  await blur();
  await page.keyboard.up('Space');
  await expect.poll(showing).toBe(true);
  await original.click();
  await expect.poll(showing).toBe(false);
});

test('Ctrl+F opens the browser and focuses search when a narrow window folds it', async ({ page }) => {
  await page.goto('/');
  await openCatalog(page);
  await page.setViewportSize({ width: 960, height: 720 });
  const browser = page.getByTestId('browser');
  const search = page.getByTestId('browser-search');
  await expect(browser).toBeHidden();
  await page.keyboard.press('Control+f');
  await expect(browser).toHaveAttribute('data-mode', 'over');
  await expect(search).toBeFocused();
  await search.fill('DSCF');
  await expect(search).toHaveValue('DSCF');
  await page.keyboard.press('Control+f');
  await expect(search).toBeFocused();
  await expect(browser).toHaveAttribute('data-mode', 'over');
  await search.blur();
  await page.keyboard.press('F8');
  await expect(browser).toBeHidden();

  await page.setViewportSize({ width: 1536, height: 816 });
  await expect(browser).toHaveAttribute('data-mode', 'docked');
  await page.getByTestId('bar-split').click();
  await expect(browser).toBeHidden();
  await page.keyboard.press('Control+f');
  await expect(browser).toHaveAttribute('data-mode', 'docked');
  await expect(search).toBeFocused();
});

test('a Capture One source is read-only: a rating key says so and writes nothing', async ({ page }) => {
  await page.goto('/');
  await openCatalog(page, 'Archive');
  await page.getByTestId('library-tile').first().click();
  await expect(page.getByTestId('source-well')).toContainText('Read-only');
  const before = await state(page, 'l.images[0].rating');
  await page.keyboard.press('3');
  await expect(page.getByTestId('library-message')).toContainText('Ratings are set in Capture One');
  expect(await state(page, 'l.images[0].rating')).toBe(before);
});

test('a linked Capture One original can be located from its offline viewer', async ({ page }) => {
  await page.goto('/');
  await openCatalog(page, 'Archive');
  const photo = page.getByRole('button', { name: 'DSC_0001.NEF, Offline' });
  const uuid = await photo.getAttribute('data-uuid');
  await photo.click();
  await expect(page.getByTestId('viewer-strip')).toContainText('Offline');
  await page.getByRole('button', { name: 'Locate Folder…' }).click();
  await expect(page.getByTestId('viewer-strip')).not.toContainText('Offline');
  await expect(page.getByTestId('show-in-explorer')).toBeEnabled();
  await expect(page.getByRole('button', { name: 'DSC_0001.NEF, selected', exact: true })).toHaveAttribute('data-uuid', uuid!);
});

test('the source menu; the light table and the contact sheet stand above the shell', async ({ page }) => {
  await page.goto('/');
  await openCatalog(page);
  await page.getByTestId('source-well').click();
  await expect(page.getByTestId('source-menu')).toContainText('Open Capture One Catalog…');
  await page.keyboard.press('Escape');
  await page.keyboard.press('Control+Shift+L');
  await expect(page.getByTestId('light-table')).toBeVisible();
  // A full-window page: the column and the browser are under it.
  const pageBox = (await page.getByTestId('full-page').boundingBox())!;
  expect([Math.round(pageBox.x), Math.round(pageBox.width)]).toEqual([0, 1536]);
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('full-page')).toHaveCount(0);
  await page.getByTestId('new-contact-sheet').click();
  await expect(page.getByTestId('contact-sheet')).toBeVisible();
  await page.getByTestId('full-page-done').click();
  await expect(page.getByTestId('full-page')).toHaveCount(0);
});

test('menus and keys: Alt shows access keys, F10 opens File, a checked View item toggles, a field keeps its keys', async ({ page }) => {
  await open(page);
  await page.keyboard.press('Alt');
  await expect(page.locator('.access.shown').first()).toBeVisible();
  await page.keyboard.press('v');
  await expect(page.getByTestId('menu-view-list')).toBeVisible();
  await page.locator('[data-command="browser"]').click();
  await expect(page.getByTestId('browser')).toBeHidden();
  await page.keyboard.press('F8');
  await expect(page.getByTestId('browser')).toBeVisible();
  await page.keyboard.press('F10');
  await expect(page.getByTestId('menu-file-list')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('menu-file-list')).toHaveCount(0);
  await page.keyboard.press('Alt+f');
  await expect(page.getByTestId('menu-file-list')).toBeVisible();
  await page.keyboard.press('Escape');
  await page.getByLabel('Film Exposure, value').focus();
  await page.keyboard.press('Control+Alt+f');
  await expect(page.getByTestId('menu-file-list')).toHaveCount(0);
  await page.keyboard.press('Alt+f');
  await expect(page.getByTestId('menu-file-list')).toBeVisible();
  await page.keyboard.press('Escape');
  await page.getByLabel('Film Exposure, value').blur();
  // Ctrl+B (and F7) is the left column (PRD-W5 R5).
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

test('title menus keep arrow navigation in the menu and restore focus on Escape', async ({ page }) => {
  await open(page);
  // A camera exposure can have more precision than its one-decimal display.
  await page.evaluate(async () => {
    const { setCameraExposureTotal } = await import('/src/state/session.ts' as string);
    setCameraExposureTotal(1.674);
  });
  const field = page.getByLabel('Film Exposure, value');
  await field.focus();
  await page.keyboard.press('Alt+v');
  const view = page.getByTestId('menu-view-list');
  const left = view.locator('[data-command="leftColumn"]');
  const browser = view.locator('[data-command="browser"]');
  await expect(left).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(browser).toBeFocused();
  await page.keyboard.press('ArrowUp');
  await expect(left).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(view).toHaveCount(0);
  expect(await state(page, 's.sidecar.params.exposureBaselineEV + s.sidecar.params.exposureCompensationEV')).toBeCloseTo(1.674, 6);
  await expect(field).toBeFocused();

  await page.keyboard.press('Alt+v');
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('Enter');
  await expect(view).toHaveCount(0);
  await expect(page.getByTestId('browser')).toBeHidden();
  expect(await state(page, 's.selection')).toContain('DSC_0001');
  await field.fill('1.2');
  await field.press('Enter');
  expect(await state(page, 's.sidecar.params.exposureBaselineEV + s.sidecar.params.exposureCompensationEV')).toBeCloseTo(1.2, 6);
});


test('browser harness models double-click maximize on the title bar', async ({ page }) => {
  await open(page);
  const title = await page.getByTestId('window-title').boundingBox();
  expect(title).not.toBeNull();
  const surface = page.getByTestId('v2-window');
  await page.mouse.dblclick(title!.x + title!.width / 2, title!.y + title!.height / 2);
  await expect(surface).toHaveClass(/\bsquare\b/);
  await page.mouse.dblclick(title!.x + title!.width / 2, title!.y + title!.height / 2);
  await expect(surface).not.toHaveClass(/\bsquare\b/);
});


test('folded title menu enters and exits submenus with the keyboard', async ({ page }) => {
  await page.setViewportSize({ width: 540, height: 816 });
  await open(page);
  const trigger = page.getByTestId('menu-fold');
  await trigger.click();
  const file = page.getByTestId('menubar').locator('[data-submenu="file"]');
  await expect(file).toBeFocused();
  await page.keyboard.press('ArrowRight');
  const openPhoto = file.locator('[data-command="open"]');
  await expect(openPhoto).toBeFocused();
  await page.keyboard.press('ArrowLeft');
  await expect(openPhoto).toHaveCount(0);
  await expect(file).toBeFocused();
  await page.keyboard.press('Enter');
  await expect(openPhoto).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(file).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(file).toHaveCount(0);
  await expect(trigger).toBeFocused();
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
  await page.getByTestId('mode-library').click();
  await expect(page.getByTestId('first-run')).toHaveCount(0);
  await expect(page.getByTestId('source-well')).toBeVisible();
});

test('narrow windows fold the browser first, then the column; a folded pane comes over the picture, one at a time', async ({ page }) => {
  await open(page);
  // 1536: both docked. At 1000 the browser folds (column 320 + browser 240 + picture 480 = 1042).
  await page.setViewportSize({ width: 1000, height: 816 });
  await expect(page.getByTestId('rail-left')).toHaveAttribute('data-mode', 'docked');
  await expect(page.getByTestId('browser')).toBeHidden();
  await page.keyboard.press('F8');
  await expect(page.getByTestId('browser')).toHaveAttribute('data-mode', 'over');
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('browser')).toBeHidden();
  // A snapped half (768): the column folds as well.
  await page.setViewportSize({ width: 768, height: 816 });
  await expect(page.getByTestId('rail-left')).toHaveCount(0);
  await page.keyboard.press('F7');
  await expect(page.getByTestId('rail-left')).toHaveAttribute('data-mode', 'over');
  await page.keyboard.press('F8');
  // One at a time.
  await expect(page.getByTestId('browser')).toHaveAttribute('data-mode', 'over');
  await expect(page.getByTestId('rail-left')).toHaveCount(0);
  await page.keyboard.press('Escape');
  await page.setViewportSize({ width: 1536, height: 700 });
  await expect(page.getByTestId('navigator-line')).toBeVisible();
  // The picture bar's overflow (layout.ts): under 640 of picture the zoom and Original go into ···;
  // under 520, Compare and Paste as well. At 1000 wide the picture is 679 (the browser folded); at 1200, 480.
  await page.setViewportSize({ width: 1300, height: 816 });
  await expect(page.getByTestId('tb-zoom')).toHaveCount(0);
  await expect(page.getByTestId('tb-compare')).toBeVisible();
  await page.setViewportSize({ width: 1200, height: 816 });
  await expect(page.getByTestId('tb-compare')).toHaveCount(0);
  await page.getByTestId('tb-more').click();
  await expect(page.getByTestId('more-menu')).toContainText('Compare');
});

test('an overlay clears when its pane docks on a wider window', async ({ page }) => {
  await open(page);
  const browser = page.getByTestId('browser');
  await page.setViewportSize({ width: 960, height: 720 });
  await expect(browser).toBeHidden();
  await page.keyboard.press('F8');
  await expect(browser).toHaveAttribute('data-mode', 'over');
  await page.setViewportSize({ width: 1536, height: 816 });
  await expect(browser).toHaveAttribute('data-mode', 'docked');
  await page.keyboard.press('F8');
  await expect(browser).toBeHidden();
  await page.keyboard.press('F8');
  await expect(browser).toHaveAttribute('data-mode', 'docked');

  await page.setViewportSize({ width: 768, height: 720 });
  const column = page.getByTestId('rail-left');
  await page.keyboard.press('F7');
  await expect(column).toHaveAttribute('data-mode', 'over');
  await page.setViewportSize({ width: 1536, height: 816 });
  await expect(column).toHaveAttribute('data-mode', 'docked');
  await page.setViewportSize({ width: 768, height: 720 });
  await expect(column).toHaveCount(0);
});

test('1080p at 150 %: the column and the browser, the Navigator folded to one line', async ({ browser }) => {
  const context = await browser.newContext({ viewport: { width: 1280, height: 672 }, deviceScaleFactor: 1.5 });
  const page = await context.newPage();
  try {
    await open(page);
    await expect(page.getByTestId('rail-left')).toHaveAttribute('data-mode', 'docked');
    await expect(page.getByTestId('browser')).toHaveAttribute('data-mode', 'docked');
    await expect(page.getByTestId('navigator-line')).toBeVisible();
    const t = await page.getByTestId('titlebar').boundingBox();
    expect(Math.round(t!.height)).toBe(32);
  } finally { await context.close(); }
});

test('the column drags between 280 and 440 and a double-click puts it back to 320', async ({ page }) => {
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
