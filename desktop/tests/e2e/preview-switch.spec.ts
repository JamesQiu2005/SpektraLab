import { expect, test, type Page } from '@playwright/test';

const cameraColors = [[48, 96, 160, 255], [208, 80, 40, 255], [24, 176, 88, 255], [192, 160, 56, 255]];
const printColors = [[168, 48, 96, 255], [40, 144, 208, 255], [128, 176, 24, 255], [56, 64, 192, 255]];

async function surfaces(page: Page) {
  return page.evaluate(() => {
    const canvas = document.querySelector<HTMLCanvasElement>('[data-testid="canvas"] > canvas')!;
    const gl = canvas.getContext('webgl2')!;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    const floating = (gl as WebGL2RenderingContext & { drawingBufferFormat?: number }).drawingBufferFormat === gl.RGBA16F;
    const native = { width: 4, height: 2 };
    const zoom = Math.min(canvas.width / native.width, canvas.height / native.height);
    const w = native.width * zoom, h = native.height * zoom;
    const left = (canvas.width - w) / 2, top = (canvas.height - h) / 2;
    const positions = [[.25, .25], [.75, .25], [.25, .75], [.75, .75]];
    const main = positions.map(([x, y]) => {
      const px = floating ? new Float32Array(4) : new Uint8Array(4);
      gl.readPixels(Math.floor(left + x! * w), Math.floor(canvas.height - top - y! * h), 1, 1,
        gl.RGBA, floating ? gl.FLOAT : gl.UNSIGNED_BYTE, px);
      return Array.from(px, (value) => floating ? Math.round(value * 255) : value);
    });
    const nav = document.querySelector<HTMLCanvasElement>('[data-testid="navigator"] canvas')!;
    const ctx = nav.getContext('2d')!;
    const navigator = positions.map(([x, y]) => Array.from(ctx.getImageData(Math.floor(nav.width * x!), Math.floor(nav.height * y!), 1, 1).data));
    const histogram = Array.from(document.querySelectorAll('[data-testid="histogram"] path')).map((path) => path.getAttribute('d')!);
    return { main, navigator, histogram, navSize: [nav.width, nav.height], canvasSize: [canvas.width, canvas.height], lost: gl.isContextLost(), glError: gl.getError() };
  });
}

function expectColors(actual: number[][], expected: number[][], tolerance = 2) {
  expect(actual).toHaveLength(expected.length);
  for (const [index, color] of actual.entries()) {
    for (const [channel, value] of color.entries()) expect(Math.abs(value - expected[index]![channel]!)).toBeLessThanOrEqual(tolerance);
  }
}

