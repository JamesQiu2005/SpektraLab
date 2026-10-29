// 1.3.4's user-visible changes against the in-page mock host: CineStill 800T's
// Film Format rows, "Don't Apply Film Simulation", and the export page in Chinese.

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
const language = (page: Page, value: string) => page.evaluate((v) => (window as unknown as { __spk: { settingsStore: {
  getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', v), value);

test('CineStill 800T: the layer switch reads off and fixed, and the headroom sits under it', async ({ page }) => {
  await openRoll(page);
  await page.locator('[data-stock="cinestill_800t"]').click();
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('cinestill_800t');
  const layer = page.getByTestId('antihalation-toggle');
  await expect(layer).toHaveAttribute('aria-checked', 'false');
  await expect(layer).toHaveAttribute('aria-disabled', 'true');
  await expect(page.getByTestId('headroom-slider')).toContainText('Highlight Headroom');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.locator('[data-stock="kodak_vision3_500t"]').click();
  await expect(page.getByTestId('headroom-slider')).toHaveCount(0);
  await expect(page.getByTestId('antihalation-toggle')).toHaveAttribute('aria-checked', 'true');
});

test("Don't Apply Film Simulation: one undo step, the film comes back when a film is chosen, and it exports", async ({ page }) => {
  await openRoll(page);
  await page.locator('[data-section="film"] button[aria-label="More"]').click();
  await page.getByTestId('no-film-toggle').click();
  await expect.poll(() => state(page, 's.sidecar.noFilm')).toBe(true);
  await expect(page.getByTestId('histogram')).toBeVisible();
  // The decoded source is on the canvas (render_source); the film settings are untouched.
  await expect.poll(() => state(page, 's.hello.methods.includes("render_source")')).toBe(true);
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_400');
  await page.getByTestId('export-button').click();
  await page.getByTestId('export-run').click();
  await expect.poll(() => state(page, 's.batchExporting')).toBe(false);
  await expect(page.getByTestId('export-page')).toContainText('DSC_0001');
  await expect(page.getByTestId('export-page')).not.toContainText('Film Simulation');
  await page.keyboard.press('Escape');
  await page.keyboard.press('Control+z');
  await expect.poll(() => state(page, 's.sidecar.noFilm')).toBe(false);
  await page.keyboard.press('Control+Shift+z');
  await expect.poll(() => state(page, 's.sidecar.noFilm')).toBe(true);
  await page.locator('[data-stock="kodak_gold_200"]').click();
  await expect.poll(() => state(page, 's.sidecar.noFilm')).toBe(false);
});

test('the export page in Simplified Chinese', async ({ page }) => {
  await openRoll(page);
  await language(page, 'simplifiedChinese');
  await page.getByTestId('export-button').click();
  const exportPage = page.getByTestId('export-page');
  await expect(exportPage).toContainText('导出配方');
  await expect(exportPage).toContainText('格式与尺寸');
  await expect(exportPage).toContainText('已有文件');
  await language(page, 'english');
});
