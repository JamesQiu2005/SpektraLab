import { expect, test, type Page } from '@playwright/test';
import type { sessionStore } from '../../src/state/session';
import type { settingsStore } from '../../src/state/settings';

type App = { sessionStore: typeof sessionStore; settingsStore: typeof settingsStore };
const exposure = (page: Page) => page.evaluate(() =>
  { const p = (window as unknown as { __spk: App }).__spk.sessionStore.getState().sidecar.params;
    return p.exposureBaselineEV + p.exposureCompensationEV; });

async function openRoll(page: Page, allFeatures = false) {
  await page.goto(allFeatures ? '/?open=&allFeatures=1' : '/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
}

test('negative input keeps its sign on Enter, blur, unchanged focus, and undo', async ({ page }) => {
  await openRoll(page);
  const field = page.getByRole('textbox', { name: 'Film Exposure value', exact: true });
  await field.fill('−2'); await field.press('Enter');
  await expect.poll(() => exposure(page)).toBeCloseTo(-2);
  await field.focus(); await field.press('Tab');
  expect(await exposure(page)).toBeCloseTo(-2);
  await field.fill('−1,5'); await field.press('Tab');
  await expect.poll(() => exposure(page)).toBeCloseTo(-1.5);
  await field.fill('-3'); await field.press('Enter');
  await expect.poll(() => exposure(page)).toBeCloseTo(-3);
  await page.keyboard.press('Control+z');
  await expect.poll(() => exposure(page)).toBeCloseTo(-1.5);
});

test('film edge locks format controls and releases the saved custom dimensions', async ({ page }) => {
  await openRoll(page, true);
  const size = page.getByTestId('film-format-size');
  const section = page.locator('[data-section=filmFormat]');
  const field = section.locator('.unit-field');
  await expect(field).toBeDisabled();
  await size.click(); await page.getByRole('menuitem', { name: 'Custom', exact: true }).click();
  await field.fill('42'); await field.press('Enter');
  await page.getByTestId('film-format-side').click();
  await page.getByRole('menuitem', { name: 'Long', exact: true }).click();
  await page.getByTestId('film-edge-enable').click();
  await expect(size).toBeDisabled();
  await expect(size).toHaveAttribute('title', /Set by Film Edge/);
  await expect(page.getByTestId('film-format-side')).toBeDisabled();
  await expect(page.getByTestId('film-format-unit')).toBeDisabled();
  await expect(field).toBeDisabled();
  await page.getByTestId('film-edge-enable').click();
  await expect(size).toBeEnabled();
  await expect(size).toContainText('Custom');
  await expect(field).toBeEnabled();
  await expect(field).toHaveValue('42.0');
  await expect(page.getByTestId('film-format-side')).toContainText('Long');
});

for (const language of ['english', 'simplifiedChinese'] as const) {
  for (const scale of [100, 115, 130] as const) {
    test(`alignment capture: ${language} ${scale}% with a 280-unit right rail`, async ({ page }) => {
      await openRoll(page);
      await page.evaluate(({ language, scale }) => {
        const settings = (window as unknown as { __spk: App }).__spk.settingsStore.getState();
        settings.set('language', language); settings.set('interfaceScale', scale);
        settings.set('rightWidth', 268);
      }, { language, scale });
      await expect(page.locator('.panel-resize.right')).toHaveAttribute('aria-valuenow', '280');
      await expect(page.getByTestId('film-format-size')).toBeVisible();
      const inside = await page.getByTestId('film-format-size').evaluate((el) => {
        const control = el.getBoundingClientRect(), rail = el.closest('aside')!.getBoundingClientRect();
        return control.right <= rail.right && control.left >= rail.left;
      });
      expect(inside).toBe(true);
      await page.screenshot({ path: test.info().outputPath(`alignment-${language}-${scale}.png`) });
    });
  }
}
