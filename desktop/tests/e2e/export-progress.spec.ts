// The export page against the in-page mock host: the host's progress events
// drive a bar, and the finished batch is announced once the page is free.

import { expect, test } from '@playwright/test';

test('export shows the host’s progress and announces the finished batch', async ({ page }) => {
  const dialogs: string[] = [];
  page.on('dialog', (dialog) => { dialogs.push(dialog.message()); void dialog.accept(); });
  await page.goto('/?open=&renderDelay=300');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.getByTestId('export-button').click();
  await page.getByTestId('export-run').click();
  const bar = page.getByTestId('export-progress');
  await expect(bar).toBeVisible();
  await expect.poll(async () => Number(await bar.getAttribute('aria-valuenow'))).toBeGreaterThan(0);
  await expect(bar).toHaveAttribute('aria-valuenow', '100', { timeout: 20_000 });
  await expect(page.getByTestId('export-status')).toContainText('1 of 1 processed');
  await expect.poll(() => dialogs.length).toBe(1);
  expect(dialogs[0]).toContain('Export finished');
  expect(dialogs[0]).toContain('1 written, 0 skipped, 0 failed.');
  // The page is usable again: the Export button is back.
  await expect(page.getByTestId('export-run')).toBeVisible();
});
