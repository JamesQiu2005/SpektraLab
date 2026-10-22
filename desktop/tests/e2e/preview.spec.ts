import { expect, test } from '@playwright/test';

test('processed GPU view is displayed without another grade or quarter turn', async ({ page }) => {
  await page.goto('/');
  const result = await page.evaluate(async () => {
    const rendererPath = '/src/canvas/glRenderer.ts';
    const adjustmentsPath = '/src/shared/adjustments.ts';
    const geometryPath = '/src/shared/geometry.ts';
    const { GLRenderer } = await import(rendererPath);
    const { ADJUSTMENTS_DEFAULT } = await import(adjustmentsPath);
    const { GEOMETRY_DEFAULT } = await import(geometryPath);
    const canvas = document.createElement('canvas');
    const renderer = new GLRenderer(canvas);
    const geometry = { ...GEOMETRY_DEFAULT, quarterTurns: 1 };
    renderer.setImage({ width: 1, height: 2, data: new Uint8Array([32, 64, 128, 255, 160, 192, 224, 255]),
      colorSpace: 'sRGB', processedGeometry: geometry });
    const pixels = renderer.renderOutput({ viewport: { width: 1, height: 2 }, offset: { x: 0, y: 0 },
      outSize: { width: 1, height: 2 }, display: geometry, editingCrop: null, sourceSize: { width: 2, height: 1 },
      adjustments: { ...ADJUSTMENTS_DEFAULT, exposure: 3 }, compare: 0, split: 0.5, surround: 0 }, 1, 2);
    return { pixels: Array.from(pixels), error: renderer.gl.getError() };
  });
  expect(result.error).toBe(0);
  expect(result.pixels).toEqual([32, 64, 128, 255, 160, 192, 224, 255]);
});

test('sRGB before image and a pending sRGB print are converted when drawing in P3', async ({ page }) => {
  await page.goto('/');
  const result = await page.evaluate(async () => {
    const rendererPath = '/src/canvas/glRenderer.ts';
    const adjustmentsPath = '/src/shared/adjustments.ts';
    const geometryPath = '/src/shared/geometry.ts';
    const { GLRenderer } = await import(rendererPath);
    const { ADJUSTMENTS_DEFAULT } = await import(adjustmentsPath);
    const { GEOMETRY_DEFAULT } = await import(geometryPath);
    const canvas = document.createElement('canvas');
    canvas.width = 1;
    canvas.height = 1;
    const renderer = new GLRenderer(canvas);
    const space = renderer.setDisplaySpace('display-p3');
    const red = { width: 1, height: 1, data: new Uint8Array([255, 0, 0, 255]), colorSpace: 'sRGB' };
    renderer.setImage({ ...red, processedGeometry: GEOMETRY_DEFAULT });
    renderer.setOriginal(red);
    const draw = { viewport: { width: 1, height: 1 }, offset: { x: 0, y: 0 },
      outSize: { width: 1, height: 1 }, display: GEOMETRY_DEFAULT, editingCrop: null, sourceSize: { width: 1, height: 1 },
      adjustments: ADJUSTMENTS_DEFAULT, compare: 0, split: 0.5, surround: 0 };
    const pixels = renderer.renderOutput(draw, 1, 1);
    renderer.draw({ ...draw, compare: 2 });
    const gl = renderer.gl;
    // The visible buffer can be RGBA16F; UNSIGNED_BYTE is only legal for the
    // fallback UNORM buffer. Compare both at the exported byte precision.
    const before = renderer.displayPrecision === 'float16' ? new Float32Array(4) : new Uint8Array(4);
    gl.readPixels(0, 0, 1, 1, gl.RGBA, before instanceof Float32Array ? gl.FLOAT : gl.UNSIGNED_BYTE, before);
    return { pixels: Array.from(pixels), before: Array.from(before, (v) => before instanceof Float32Array ? Math.round(v * 255) : v), space, error: gl.getError() };
  });
  expect(result.error).toBe(0);
  expect(result.before).toEqual(result.pixels);
  if (result.space === 'display-p3') {
    // CSS Color 4 D65 transform of sRGB red into Display P3.
    for (const [i, value] of [234, 51, 35, 255].entries()) expect(Math.abs(Number(result.pixels[i]) - value)).toBeLessThanOrEqual(1);
  } else expect(result.pixels).toEqual([255, 0, 0, 255]);
});
