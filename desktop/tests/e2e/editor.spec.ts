// Layout and behaviour of the editor against the in-page mock host.

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

test('the window: two rails, the bar, the canvas, the filmstrip', async ({ page }) => {
  await openRoll(page);
  await expect(page.getByTestId('left-rail')).toContainText('Film and Print');
  await expect(page.getByTestId('right-rail')).toContainText('Parameters');
  await expect(page.locator('.thumb')).toHaveCount(8);
  await expect(page.getByTestId('histogram')).toBeVisible();
  await expect(page.getByTestId('navigator').locator('canvas')).toBeVisible();
});

test('reopening one file after restart does not bring the previous roll back', async ({ page }) => {
  await openRoll(page);
  await expect(page.locator('.thumb')).toHaveCount(8);
  await page.evaluate(() => {
    const app = (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk;
    app.settingsStore.getState().set('lastFolder', '/mock/Roll 01');
  });
  await page.goto('/');
  await expect.poll(() => state(page, 's.hostState.phase')).toBe('ready');
  await expect(page.locator('.thumb')).toHaveCount(0);
  await page.evaluate(() => {
    (window as unknown as { __spkOpenPaths(p: string[]): void }).__spkOpenPaths(['/mock/Roll 01/new.ARW']);
  });
  await expect(page.locator('.thumb')).toHaveCount(1);
  await expect(page.locator('.thumb')).toContainText('new.ARW');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  expect(await state(page, 's.frames.map(f => f.path)')).toEqual(['/mock/Roll 01/new.ARW']);
});

test('a film edit reaches the sidecar and the engine', async ({ page }) => {
  await openRoll(page);
  await page.locator('[data-stock="kodak_gold_200"]').click();
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_gold_200');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_400');
});

test('a slide selection enables direct scanning, retains the paper and undoes as one edit', async ({ page }) => {
  await openRoll(page);
  const paper = await state(page, 's.sidecar.params.printStock');
  const version = await state(page, 's.imageVersion');
  await page.locator('[data-stock="fujifilm_provia_100f"]').click();
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(true);
  expect(await state(page, 's.sidecar.params.printStock')).toBe(paper);
  await expect.poll(() => state(page, 's.imageVersion')).toBeGreaterThan(version as number);
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_400');
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(false);
  expect(await state(page, 's.sidecar.params.printStock')).toBe(paper);
});

test('returning from a slide selects the negative target paper and restores the print stage', async ({ page }) => {
  await openRoll(page);
  const paper = await state(page, 's.sidecar.params.printStock');
  await page.locator('[data-stock="fujifilm_provia_100f"]').click();
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(true);
  await page.locator('[data-stock="kodak_ektar_100"]').click();
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(false);
  expect(await state(page, 's.sidecar.params.printStock')).toBe('kodak_portra_endura');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('fujifilm_provia_100f');
  expect(await state(page, 's.sidecar.params.scanFilm')).toBe(true);
  expect(await state(page, 's.sidecar.params.printStock')).toBe(paper);
});

test('trap 32: an arrow typed in a field does not change the frame', async ({ page }) => {
  await openRoll(page);
  const first = await state(page, 's.selection');
  const field = page.getByRole('textbox', { name: 'Film Exposure value' });
  await field.click();
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowRight');
  expect(await state(page, 's.selection')).toBe(first);
  await page.keyboard.press('Escape');
  await page.getByTestId('canvas').click();
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => state(page, 's.selection')).not.toBe(first);
});

test('Escape cancels a slider draft without adding history; Enter and blur commit', async ({ page }) => {
  await openRoll(page);
  const field = page.getByRole('textbox', { name: 'Film Exposure value', exact: true });
  const before = await state(page, 's.sidecar.params.exposureCompensationEV');
  const history = await state(page, 's.undo.length');
  await field.fill('2');
  await field.press('Escape');
  expect(await state(page, 's.sidecar.params.exposureCompensationEV')).toBe(before);
  expect(await state(page, 's.undo.length')).toBe(history);
  await expect(field).not.toBeFocused();
  await field.fill('1');
  await field.press('Enter');
  await expect.poll(() => state(page, 's.sidecar.params.exposureCompensationEV')).toBe(1);
  await field.fill('3');
  await field.press('Tab');
  await expect.poll(() => state(page, 's.sidecar.params.exposureCompensationEV')).toBe(3);
});

