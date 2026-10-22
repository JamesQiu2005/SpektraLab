import { expect, test } from '@playwright/test';

test('a long filmstrip requests nearby thumbnails as it scrolls, not the entire folder', async ({ page }) => {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 25_000 });
  await page.evaluate(async () => {
    // Use the exact app module URL, including Vite's HMR version. A bare
    // import after edits can create another host that the visible strip never uses.
    const loaded = (path: string) => performance.getEntriesByType('resource').find((entry) => new URL(entry.name).pathname === path)?.name ?? path;
    const [{ host }, { thumbs }] = await Promise.all(['/src/host/client.ts', '/src/state/thumbs.ts'].map((path) => import(loaded(path))));
    const client = host(), original = client.thumbnail.bind(client);
    const calls: string[] = [];
    let sameHost = false;
    client.thumbnail = (path: string, edge: number) => {
      if (path === '/mock/thumbnail-host-probe.ARW') sameHost = true;
      if (edge === 320 && path.startsWith('/mock/Lazy/')) calls.push(path);
      return original(path, edge);
    };
    const w = window as unknown as { __thumbCalls: string[]; __thumbUsesSameHost(): boolean; __spk: { sessionStore: {
      getState(): { frames: Record<string, unknown>[] }; setState(value: unknown): void;
    } } };
    w.__thumbCalls = calls;
    w.__thumbUsesSameHost = () => sameHost;
    thumbs.get('/mock/thumbnail-host-probe.ARW');
    const frame = w.__spk.sessionStore.getState().frames[0];
    w.__spk.sessionStore.setState({ frames: Array.from({ length: 100 }, (_, i) => ({
      ...frame, path: `/mock/Lazy/${i}.ARW`, name: `${i}.ARW`,
    })) });
  });
  await expect.poll(() => page.evaluate(() => (window as unknown as { __thumbUsesSameHost(): boolean }).__thumbUsesSameHost()),
    { message: 'The instrumented host must be the host used by the real thumbnail cache' }).toBe(true);
  await expect(page.locator('.filmstrip-cells .thumb')).toHaveCount(100);
  const calls = () => page.evaluate(() => (window as unknown as { __thumbCalls: string[] }).__thumbCalls);
  await expect.poll(async () => (await calls()).length).toBeGreaterThan(2);
  expect((await calls()).length).toBeLessThan(25);
  expect(await calls()).not.toContain('/mock/Lazy/99.ARW');
  await page.locator('.filmstrip-cells').evaluate((element) => { element.scrollLeft = element.scrollWidth; });
  await expect.poll(calls).toContain('/mock/Lazy/99.ARW');
  expect((await calls()).length).toBeLessThan(40);
});
