// Open Recent on the top bar, against the in-page mock host: a folder that
// was opened is offered again after a restart; the list can be cleared.

import { expect, test } from '@playwright/test';

test('a folder opened at launch is offered under Open Recent, survives a restart and can be cleared', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.getByTestId('recent-button').click();
  const menu = page.getByTestId('recent-menu');
  await expect(menu.getByRole('menuitem', { name: 'Roll 01' })).toBeVisible();
  await page.keyboard.press('Escape');

  // A restart without a roll: nothing opens by itself, the folder is still offered.
  await page.goto('/');
  await expect.poll(() => page.locator('.thumb').count()).toBe(0);
  await page.getByTestId('recent-button').click();
  await page.getByTestId('recent-menu').getByRole('menuitem', { name: 'Roll 01' }).click();
  await expect(page.locator('.thumb')).toHaveCount(8);
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });

  await page.getByTestId('recent-button').click();
  await page.getByTestId('recent-menu').getByRole('menuitem', { name: 'Clear Menu' }).click();
  await page.getByTestId('recent-button').click();
  await expect(page.getByTestId('recent-menu')).toContainText('No recent folders');
});