test('camera fallback draws real pixels on all surfaces before decode, then shows the processed print exactly once', async ({ page }) => {
  await page.goto('/');
  await expect.poll(() => page.evaluate(() => (window as unknown as { __spk: { sessionStore: { getState(): { hostState: { phase: string } } } } }).__spk.sessionStore.getState().hostState.phase)).toBe('ready');
  await page.evaluate(async (colors) => {
    const sidecarPath = '/src/shared/sidecar.ts';
    const { newSidecar } = await import(sidecarPath);
    const w = window as unknown as { __spk: {
      frameImages: { print: unknown; original: unknown };
      settingsStore: { getState(): { set(key: string, value: unknown): void } };
      sessionStore: { getState(): { imageVersion: number }; setState(value: unknown): void };
    } };
    const sidecar = newSidecar();
    sidecar.geometry = { ...sidecar.geometry, crop: { x: .25, y: 0, width: .5, height: 1 }, quarterTurns: 1 };
    sidecar.adjustments = { ...sidecar.adjustments, exposure: 3, saturation: 50 };
    const data = new Uint8Array([colors[0]!, colors[0]!, colors[1]!, colors[1]!, colors[2]!, colors[2]!, colors[3]!, colors[3]!].flat());
    w.__spk.settingsStore.getState().set('previewGamut', 'srgb');
    w.__spk.frameImages.print = null;
    w.__spk.frameImages.original = { width: 4, height: 2, data, colorSpace: 'sRGB', format: 'rgba8' };
    w.__spk.sessionStore.setState({ selection: '/owned/camera.ARW', engineSession: null, nativeSize: null, sidecar,
      badge: null, imageVersion: w.__spk.sessionStore.getState().imageVersion + 1,
      view: { fit: true, zoom: 1, cx: .5, cy: .5 }, showingOriginal: false, comparing: false, tool: 'select' });
  }, cameraColors);
  await expect(page.getByTestId('camera-preview-badge')).toBeVisible();
  await expect.poll(async () => (await surfaces(page)).navSize).toEqual([256, 128]);
  await expect(page.getByTestId('histogram')).toBeVisible();
  const original = await surfaces(page);
  expect(original.glError).toBe(0);
  expectColors(original.main, cameraColors);
  expectColors(original.navigator, cameraColors);
  expect(original.histogram).toHaveLength(4);
  // Histogram paths must have populated bins above their baseline, not merely
  // a visible empty SVG. Each channel has its own coloured input distribution.
  for (const path of original.histogram) expect(path).toMatch(/L[\d.]+ 0\.0/);

  await page.evaluate((colors) => {
    const w = window as unknown as { __spk: {
      frameImages: { print: unknown }; sessionStore: {
        getState(): { imageVersion: number; sidecar: { geometry: unknown } }; setState(value: unknown): void;
      };
    } };
    const state = w.__spk.sessionStore.getState();
    const data = new Uint8Array([colors[0]!, colors[0]!, colors[1]!, colors[1]!, colors[2]!, colors[2]!, colors[3]!, colors[3]!].flat());
    w.__spk.frameImages.print = { width: 4, height: 2, data, colorSpace: 'sRGB', format: 'rgba8',
      processedGeometry: state.sidecar.geometry, nativeSize: { width: 8, height: 8 }, tier: 'full', reprinted: false, ms: 1 };
    w.__spk.sessionStore.setState({ nativeSize: { width: 8, height: 8 }, badge: 'full', imageVersion: state.imageVersion + 1 });
  }, printColors);
  await expect(page.getByTestId('camera-preview-badge')).toHaveCount(0);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await expect.poll(async () => (await surfaces(page)).navigator[0]![0]).toBe(printColors[0]![0]);
  const printed = await surfaces(page);
  expect(printed.glError).toBe(0);
  expect(printed.navSize).toEqual([256, 128]);
  expectColors(printed.main, printColors);
  expectColors(printed.navigator, printColors);
  expect(printed.histogram).not.toEqual(original.histogram);
});

