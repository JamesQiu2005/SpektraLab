import { test, expect } from '@playwright/test';

test('keeps 16-bit samples until drawing and reports the actual browser buffer', async ({ page }, testInfo) => {
  await page.goto('/');
  const measured = await page.evaluate(async () => {
    // Vite serves the application's real renderer, not a separate test shader.
    const rendererPath = '/src/canvas/glRenderer.ts', geometryPath = '/src/shared/geometry.ts', adjustmentsPath = '/src/shared/adjustments.ts';
    const { GLRenderer } = await import(rendererPath);
    const { GEOMETRY_DEFAULT } = await import(geometryPath);
    const { ADJUSTMENTS_DEFAULT } = await import(adjustmentsPath);
    const canvas = document.createElement('canvas'); canvas.width = 1024; canvas.height = 1;
    document.body.append(canvas);
    const renderer = new GLRenderer(canvas);
    const codes = new Uint16Array(1024 * 4);
    for (let i=0;i<1024;++i) { codes[i*4]=codes[i*4+1]=codes[i*4+2]=10000+i; codes[i*4+3]=65535; }
    renderer.setImage({ width:1024,height:1,data:new Uint8Array(codes.buffer),format:'rgba16',colorSpace:'sRGB',processedGeometry:GEOMETRY_DEFAULT });
    const state = { viewport:{width:1024,height:1},offset:{x:0,y:0},outSize:{width:1024,height:1},
      sourceSize:{width:1024,height:1},display:GEOMETRY_DEFAULT,editingCrop:null,adjustments:ADJUSTMENTS_DEFAULT,
      compare:0,split:.5,surround:.18 };
    renderer.draw(state);
    const gl=renderer.gl;
    const out=new Float32Array(1024*4);
    let steps=0;
    if (renderer.displayPrecision==='float16') {
      gl.readPixels(0,0,1024,1,gl.RGBA,gl.FLOAT,out);
      steps=new Set(Array.from({length:1024},(_,i)=>out[i*4])).size;
    }
    const precision = renderer.displayPrecision;
    const error=gl.getError();
    // Averages exact codes 0 and 256 to 128 -> byte 0. Premature byte rounding
    // would average 0 and 1 -> byte 1, so this also checks the fallback path.
    const two=new Uint16Array([0,0,0,65535,256,256,256,65535]);
    renderer.setImage({width:2,height:1,data:new Uint8Array(two.buffer),format:'rgba16',colorSpace:'sRGB',processedGeometry:GEOMETRY_DEFAULT});
    const tiny=renderer.renderOutput({...state,sourceSize:{width:2,height:1}},1,1);
    const glError=gl.getError();
    const capabilities={precision,steps,error,glError,sample:tiny?.[0],drawingBufferStorage:typeof (gl as unknown as {drawingBufferStorage?:unknown}).drawingBufferStorage,
      renderer:gl.getParameter(gl.RENDERER),version:gl.getParameter(gl.VERSION),p3:renderer.supportsP3()};
    gl.getExtension('WEBGL_lose_context')?.loseContext(); canvas.remove();
    return capabilities;
  });
  expect(measured.error).toBe(0);
  expect(measured.glError).toBe(0);
  expect(measured.sample).toBe(0);
  if (measured.precision === 'float16') expect(measured.steps).toBeGreaterThan(50);
  else expect(measured.precision).toBe('unorm8');
  console.log('Actual preview precision:', JSON.stringify(measured));
  await testInfo.attach('actual-browser-preview-precision', {body:JSON.stringify(measured,null,2),contentType:'application/json'});
});

test('keeps exact 16-bit source interpolation when float canvas storage is unavailable', async ({ page }) => {
  await page.goto('/');
  const result = await page.evaluate(async () => {
    const rendererPath = '/src/canvas/glRenderer.ts', geometryPath = '/src/shared/geometry.ts', adjustmentsPath = '/src/shared/adjustments.ts';
    const { GLRenderer } = await import(rendererPath);
    const { GEOMETRY_DEFAULT } = await import(geometryPath);
    const { ADJUSTMENTS_DEFAULT } = await import(adjustmentsPath);
    const canvas = document.createElement('canvas'); canvas.width = 1; canvas.height = 1;
    const gl = canvas.getContext('webgl2')!;
    // This is the real WebGL driver with only the optional storage API hidden.
    Object.defineProperty(gl, 'drawingBufferStorage', { value: undefined });
    const renderer = new GLRenderer(canvas);
    const two = new Uint16Array([0, 0, 0, 65535, 256, 256, 256, 65535]);
    renderer.setImage({ width: 2, height: 1, data: new Uint8Array(two.buffer), format: 'rgba16', colorSpace: 'sRGB', processedGeometry: GEOMETRY_DEFAULT });
    renderer.draw({ viewport: { width: 1, height: 1 }, offset: { x: 0, y: 0 }, outSize: { width: 1, height: 1 }, sourceSize: { width: 2, height: 1 },
      display: GEOMETRY_DEFAULT, editingCrop: null, adjustments: ADJUSTMENTS_DEFAULT, compare: 0, split: .5, surround: .18 });
    const out = new Uint8Array(4); gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, out);
    const measured = { precision: renderer.displayPrecision, sample: out[0], error: gl.getError() };
    gl.getExtension('WEBGL_lose_context')?.loseContext();
    return measured;
  });
  expect(result).toEqual({ precision: 'unorm8', sample: 0, error: 0 });
});
