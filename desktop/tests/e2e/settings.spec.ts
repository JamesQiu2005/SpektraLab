import { expect, test } from '@playwright/test';

test('settings distinguish browser-only capability gaps and never check updates on opening', async ({ page }) => {
  let updateRequests = 0;
  await page.route('https://api.github.com/**', async (route) => { updateRequests++; await route.abort(); });
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
  await page.keyboard.press('Control+,');
  const dialog = page.getByTestId('settings');
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole('button', { name: 'Check for Windows updates' })).toBeDisabled();
  expect(updateRequests).toBe(0);
  await dialog.getByRole('button', { name: 'Memory', exact: true }).click();
  await expect(dialog.getByTestId('memory-ledger')).toBeVisible();
  await expect(dialog.getByText('Available in the desktop application.')).toBeVisible();
  await dialog.getByRole('button', { name: 'Agents', exact: true }).click();
  await expect(dialog.getByText('Available in the desktop application.')).toBeVisible();
  await dialog.getByRole('button', { name: 'Diagnostics', exact: true }).click();
  await expect(dialog.getByRole('button', { name: 'Copy diagnostics' })).toBeVisible();
  await expect(dialog.getByText('Off by default.', { exact: false })).toBeVisible();
  expect(updateRequests).toBe(0);
});