test('a late cache read from the previous photograph cannot replace the latest preview while old engine work is blocked', async ({ page }) => {
  await page.goto('/');
  await expect.poll(() => page.evaluate(() => (window as unknown as { __spk: { sessionStore: { getState(): { hostState: { phase: string } } } } }).__spk.sessionStore.getState().hostState.phase)).toBe('ready');
  await page.evaluate(async () => {
    const hostPath = '/src/host/client.ts', sessionPath = '/src/state/session.ts', framingPath = '/src/shared/framing.ts', geometryPath = '/src/shared/geometry.ts';
    // Reusing a Vite server during development can add HMR query strings to
    // module URLs. Import the exact module already used by the window, or a
    // second state store would test an invisible editor instead of this one.
    const loaded = (path: string) => performance.getEntriesByType('resource').find((entry) => new URL(entry.name).pathname === path)?.name ?? path;
    const [{ host }, session, { encodeFrame }, { GEOMETRY_DEFAULT }] = await Promise.all([hostPath, sessionPath, framingPath, geometryPath].map((path) => import(loaded(path))));
    const app = (window as unknown as { __spk: { sessionStore: unknown } }).__spk;
    if (session.sessionStore !== app.sessionStore) throw new Error('The test must control the displayed editor session');
    const pending = new Map<string, (value: ArrayBuffer) => void>();
    const reads: string[] = [], opened: string[] = [];
    const image = (red: number) => {
      const bytes = encodeFrame({ hit: true, metadata: { image: { width: 4, height: 2, format: 'rgba8', colorSpace: 'sRGB',
        cachedSourceSize: { width: 4, height: 2 }, processedGeometry: GEOMETRY_DEFAULT } } },
      new Uint8Array(Array.from({ length: 8 }, () => [red, 96, 160, 255]).flat()));
      return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
    };
    const miss = encodeFrame({ hit: false }, new Uint8Array());
    Object.assign(window, { __TAURI_INTERNALS__: { invoke: (cmd: string, args: Record<string, unknown>) => {
      if (cmd === 'frame_cache_key') {
        const desc = args.descriptor as { kind: string; sources: string[] };
        const char = desc.kind === 'print' ? (desc.sources[0] === '/owned/a.ARW' ? 'a' : 'b') : 'c';
        return Promise.resolve(char.repeat(64));
      }
      if (cmd === 'frame_cache_read') {
        const key = String(args.key); reads.push(key);
        if (key === 'c'.repeat(64)) return Promise.resolve(miss.buffer.slice(miss.byteOffset, miss.byteOffset + miss.byteLength));
        return new Promise<ArrayBuffer>((resolve) => pending.set(key, resolve));
      }
      return Promise.resolve(null);
    } } });
    // Block release of the old RAW session. Cached display must be independent
    // of this queue, while new RAW opens must still wait to limit memory.
    host().close = () => new Promise(() => {});
    host().open = (path: string) => { opened.push(path); return new Promise(() => {}); };
    session.sessionStore.setState({ engineSession: 'old-session' });
    Object.assign(window, { __switch: {
      select: (path: string) => { void session.select(path); }, reads, opened,
      release: (key: string, red: number) => pending.get(key.repeat(64))!(image(red)),
      inspect: () => ({ selection: session.sessionStore.getState().selection,
        red: (window as unknown as { __spk: { frameImages: { print: { data: Uint8Array } | null } } }).__spk.frameImages.print?.data[0] }),
    } });
  });
  type SwitchHarness = { __switch: { select(path: string): void; reads: string[]; opened: string[];
    release(key: string, red: number): void; inspect(): { selection: string | null; red?: number } } };
  await page.evaluate(() => (window as unknown as SwitchHarness).__switch.select('/owned/a.ARW'));
  await expect.poll(() => page.evaluate(() => (window as unknown as SwitchHarness).__switch.reads)).toContain('a'.repeat(64));
  await page.evaluate(() => (window as unknown as SwitchHarness).__switch.select('/owned/b.ARW'));
  await expect.poll(() => page.evaluate(() => (window as unknown as SwitchHarness).__switch.reads)).toContain('b'.repeat(64));
  await page.evaluate(() => (window as unknown as SwitchHarness).__switch.release('b', 40));
  await expect.poll(() => page.evaluate(() => (window as unknown as SwitchHarness).__switch.inspect())).toEqual({ selection: '/owned/b.ARW', red: 40 });
  await expect.poll(async () => (await surfaces(page)).navigator[0]![0]).toBe(40);
  expectColors((await surfaces(page)).main, Array.from({ length: 4 }, () => [40, 96, 160, 255]));
  await page.evaluate(() => (window as unknown as SwitchHarness).__switch.release('a', 220));
  // A frame boundary plus the cache continuation is sufficient; no sleep tied
  // to a machine-specific RAW duration is used for the stale-response check.
  await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
  expect(await page.evaluate(() => (window as unknown as SwitchHarness).__switch.inspect())).toEqual({ selection: '/owned/b.ARW', red: 40 });
  expect(await page.evaluate(() => (window as unknown as SwitchHarness).__switch.opened)).toEqual([]);
  expectColors((await surfaces(page)).main, Array.from({ length: 4 }, () => [40, 96, 160, 255]));
});
