import { expect, test, type Page } from '@playwright/test';

const viewState = (page: Page) => page.evaluate(() => {
  const { sessionStore } = (window as unknown as { __spk: { sessionStore: { getState(): {
    view: { fit: boolean; zoom: number; cx: number; cy: number }; fitZoom: number;
    sidecar: unknown; undo: unknown[];
  } } } }).__spk;
  const s = sessionStore.getState();
  return { ...s.view, fitZoom: s.fitZoom, sidecar: s.sidecar, undo: s.undo.length };
});

test('Ctrl-wheel crosses below fit, keeps shrinking, and zooms back in without editing the photo', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
  const before = await viewState(page);
  expect(before.fit).toBe(true);
  const box = (await page.getByTestId('canvas').boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.keyboard.down('Control');
  await page.mouse.wheel(0, 25);
  await expect.poll(async () => (await viewState(page)).fit).toBe(false);
  const first = await viewState(page);
  expect(first.zoom).toBeLessThan(before.fitZoom);
  await page.mouse.wheel(0, 25);
  await expect.poll(async () => (await viewState(page)).zoom).toBeLessThan(first.zoom);
  await page.mouse.wheel(0, -75);
  await expect.poll(async () => (await viewState(page)).zoom).toBeGreaterThan(before.fitZoom);
  await page.keyboard.up('Control');
  const after = await viewState(page);
  expect(after.sidecar).toEqual(before.sidecar);
  expect(after.undo).toBe(before.undo);
  await page.keyboard.press('Control+0');
  await expect.poll(async () => (await viewState(page)).fit).toBe(true);
  await page.keyboard.press('Control+-');
  const stepped = await viewState(page);
  expect(stepped.fit).toBe(false);
  expect(stepped.zoom).toBeLessThan(before.fitZoom);
});

test('wheel zoom stays bounded and crop mode does not consume it as a view change', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
  const before = await viewState(page);
  const box = (await page.getByTestId('canvas').boundingBox())!;
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.keyboard.down('Control');
  await page.mouse.wheel(0, 10000);
  const minimum = Math.min(.05, before.fitZoom / 2);
  await expect.poll(async () => (await viewState(page)).zoom).toBe(minimum);
  await page.mouse.wheel(0, -10000);
  await expect.poll(async () => (await viewState(page)).zoom).toBe(16);
  await page.keyboard.up('Control');
  await page.keyboard.press('c');
  const cropView = await viewState(page);
  await page.keyboard.down('Control');
  await page.mouse.wheel(0, 250);
  await page.keyboard.up('Control');
  const after = await viewState(page);
  expect(after.zoom).toBe(cropView.zoom);
  expect(after.fit).toBe(cropView.fit);
  expect(after.sidecar).toEqual(cropView.sidecar);
});
