// Layout and behaviour of the editor against the in-page mock host.

import { expect, test, type Page } from '@playwright/test';

async function openRoll(page: Page) {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
}

const state = (page: Page, expr: string) =>
  page.evaluate((e) => {
    const s = (window as unknown as { __spk: { sessionStore: { getState(): unknown } } }).__spk.sessionStore.getState();
    return new Function('s', `return ${e}`)(s);
  }, expr);

test('the window: two rails, the bar, the canvas, the filmstrip', async ({ page }) => {
  await openRoll(page);
  await expect(page.getByTestId('left-rail')).toContainText('Film and Print');
  await expect(page.getByTestId('right-rail')).toContainText('Parameters');
  await expect(page.locator('.thumb')).toHaveCount(8);
  await expect(page.getByTestId('histogram')).toBeVisible();
  await expect(page.getByTestId('navigator').locator('canvas')).toBeVisible();
});

test('a film edit reaches the sidecar and the engine', async ({ page }) => {
  await openRoll(page);
  await page.locator('[data-stock="kodak_gold_200"]').click();
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_gold_200');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_400');
});

test('a slide selection enables direct scanning, retains the paper and undoes as one edit', async ({ page }) => {
  await openRoll(page);
  const paper = await state(page, 's.sidecar.params.printStock');
  const version = await state(page, 's.imageVersion');
  await page.locator('[data-stock="fujifilm_provia_100f"]').click();
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(true);
  expect(await state(page, 's.sidecar.params.printStock')).toBe(paper);
  await expect.poll(() => state(page, 's.imageVersion')).toBeGreaterThan(version as number);
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_400');
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(false);
  expect(await state(page, 's.sidecar.params.printStock')).toBe(paper);
});

test('returning from a slide to a negative restores the print stage', async ({ page }) => {
  await openRoll(page);
  const paper = await state(page, 's.sidecar.params.printStock');
  await page.locator('[data-stock="fujifilm_provia_100f"]').click();
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(true);
  await page.locator('[data-stock="kodak_ektar_100"]').click();
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(false);
  expect(await state(page, 's.sidecar.params.printStock')).toBe(paper);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('fujifilm_provia_100f');
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(true);
});

test('trap 32: an arrow typed in a field does not change the frame', async ({ page }) => {
  await openRoll(page);
  const first = await state(page, 's.selection');
  const field = page.getByRole('textbox', { name: 'Film Exposure value' });
  await field.click();
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowRight');
  expect(await state(page, 's.selection')).toBe(first);
  await page.keyboard.press('Escape');
  await page.getByTestId('canvas').click();
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => state(page, 's.selection')).not.toBe(first);
});

test('a quarter turn swaps the output size readout', async ({ page }) => {
  await openRoll(page);
  const before = await page.getByTestId('crop-size').textContent();
  await page.getByTestId('rotate-right').click();
  const after = await page.getByTestId('crop-size').textContent();
  const [w, h] = before!.split(' · ')[0]!.split(' × ');
  expect(after!.startsWith(`${h} × ${w}`)).toBe(true);
});

test('the language switch renames the rails', async ({ page }) => {
  await openRoll(page);
  await page.evaluate(() => (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', 'simplifiedChinese'));
  await expect(page.getByTestId('left-rail')).toContainText('胶片与相纸');
  await page.evaluate(() => (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', 'english'));
  await expect(page.getByTestId('left-rail')).toContainText('Film and Print');
});

test('the export page names the file and holds the frame while it runs', async ({ page }) => {
  await openRoll(page);
  await page.getByTestId('export-button').click();
  await expect(page.getByTestId('export-page')).toBeVisible();
  await expect(page.getByTestId('export-sample')).toContainText('DSC_0001_Portra_400');
  await page.getByTestId('export-run').click();
  await expect.poll(() => state(page, 's.batchExporting')).toBe(false);
  await expect(page.getByTestId('export-page')).toContainText('DSC_0001');
});
