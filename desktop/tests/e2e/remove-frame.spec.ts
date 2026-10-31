// Removing frames from the roll through the filmstrip's menu, against the
// in-page mock host.

import { expect, test, type Page } from '@playwright/test';

const state = (page: Page, expr: string) =>
  page.evaluate((e) => {
    const s = (window as unknown as { __spk: { sessionStore: { getState(): unknown } } }).__spk.sessionStore.getState();
    return new Function('s', `return ${e}`)(s);
  }, expr);

test('a frame leaves the roll from the filmstrip menu; the open frame hands over to its neighbour', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await expect(page.locator('.thumb')).toHaveCount(8);
  await page.locator('.thumb').nth(3).click({ button: 'right' });
  const menu = page.getByTestId('filmstrip-menu');
  await expect(menu).toBeVisible();
  await menu.getByRole('menuitem', { name: 'Remove from the roll' }).click();
  await expect(page.locator('.thumb')).toHaveCount(7);
  await expect(menu).toHaveCount(0);
  expect(await state(page, 's.frames.map(f => f.name)')).not.toContain('DSC_0004.ARW');

  // The open frame (the first) goes: the second takes the canvas.
  expect(await state(page, 's.selection')).toBe('/mock/Roll 01/DSC_0001.NEF');
  await page.locator('.thumb').first().click({ button: 'right' });
  await page.getByTestId('filmstrip-menu').getByRole('menuitem', { name: 'Remove from the roll' }).click();
  await expect(page.locator('.thumb')).toHaveCount(6);
  await expect.poll(() => state(page, 's.selection')).toBe('/mock/Roll 01/DSC_0002.NEF');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
});
