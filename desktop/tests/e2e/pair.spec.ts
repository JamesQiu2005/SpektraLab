// Browser controls use synthetic pair pixels; native source/layer correctness
// is covered separately by the host and Vulkan pair tests.
import { expect, test, type Page } from '@playwright/test';
const state = (page: Page, expr: string) => page.evaluate((e) => {
  const s = (window as unknown as { __spk: { sessionStore: { getState(): unknown } } }).__spk.sessionStore.getState();
  return new Function('s', `return ${e}`)(s);
}, expr);
async function open(page: Page, renderDelay = 0) {
  await page.goto(`/?open=&renderDelay=${renderDelay}`);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
}
test('creates a pair in strip order, edits one hole, and reloads the owned recipe with the folder', async ({ page }) => {
  await open(page);
  await page.locator('.thumb').nth(1).click({ modifiers: ['Control'] });
  await page.getByTestId('make-pair').click();
  await expect(page.getByTestId('pair-overlay')).toBeVisible();
  await expect.poll(() => state(page, 's.pairInfo?.right?.available')).toBe(true);
  const savedPath = await state(page, 's.selection');
  expect(await state(page, '[s.pair.left.path,s.pair.right.path]')).toEqual(['/mock/Roll 01/DSC_0001.NEF', '/mock/Roll 01/DSC_0002.NEF']);
  await expect(page.getByTestId('export-button')).toBeEnabled();
  await page.getByTestId('pair-layer-left').click();
  const exposure = page.getByTestId('film-exposure').locator('input');
  await exposure.press('ArrowUp');
  expect(await state(page, 's.pair.left.exposureEV')).toBeCloseTo(1 / 3);
  expect(await state(page, 's.pair.right.exposureEV')).toBe(0);
  await expect.poll(() => page.evaluate((path) => localStorage.getItem(`pair:${path}`), savedPath)).toContain('0.3333333333333333');
  await page.reload(); await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await expect(page.locator('.thumb')).toHaveCount(9);
  await page.locator('.thumb').filter({ hasText: 'Half-Frame Pair' }).click();
  await expect.poll(() => state(page, 's.selection')).toBe(savedPath);
  expect(await state(page, 's.pair.left.exposureEV')).toBeCloseTo(1 / 3);
});
for (const renderDelay of [0, 600]) {
  test(`fills an empty hole by dragging from the strip and supports reversible placement on the canvas (render delay ${renderDelay} ms)`, async ({ page }) => {
    await open(page, renderDelay); await page.getByTestId('make-pair').click();
    // Windows native file-drop handling consumes HTML5 drag/drop. Internal
    // gestures must still work when those browser events cannot reach the app.
    await page.evaluate(() => { for (const type of ['dragstart', 'dragover', 'drop']) window.addEventListener(type, (e) => { e.preventDefault(); e.stopImmediatePropagation(); }, true); });
    await expect(page.getByTestId('pair-overlay')).toBeVisible();
    await expect(page.getByTestId('export-button')).toBeDisabled();
    // The overlay mounts before the pair's render and filmstrip thumbnails
    // settle. Measuring their placeholders can start or end a drag elsewhere
    // on a slower CI runner. Wait for the actual pair, then let Playwright
    // resolve a visible, stable source before measuring the destination.
    await expect.poll(() => state(page, 's.pairInfo?.left?.available')).toBe(true);
    await expect(page.getByTestId('tier-badge')).toHaveText('full');
    const gate = page.getByTestId('pair-overlay').locator('rect').nth(1);
    const selected = await state(page, 's.selection');
    const source = page.locator('.thumb[data-path="/mock/Roll 01/DSC_0002.NEF"]');
    await expect(source).toHaveAttribute('draggable', 'false');
    await expect(source.locator('canvas')).toBeVisible();
    await source.hover(); await page.mouse.down();
    const empty = (await gate.boundingBox())!;
    await page.mouse.move(empty.x + empty.width / 2, empty.y + empty.height / 2, { steps: 8 });
    expect(await state(page, 's.selection')).toBe(selected);
    await page.mouse.up();
    await expect.poll(() => state(page, 's.pair?.right?.path')).toBe('/mock/Roll 01/DSC_0002.NEF');
    expect(await state(page, 's.selection')).toBe(selected);
    await expect(page.getByTestId('export-button')).toBeEnabled();
    await page.getByTestId('pair-layer-right').click();
    const scale = page.getByRole('textbox', { name: 'Scale value', exact: true });
    await scale.fill('2'); await scale.press('Enter');
    await page.getByRole('button', { name: 'Crop on the canvas', exact: true }).click();
    const rect = (await gate.boundingBox())!, x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
    const before = await state(page, '({...s.pair.right.placement})');
    await page.mouse.move(x, y); await page.mouse.down(); await page.mouse.move(x + 35, y + 20, { steps: 4 }); await page.mouse.up();
    const after = await state(page, 's.pair.right.placement');
    expect(after.x).not.toBe(before.x); expect(after.y).not.toBe(before.y);
    await page.keyboard.press('Control+z');
    expect(await state(page, 's.pair.right.placement')).toEqual(before);
  });
}
