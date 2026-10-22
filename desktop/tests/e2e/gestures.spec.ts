import { expect, test, type Page } from '@playwright/test';
const state = (page: Page, expr: string) => page.evaluate((e) => {
  const app = (window as unknown as { __spk: { sessionStore: { getState(): unknown }; settingsStore: { getState(): unknown } } }).__spk;
  return new Function('s', 'settings', `return ${e}`)(app.sessionStore.getState(), app.settingsStore.getState());
}, expr);
async function open(page: Page) {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
}
test('filmstrip drag reorders without switching the editor and persists on reopening the same roll', async ({ page }) => {
  await open(page);
  const before = await state(page, '({ paths:s.frames.map(f=>f.path), selected:s.selection, params:s.sidecar.params })');
  await page.evaluate(() => window.addEventListener('dragstart', (e) => { e.preventDefault(); e.stopImmediatePropagation(); }, true));
  const from = (await page.locator('.thumb').nth(0).boundingBox())!, to = (await page.locator('.thumb').nth(2).boundingBox())!;
  await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2); await page.mouse.down();
  await page.mouse.move(to.x + to.width / 2, to.y + to.height / 2, { steps: 8 }); await page.mouse.up();
  const paths = await state(page, 's.frames.map(f=>f.path)');
  expect(paths.slice(0, 3)).toEqual([before.paths[1], before.paths[2], before.paths[0]]);
  expect(await state(page, 's.selection')).toBe(before.selected);
  expect(await state(page, 's.sidecar.params')).toEqual(before.params);
  await page.reload();
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  expect(await state(page, 's.frames.map(f=>f.path)')).toEqual(paths);
});
test('panel handles track a bounded drag, reset on double-click, and retain widths across reload', async ({ page }) => {
  await open(page);
  const handle = page.getByRole('separator', { name: 'Resize left panel' });
  const box = (await handle.boundingBox())!;
  await page.mouse.move(box.x + 3, box.y + 200); await page.mouse.down();
  await page.mouse.move(box.x + 73, box.y + 200, { steps: 5 }); await page.mouse.up();
  expect(await state(page, 'settings.leftWidth')).toBe(324);
  await page.reload(); await expect(handle).toHaveAttribute('aria-valuenow', '324');
  await handle.dblclick(); expect(await state(page, 'settings.leftWidth')).toBe(254);
});
test('Ctrl-drag draws a straighten guide and commits a reversible geometry edit on release', async ({ page }) => {
  await open(page);
  await page.keyboard.press('c');
  const canvas = page.getByTestId('canvas'), box = (await canvas.boundingBox())!;
  const undo = await state(page, 's.undo.length');
  const from = { x: box.x + box.width * .35, y: box.y + box.height * .45 };
  const to = { x: box.x + box.width * .65, y: from.y + 30 };
  await page.keyboard.down('Control'); await page.mouse.move(from.x, from.y); await page.mouse.down();
  await page.mouse.move(to.x, to.y, { steps: 5 });
  await expect(page.getByTestId('straighten-line')).toBeVisible();
  expect(await state(page, 's.sidecar.geometry.angle')).toBe(0);
  await page.mouse.up(); await page.keyboard.up('Control');
  await expect(page.getByTestId('straighten-line')).toHaveCount(0);
  expect(Math.abs(await state(page, 's.sidecar.geometry.angle'))).toBeGreaterThan(1);
  expect(await state(page, 's.undo.length')).toBe(undo + 1);
  await page.keyboard.press('Control+z'); expect(await state(page, 's.sidecar.geometry.angle')).toBe(0);
});
