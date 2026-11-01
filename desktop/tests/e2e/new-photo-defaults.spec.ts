import { expect, test, type Page } from '@playwright/test';
import type { sessionStore } from '../../src/state/session';
import type { settingsStore } from '../../src/state/settings';

type App = { sessionStore: typeof sessionStore; settingsStore: typeof settingsStore };
const stocks = (page: Page) => page.evaluate(() => {
  const s = (window as unknown as { __spk: App }).__spk.sessionStore.getState();
  return { film: s.sidecar.params.filmStock, paper: s.sidecar.params.printStock, scan: s.sidecar.params.scanFilm };
});

async function preferences(page: Page) {
  await page.keyboard.press('Control+,');
  await expect(page.getByTestId('settings')).toBeVisible();
  await page.getByRole('button', { name: 'General', exact: true }).click();
}

async function openPhoto(page: Page, path: string) {
  await page.evaluate((p) => (window as unknown as { __spkOpenPaths(paths: string[]): void }).__spkOpenPaths([p]), path);
  await expect.poll(() => page.evaluate(() => (window as unknown as { __spk: App }).__spk.sessionStore.getState().selection)).toBe(path);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
}

test('new-photo preferences survive restart and preserve the current and saved photographs', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const current = await stocks(page);
  await preferences(page);
  await page.getByTestId('new-photo-film').click();
  await page.getByRole('menuitem', { name: 'Kodak Gold 200', exact: true }).click();
  await page.getByTestId('new-photo-paper').click();
  await page.getByRole('menuitem', { name: 'Kodak Vision 2383', exact: true }).click();
  expect(await stocks(page)).toEqual(current);
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await openPhoto(page, '/mock/New defaults/first.ARW');
  expect(await stocks(page)).toEqual({ film: 'kodak_gold_200', paper: 'kodak_2383', scan: false });
  await page.locator('[data-stock="kodak_ektar_100"]').click();
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  // Opening a second photo flushes the first photo's edits before restart.
  await openPhoto(page, '/mock/New defaults/second.ARW');
  await page.goto('/');
  await expect.poll(() => page.evaluate(() => (window as unknown as { __spk: App }).__spk.sessionStore.getState().hostState.phase)).toBe('ready');
  await openPhoto(page, '/mock/New defaults/first.ARW');
  expect((await stocks(page)).film).toBe('kodak_ektar_100');
  await openPhoto(page, '/mock/New defaults/third.ARW');
  expect(await stocks(page)).toEqual({ film: 'kodak_gold_200', paper: 'kodak_2383', scan: false });
});

test('settings offer compatible silver paper, direct scans and a reset without editing the open photo', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await preferences(page);
  await page.getByTestId('new-photo-film').click();
  await page.getByRole('menuitem', { name: 'Kodak Tri-X 400', exact: true }).click();
  await expect(page.getByTestId('new-photo-paper')).toHaveText('Ilford Multigrade IV RC');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await openPhoto(page, '/mock/New defaults/silver.ARW');
  expect(await stocks(page)).toEqual({ film: 'kodak_tri_x_400', paper: 'ilford_multigrade_iv_rc', scan: false });
  await preferences(page);
  await page.getByTestId('new-photo-film').click();
  await page.getByRole('menuitem', { name: 'Fujifilm Provia 100F', exact: true }).click();
  await expect(page.getByTestId('new-photo-paper')).toBeDisabled();
  await expect(page.getByTestId('new-photo-paper')).toHaveText('Direct scan (no paper)');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await openPhoto(page, '/mock/New defaults/slide.ARW');
  expect((await stocks(page)).scan).toBe(true);
  await preferences(page);
  await page.getByRole('button', { name: 'Restore stock defaults', exact: true }).click();
  await expect(page.getByTestId('new-photo-film')).toHaveText('Kodak Portra 400');
  expect((await stocks(page)).film).toBe('fujifilm_provia_100f');
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await openPhoto(page, '/mock/New defaults/reset.ARW');
  expect(await stocks(page)).toEqual({ film: 'kodak_portra_400', paper: 'kodak_supra_endura', scan: false });
});
