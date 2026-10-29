// Browser interaction coverage. Real source pixels and export math are checked
// separately against the freshly built Vulkan host.
import { expect, test, type Page } from '@playwright/test';
import type { sessionStore } from '../../src/state/session';
import type { frameImages } from '../../src/state/frames';
type App = { sessionStore: typeof sessionStore; frameImages: typeof frameImages };
const snapshot = (page: Page) => page.evaluate(() => {
  const app = (window as unknown as { __spk: App }).__spk;
  const s = app.sessionStore.getState(), image = app.frameImages.print;
  return { noFilm: s.sidecar.noFilm, params: s.sidecar.params, geometry: s.sidecar.geometry,
    exposure: s.sidecar.adjustments.exposure, path: s.selection, error: s.lastError,
    processedGeometry: image?.processedGeometry, width: image?.width, height: image?.height,
    checksum: image ? image.data.reduce((sum, byte, i) => i % 251 === 0 ? sum + byte : sum, 0) : null };
});
async function menu(page: Page) {
  await page.locator('[data-section=film]').getByRole('button', { name: 'More', exact: true }).click();
  return page.getByRole('menuitem', { name: /Don't Apply Film Simulation/ });
}
const full = (page: Page) => expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });

test('bypass retains edits, restores the film on selection, and survives reopen with a matching proof', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('sidecar:/mock/Roll 01/DSC_0001.NEF', JSON.stringify({
    params: { filmEdge: { active: true, format: '135', seeded: true }, dateBack: { active: true } },
    geometry: { crop: { x: .1, y: .1, width: .7, height: .6 }, quarterTurns: 1, flipH: true },
    adjustments: { exposure: .75 },
  })));
  await page.goto('/?open=&allFeatures=1'); await full(page);
  const before = await snapshot(page);
  await (await menu(page)).click(); await full(page);
  const bypass = await snapshot(page);
  expect(bypass.noFilm).toBe(true);
  expect(bypass.params).toEqual(before.params);
  expect(bypass.geometry).toEqual(before.geometry);
  expect(bypass.exposure).toBe(.75);
  expect(bypass.processedGeometry).toEqual(before.geometry);
  expect(bypass.checksum).not.toBe(before.checksum);
  await expect(page.getByTestId('no-film-state')).toBeVisible();
  await page.locator('[data-stock="kodak_portra_400"]').click(); await full(page);
  expect((await snapshot(page)).noFilm).toBe(false);
  await page.keyboard.press('Control+z'); await full(page);
  expect((await snapshot(page)).noFilm).toBe(true);
  await expect.poll(() => page.evaluate(() => JSON.parse(localStorage.getItem('sidecar:/mock/Roll 01/DSC_0001.NEF') ?? '{}').noFilm)).toBe(true);
  await page.locator('.thumb').nth(1).click(); await full(page);
  expect((await snapshot(page)).noFilm).toBe(false);
  await page.locator('.thumb').first().click(); await full(page);
  expect((await snapshot(page)).noFilm).toBe(true);
  expect((await snapshot(page)).checksum).toBe(bypass.checksum);
  await page.getByTestId('export-button').click();
  await expect(page.getByTestId('export-proof')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('proof-stats')).toContainText('Export proof');
  await page.screenshot({ path: test.info().outputPath('no-film-proof.png') });
});

test('an old host refuses a saved bypass and selecting a film recovers normal rendering', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('sidecar:/mock/Roll 01/DSC_0001.NEF', '{"noFilm":true}'));
  await page.goto('/?open=&noFilm=0');
  await expect.poll(async () => (await snapshot(page)).error).toMatch(/bypass film simulation/);
  expect((await snapshot(page)).checksum).toBeNull();
  await expect(page.getByTestId('no-film-state')).toContainText('cannot show');
  await expect(await menu(page)).toBeDisabled(); await page.keyboard.press('Escape');
  await page.locator('[data-stock="kodak_portra_400"]').click(); await full(page);
  expect((await snapshot(page)).noFilm).toBe(false);
});

test('half-frame pairs cannot enable film bypass', async ({ page }) => {
  await page.goto('/?open=&allFeatures=1'); await full(page);
  await page.locator('.thumb').nth(1).click({ modifiers: ['Control'] });
  await page.getByTestId('make-pair').click(); await full(page);
  await expect(await menu(page)).toBeDisabled();
  expect((await snapshot(page)).noFilm).toBe(false);
});
