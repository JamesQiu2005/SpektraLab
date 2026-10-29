import { expect, test } from '@playwright/test';

test('camera preview badge distinguishes pending, failure and idle in both languages', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  for (const language of ['english', 'simplifiedChinese']) {
    for (const status of ['loading', 'failed', 'idle']) {
      await page.evaluate(({ language, status }) => {
        const app = (window as unknown as { __spk: {
          frameImages: { print: unknown; original: unknown };
          settingsStore: { getState(): { set(k: string, v: string): void } };
          sessionStore: { getState(): { imageVersion: number }; setState(s: object): void };
        } }).__spk;
        app.settingsStore.getState().set('language', language);
        app.frameImages.original ??= app.frameImages.print;
        app.frameImages.print = null;
        app.sessionStore.setState({ developing: status === 'loading', lastError: status === 'failed' ? 'decode failed' : null,
          imageVersion: app.sessionStore.getState().imageVersion + 1 });
      }, { language, status });
      const labels = language === 'english'
        ? { loading: 'Camera preview · loading film effect', failed: 'Camera preview · film effect failed to load', idle: 'Camera preview' }
        : { loading: '原图预览 · 正在加载胶片效果', failed: '原图预览 · 胶片效果加载失败', idle: '原图预览' };
      await expect(page.getByTestId('camera-preview-badge')).toHaveText(labels[status as keyof typeof labels]);
    }
  }
});
