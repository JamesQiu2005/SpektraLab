// Regressions for the real toolbar and stock list at supported window/UI sizes.
// These are browser layout checks: jsdom does not perform the flex/text layout
// that made the file name disappear, wrapped zoom and joined cover images.
import { expect, test, type Page } from '@playwright/test';

const layouts = [
  { width: 1100, scale: 130, maxRails: true, chinese: true, zoom: 16 },
  { width: 1100, scale: 115, maxRails: false, chinese: true, zoom: 1 },
  { width: 1280, scale: 115, maxRails: false, chinese: true, zoom: 1 },
  { width: 1600, scale: 100, maxRails: false, chinese: false, zoom: 16 },
];

async function openAt(page: Page, layout: typeof layouts[number]) {
  await page.setViewportSize({ width: layout.width, height: 960 });
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.evaluate((layout) => {
    const app = (window as unknown as { __spk: {
      settingsStore: { getState(): { set(key: string, value: unknown): void } };
      sessionStore: { setState(value: unknown): void };
    } }).__spk;
    const settings = app.settingsStore.getState();
    settings.set('interfaceScale', layout.scale);
    settings.set('language', layout.chinese ? 'simplifiedChinese' : 'english');
    settings.set('leftWidth', layout.maxRails ? 380 : 254);
    settings.set('rightWidth', layout.maxRails ? 364 : 288);
    settings.set('previewGamut', 'auto');
    // Exercise the longest normal gamut label, independently of the test
    // runner's actual monitor. Colour capability negotiation has its own tests.
    app.sessionStore.setState({ displaySpace: 'display-p3', view: { fit: false, zoom: layout.zoom, cx: .5, cy: .5 } });
  }, layout);
  await expect(page.getByTestId('preview-gamut')).toContainText('Display P3');
  await expect(page.getByTestId('zoom-pill')).toHaveText(`${layout.zoom * 100} %`);
}

for (const layout of layouts) {
  test(`toolbar and film covers fit ${layout.width}px / ${layout.scale}% / ${layout.maxRails ? 'wide rails' : 'default rails'} / ${layout.chinese ? 'Chinese' : 'English'}`, async ({ page }) => {
    await openAt(page, layout);
    const bar = page.getByTestId('topbar');
    const fileName = bar.getByText(/DSC_0001\.NEF/).first();
    await expect(fileName).toBeVisible();
    const filenameBox = (await fileName.boundingBox())!;
    const gamutBox = (await page.getByTestId('preview-gamut').boundingBox())!;
    expect.soft(filenameBox.width, 'the file name retains readable space').toBeGreaterThan(80);
    const overlap = Math.min(filenameBox.x + filenameBox.width, gamutBox.x + gamutBox.width) - Math.max(filenameBox.x, gamutBox.x) > 1
      && Math.min(filenameBox.y + filenameBox.height, gamutBox.y + gamutBox.height) - Math.max(filenameBox.y, gamutBox.y) > 1;
    expect.soft(overlap, 'gamut must not occupy the file-name region').toBe(false);

    const buttons = await bar.locator('button:visible').evaluateAll((buttons) => {
      const bar = buttons[0]!.closest('[data-testid="topbar"]')!.getBoundingClientRect();
      return buttons.map((button) => {
        const r = button.getBoundingClientRect();
        return { name: button.getAttribute('title') ?? button.textContent, inside: r.left >= bar.left - 1 && r.right <= bar.right + 1
          && r.top >= bar.top - 1 && r.bottom <= bar.bottom + 1 };
      });
    });
    for (const button of buttons) expect.soft(button.inside, `toolbar control stays in its bar: ${button.name}`).toBe(true);
    const zoomText = await page.getByTestId('zoom-pill').evaluate((button) => {
      const range = document.createRange(); range.selectNodeContents(button);
      const lines = [...range.getClientRects()], r = button.getBoundingClientRect();
      return { lines: lines.length, fits: lines.every((line) => line.left >= r.left - 1 && line.right <= r.right + 1
        && line.top >= r.top - 1 && line.bottom <= r.bottom + 1) };
    });
    expect.soft(zoomText.lines, 'zoom percentage remains on one line').toBe(1);
    expect.soft(zoomText.fits, 'zoom percentage stays inside its pill').toBe(true);
    await expect.soft(page.getByTestId('make-pair')).toHaveText(layout.chinese ? '双图拼接' : 'Pair photos');
    await expect.soft(page.getByTestId('make-pair')).toHaveAttribute('title', layout.chinese ? /两张/ : /two/i);

    const covers = page.locator('[role="listbox"] img.cover');
    await expect.poll(() => covers.evaluateAll((images) => images.length > 1 && images.every((image) => (image as HTMLImageElement).naturalWidth > 0))).toBe(true);
    const coverLayout = await covers.evaluateAll((images) => images.map((image) => {
      const img = image.getBoundingClientRect(), row = image.closest('[role="option"]')!.getBoundingClientRect();
      return { top: img.top, bottom: img.bottom, inside: img.top >= row.top && img.bottom <= row.bottom,
        fit: getComputedStyle(image).objectFit };
    }));
    for (const cover of coverLayout) {
      expect.soft(cover.inside, 'cover remains inside its own row').toBe(true);
      expect.soft(cover.fit, 'the whole cover is visible').toBe('contain');
    }
    for (let i = 1; i < coverLayout.length; i++) {
      expect.soft(coverLayout[i]!.top - coverLayout[i - 1]!.bottom, 'adjacent film covers have breathing room').toBeGreaterThanOrEqual(2);
    }
    // The reported negative covers must be inspected on screen too, not only
    // measured below the rail's scroll viewport.
    const portra = page.locator('[data-stock="kodak_portra_400"]');
    await portra.scrollIntoViewIfNeeded();
    const negatives = page.locator('[data-stock="kodak_gold_200"], [data-stock="kodak_portra_160"], [data-stock="kodak_portra_400"], [data-stock="kodak_portra_800"]');
    const rows = await negatives.evaluateAll((elements) => elements.map((element) => {
      const row = element.getBoundingClientRect(), cover = element.querySelector('img')!.getBoundingClientRect();
      return { top: row.top, bottom: row.bottom, paddingTop: cover.top - row.top, paddingBottom: row.bottom - cover.bottom };
    }));
    expect(rows).toHaveLength(4);
    for (const row of rows) {
      expect(row.paddingTop).toBeGreaterThanOrEqual(2.9);
      expect(row.paddingBottom).toBeGreaterThanOrEqual(2.9);
    }
    for (let i = 1; i < rows.length; i++) expect(rows[i]!.top - rows[i - 1]!.bottom).toBeGreaterThanOrEqual(2.9);
    await page.screenshot({ path: test.info().outputPath('toolbar-and-covers.png') });
  });
}
