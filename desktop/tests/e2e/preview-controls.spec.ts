import { expect, test, type Page } from '@playwright/test';

const viewState = (page: Page) => page.evaluate(() => {
  const app = (window as unknown as { __spk: {
    sessionStore: { getState(): { displaySpace: string; hello?: { methods?: string[] }; sidecar: unknown } };
    settingsStore: { getState(): { previewGamut: string } };
    frameImages: { print: { colorSpace: string; processedGeometry?: unknown } | null };
  } }).__spk;
  const state = app.sessionStore.getState();
  return { displaySpace: state.displaySpace, methods: state.hello?.methods, sidecar: state.sidecar,
    preference: app.settingsStore.getState().previewGamut,
    imageSpace: app.frameImages.print?.colorSpace === 'Display P3' ? 'display-p3' : 'srgb',
    processed: !!app.frameImages.print?.processedGeometry };
});

test('preview gamut switches independently of edits and persists its preference', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
  const before = await viewState(page);
  expect(before.methods).toContain('render_view');
  expect(before.processed).toBe(true);
  await expect(page.getByTestId('preview-gamut')).toHaveAttribute('title', /ProPhoto RGB/);
  await page.getByTestId('preview-gamut').click();
  await page.getByRole('menuitem', { name: 'Display P3', exact: true }).click();
  await expect.poll(async () => (await viewState(page)).preference).toBe('display-p3');
  await expect.poll(async () => {
    const s = await viewState(page);
    return s.imageSpace === s.displaySpace;
  }).toBe(true);
  expect((await viewState(page)).sidecar).toEqual(before.sidecar);
  const actual = (await viewState(page)).displaySpace;
  await expect(page.getByTestId('preview-gamut')).toHaveText(actual === 'display-p3' ? 'Display P3' : 'P3 → sRGB');
  await page.getByTestId('preview-gamut').click();
  await page.getByRole('menuitem', { name: 'sRGB', exact: true }).click();
  await expect.poll(async () => (await viewState(page)).displaySpace).toBe('srgb');
  await expect.poll(async () => (await viewState(page)).imageSpace).toBe('srgb');
  await page.reload();
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
  expect((await viewState(page)).preference).toBe('srgb');
});
