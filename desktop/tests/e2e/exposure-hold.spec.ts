import { expect, test } from '@playwright/test';
import type { sessionStore } from '../../src/state/session';

test('auto reading is visible; custom, slider, undo, reload and As Shot preserve the exposure contract', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const field = page.getByTestId('film-exposure').locator('input');
  const metering = page.getByTestId('metering');
  const read = () => page.evaluate(() => (window as unknown as { __spk: { sessionStore: typeof sessionStore } }).__spk.sessionStore.getState().sidecar);
  await expect(field).toHaveValue('+0.3');
  await field.focus(); await field.press('Tab');
  await expect(metering).toContainText('Balanced');
  const before = await read();
  await metering.click(); await page.getByRole('menuitem', { name: 'Custom', exact: true }).click();
  await expect(field).toHaveValue('+0.3');
  expect((await read()).params).toEqual({ ...before.params, autoExposure: false, exposureBaselineEV: .3 });
  await page.keyboard.press('Control+z');
  await expect(metering).toContainText('Balanced');
  await field.press('ArrowUp');
  await expect(metering).toContainText('Custom');
  expect((await read()).params.exposureBaselineEV).toBeCloseTo(.3 + 1 / 3);
  expect((await read()).params.exposureCompensationEV).toBe(0);
  expect((await read()).decode).toEqual(before.decode);
  expect((await read()).adjustments).toEqual(before.adjustments);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  // Wait for the actual sidecar write before reopening the app.
  await expect.poll(() => page.evaluate(() => Object.values(localStorage).some((v) => v.includes('"exposureBaselineEV":0.6333') && v.includes('"autoExposure":false')))).toBe(true);
  await page.reload(); await expect(field).toHaveValue('+0.6');
  await expect(metering).toContainText('Custom');
  await page.getByTestId('film-exposure').getByRole('checkbox').click();
  await expect(field).toHaveValue('0.0');
  expect((await read()).params).toMatchObject({ autoExposure: false, exposureBaselineEV: 0, exposureCompensationEV: 0 });
  await field.fill('0.3'); await field.press('Enter');
  expect((await read()).params).toMatchObject({ autoExposure: false, exposureBaselineEV: .3, exposureCompensationEV: 0 });
  await metering.click(); await page.getByRole('menuitem', { name: 'Protect highlights', exact: true }).click();
  await expect(field).toHaveValue('−0.4');
  await page.getByTestId('film-exposure').getByRole('slider').click({ position: { x: 60, y: 5 } });
  await expect(metering).toContainText('Custom');
});
