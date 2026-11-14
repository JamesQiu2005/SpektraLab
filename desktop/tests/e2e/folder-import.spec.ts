import { expect, test } from '@playwright/test';

test('folder RAW filter is offered, remembered and does not filter explicitly selected JPEGs', async ({ page }) => {
  await page.goto('/');
  await page.getByTestId('open-button').click();
  const dialog = page.getByTestId('folder-import-dialog');
  await expect(dialog).toContainText('8 photographs');
  await dialog.getByRole('checkbox', { name: 'Import RAW files only' }).click();
  await dialog.getByRole('button', { name: 'Import', exact: true }).click();
  await expect(page.locator('.thumb')).toHaveCount(6);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.getByTestId('open-button').click();
  await expect(dialog.getByRole('checkbox')).toBeChecked();
  await dialog.getByRole('button', { name: 'Cancel' }).click();
  await expect(page.locator('.thumb')).toHaveCount(6);
  // The preference survives a reload, and a full-folder import can opt out.
  await page.reload();
  await page.getByTestId('open-button').click();
  await expect(dialog.getByRole('checkbox')).toBeChecked();
  await dialog.getByRole('checkbox').click();
  await dialog.getByRole('button', { name: 'Import', exact: true }).click();
  await expect(page.locator('.thumb')).toHaveCount(8);
  await page.getByTestId('open-button').click();
  await dialog.getByRole('checkbox').click();
  await dialog.getByRole('button', { name: 'Import', exact: true }).click();
  await page.evaluate(() => {
    (window as unknown as { __spkOpenPaths: (paths: string[]) => void }).__spkOpenPaths(['/mock/Roll 01/scan_0008.jpg']);
  });
  await expect(dialog).toHaveCount(0);
  await expect(page.locator('.thumb')).toHaveCount(1);
  await expect(page.locator('.thumb').first()).toContainText('scan_0008.jpg');
});
