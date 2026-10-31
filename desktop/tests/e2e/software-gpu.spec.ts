// The mock host as a CPU rasterizer (`?gpu=software`): the preview edge
// follows the device until the user picks one in Settings.

import { expect, test, type Page } from '@playwright/test';

type App = { settingsStore: { getState(): { previewLongEdge: number; set(k: string, v: unknown): void } } };
const edge = (page: Page) => page.evaluate(() => (window as unknown as { __spk: App }).__spk.settingsStore.getState().previewLongEdge);

test('a software device lowers the preview edge, hardware restores it, a choice in Settings is kept', async ({ page }) => {
  await page.goto('/?open=&gpu=software');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await expect.poll(() => edge(page)).toBe(1080);
  await page.keyboard.press('Control+,');
  await page.getByRole('button', { name: /rendering|渲染/i }).click();
  await expect(page.getByRole('dialog')).toContainText('1080 px');
  await expect(page.getByRole('dialog')).toContainText('llvmpipe');
  await page.keyboard.press('Escape');

  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await expect.poll(() => edge(page)).toBe(2560);

  await page.evaluate(() => { const s = (window as unknown as { __spk: App }).__spk.settingsStore.getState(); s.set('previewLongEdge', 1920); s.set('previewLongEdgeChosen', true); });
  await page.goto('/?open=&gpu=software');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await expect.poll(() => edge(page)).toBe(1920);
});