test('Escape cancels a unit draft without adding history; Enter and blur commit', async ({ page }) => {
  await openRoll(page);
  const section = page.locator('[data-section="filmFormat"]');
  await section.getByRole('button', { name: '135', exact: true }).click();
  await page.getByRole('menuitem', { name: 'Custom', exact: true }).click();
  const field = section.locator('.unit-field');
  const before = await state(page, 's.sidecar.params.sideLengthMM');
  const history = await state(page, 's.undo.length');
  await field.fill('50');
  await field.press('Escape');
  expect(await state(page, 's.sidecar.params.sideLengthMM')).toBe(before);
  expect(await state(page, 's.undo.length')).toBe(history);
  await expect(field).not.toBeFocused();
  await field.fill('36');
  await field.press('Enter');
  await expect.poll(() => state(page, 's.sidecar.params.sideLengthMM')).toBe(36);
  await field.fill('40');
  await field.press('Tab');
  await expect.poll(() => state(page, 's.sidecar.params.sideLengthMM')).toBe(40);
});

test('a quarter turn swaps the output size readout', async ({ page }) => {
  await openRoll(page);
  const before = await page.getByTestId('crop-size').textContent();
  await page.getByTestId('rotate-right').click();
  const after = await page.getByTestId('crop-size').textContent();
  const [w, h] = before!.split(' · ')[0]!.split(' × ');
  expect(after!.startsWith(`${h} × ${w}`)).toBe(true);
});

test('the language switch renames the rails', async ({ page }) => {
  await openRoll(page);
  await page.evaluate(() => (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', 'simplifiedChinese'));
  await expect(page.getByTestId('left-rail')).toContainText('胶片与相纸');
  await page.evaluate(() => (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', 'english'));
  await expect(page.getByTestId('left-rail')).toContainText('Film and Print');
});

test('the export page names the file and holds the frame while it runs', async ({ page }) => {
  await openRoll(page);
  await page.getByTestId('export-button').click();
  await expect(page.getByTestId('export-page')).toBeVisible();
  await expect(page.getByTestId('export-sample')).toContainText('DSC_0001_Portra_400');
  await page.getByTestId('export-run').click();
  await expect.poll(() => state(page, 's.batchExporting')).toBe(false);
  await expect(page.getByTestId('export-page')).toContainText('DSC_0001');
});


for (const scale of [100, 115, 130]) {
  test(`feedback: Chinese clipboard and filmstrip fit at ${scale}%`, async ({ page }) => {
    await openRoll(page);
    await page.evaluate((scale) => {
      const spk = (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: unknown): void } } } }).__spk;
      spk.settingsStore.getState().set('interfaceScale', scale);
      spk.settingsStore.getState().set('language', 'simplifiedChinese');
    }, scale);
    await page.getByTestId('canvas').click();
    await page.keyboard.press('Control+a');
    expect(await state(page, 's.picked.length')).toBe(8);
    const buttons = page.locator('.clipboard-actions button');
    await expect(buttons).toHaveCount(3);
    for (const b of await buttons.all()) {
      expect(await b.evaluate((el) => el.scrollWidth <= el.clientWidth && el.scrollHeight <= el.clientHeight)).toBe(true);
    }
    const fits = await page.locator('.thumb-name').evaluateAll((names) => names.every((el) => {
      const a = el.getBoundingClientRect();
      const strip = el.closest('.filmstrip-cells')!;
      const b = strip.getBoundingClientRect();
      return a.bottom <= b.top + strip.clientHeight && a.top >= b.top;
    }));
    expect(fits).toBe(true);
    await page.screenshot({ path: `D:/SpektraLab-win/validation/feedback-20261012/layout-${scale}.png` });
  });
}

test('feedback: built-in export recipes remain reusable after custom edits', async ({ page }) => {
  await openRoll(page);
  await page.getByTestId('export-button').click();
  await page.getByTestId('export-page').getByRole('button', { name: 'JPEG', exact: true }).click();
  await page.getByRole('menuitem', { name: 'PNG', exact: true }).click();
  await expect(page.getByTestId('recipe-summary')).toContainText('PNG');
  await page.locator('.recipe-list .stock-row').first().click();
  await expect(page.getByTestId('recipe-summary')).toHaveText('JPEG · 8 bit · Display P3');
  await page.locator('.recipe-list .stock-row').last().click();
  await expect(page.getByTestId('recipe-summary')).toContainText('PNG');
});

test('feedback: reset layout restores visibility, scale and sections', async ({ page }) => {
  await openRoll(page);
  await page.evaluate(() => {
    const spk = (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: unknown): void } } } }).__spk;
    for (const [k,v] of Object.entries({ interfaceScale: 130, leftCollapsed: true, filmstripCollapsed: true, collapsedSections: { film: true } })) spk.settingsStore.getState().set(k,v);
  });
  await page.keyboard.press('Control+,');
  await page.getByRole('button', { name: 'Reset All Layout', exact: true }).click();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('left-rail')).toBeVisible();
  await expect(page.getByTestId('filmstrip')).toBeVisible();
  await expect(page.locator('[data-stock="kodak_gold_200"]')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.style.getPropertyValue('--ui-scale'))).toBe('1.15');
});
