// Layout and behaviour of the editor against the in-page mock host.

import { expect, test, type Page } from '@playwright/test';
test.beforeEach(({page})=>{page.on('pageerror',e=>console.error('Webview exception:',e.message));});

async function openRoll(page: Page) {
  await page.goto('/?open=');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
}

const state = (page: Page, expr: string) =>
  page.evaluate((e) => {
    const s = (window as unknown as { __spk: { sessionStore: { getState(): unknown } } }).__spk.sessionStore.getState();
    return new Function('s', `return ${e}`)(s);
  }, expr);

test('black-and-white stocks select silver paper and guard incompatible papers and EDR',async({page})=>{
  await openRoll(page);
  const films=page.getByTestId('film-list'),papers=page.getByTestId('paper-list');
  await expect(films.getByText('Black & White',{exact:true})).toBeVisible();
  await films.locator('[data-stock="kodak_tri_x_400"]').click();
  await expect.poll(()=>state(page,'s.sidecar.params.printStock')).toBe('ilford_multigrade_iv_rc');
  await expect(papers.locator('[data-stock="kodak_supra_endura"]')).toHaveAttribute('aria-disabled','true');
  // Exercise the handler too; an ordinary user click is already blocked by
  // aria-disabled, which Playwright correctly refuses to click normally.
  await papers.locator('[data-stock="kodak_supra_endura"]').click({force:true});
  expect(await state(page,'s.sidecar.params.printStock')).toBe('ilford_multigrade_iv_rc');
  await expect(page.locator('[data-section="print"]').getByRole('switch',{name:'Extended Dynamic Range'})).toBeDisabled();
  await films.locator('[data-stock="kodak_portra_400"]').click();
  await expect.poll(()=>state(page,'s.sidecar.params.printStock')).toBe('kodak_portra_endura');
  await expect(papers.locator('[data-stock="ilford_multigrade_iv_rc"]')).toHaveAttribute('aria-disabled','true');
  await films.locator('[data-stock="kodak_ektachrome_100"]').click();
  await expect.poll(()=>state(page,'s.sidecar.params.scanFilm')).toBe(true);
});

test('pair recipe controls preserve source edits, flush before leaving, reload and guard batch editing (synthetic host)',async({page})=>{
  await page.goto('/?open=&pairFixture=1');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const a=page.locator('.thumb').nth(0),b=page.locator('.thumb').nth(1);
  await a.click();await b.click({modifiers:['Control']});
  const sources=await state(page,'s.picked');
  await page.getByTestId('create-pair').click();
  await expect(page.locator('[data-section="pair"]')).toBeVisible();
  await expect.poll(()=>state(page,'s.pairInfo?.complete')).toBe(true);
  const pairPath=await state(page,'s.selection');
  expect(await state(page,'[s.pairDocument.left.path,s.pairDocument.right.path]')).toEqual(sources);
  await page.getByTestId('pair-right').click();
  const ev=page.getByTestId('pair-exposure').locator('input');
  await ev.fill('0.75');await ev.press('Enter');
  await page.locator('.thumb').nth(0).click();
  expect(await page.evaluate(p=>JSON.parse(localStorage.getItem('pair:'+p)!).right.exposureEV,pairPath)).toBe(.75);
  expect(await page.evaluate(p=>localStorage.getItem('sidecar:'+p),sources[1])).toBeNull();
  await page.reload();await expect(page.locator('.thumb')).toHaveCount(9);
  await page.locator('.thumb').last().click();
  await expect.poll(()=>state(page,'s.pairDocument?.right.exposureEV')).toBe(.75);
  await expect(page.getByTestId('crop-tool')).toBeEnabled();
  await page.getByTestId('pair-right').click();
  await page.locator('[data-section="pair"]').getByRole('button',{name:'Clear hole',exact:true}).click();
  await expect.poll(()=>state(page,'s.pairInfo?.can_export')).toBe(false);
  await page.getByTestId('export-button').click();await page.getByTestId('export-run').click();
  await expect(page.getByTestId('export-page')).toContainText('Both half-frame holes');
});

test('Scene Placement commits a fitted curve and undo restores it (synthetic measurement)',async({page})=>{
  await page.goto('/?open=&allFeatures=1');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const row=page.getByTestId('placement-highlight');
  const section=page.locator('[data-section="scenePlacement"]');
  if(!(await row.isVisible()))await section.locator('.disclosure').click();
  await expect(row.locator('input')).toBeEnabled();
  await row.locator('input').fill('3');await row.locator('input').press('Enter');
  await expect.poll(()=>state(page,'s.sidecar.params.sceneLatitude.active')).toBe(true);
  expect(await state(page,'s.sidecar.params.sceneLatitude.highlightRoom')).toBeGreaterThanOrEqual(.5);
  await page.keyboard.press('Control+z');
  await expect.poll(()=>state(page,'s.sidecar.params.sceneLatitude.active')).toBe(false);
});
test('pair framing drags, wheel anchor, undo and saved recipe agree (synthetic source, real WebGL)',async({page})=>{
  await page.goto('/?open=&pairFixture=1');await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.locator('.thumb').nth(1).click({modifiers:['Control']});await page.getByTestId('create-pair').click();
  await expect.poll(()=>state(page,'s.pairInfo?.complete')).toBe(true);await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const path=await state(page,'s.selection'),before=await state(page,'s.pairDocument.left.placement');
  await page.getByTestId('crop-tool').click();
  await expect(page.getByTestId('pair-placement-bar')).toContainText('Camera framing');
  const gate=await page.getByTestId('pair-placement-gate').boundingBox();expect(gate).not.toBeNull();
  const x=gate!.x+gate!.width*.45,y=gate!.y+gate!.height*.55;
  await page.mouse.move(x,y);await page.mouse.wheel(0,-300);
  await expect.poll(()=>state(page,'s.pairDocument.left.placement.scale')).toBeGreaterThan(1.3);
  await expect.poll(()=>state(page,'s.pairUpdating')).toBe(false);
  const scaled=await state(page,'s.pairDocument.left.placement'),steps=await state(page,'s.undo.length');
  await page.mouse.move(x,y);await page.mouse.down();await page.mouse.move(x+gate!.width*.12,y-gate!.height*.09,{steps:4});
  await expect(page.getByTestId('pair-camera-preview')).toBeVisible();
  expect(await state(page,'s.pairDocument.left.placement')).toEqual(scaled);
  expect(await state(page,'s.undo.length')).toBe(steps);
  await page.mouse.up();
  await expect.poll(()=>state(page,'s.pairDocument.left.placement.x')).toBeLessThan(scaled.x);
  await expect.poll(()=>state(page,'s.pairDocument.left.placement.y')).toBeGreaterThan(scaled.y);
  expect(await state(page,'s.undo.length')).toBe(steps+1);
  await page.keyboard.press('Control+z');await expect.poll(()=>state(page,'s.pairDocument.left.placement')).toEqual(scaled);
  await page.keyboard.press('Control+y');await expect.poll(()=>state(page,'s.pairDocument.left.placement.x')).toBeLessThan(scaled.x);
  await page.keyboard.press('Enter');await expect(page.getByTestId('pair-placement-bar')).toHaveCount(0);
  await expect.poll(()=>state(page,'s.pairUpdating')).toBe(false);
  const placed=await state(page,'s.pairDocument.left.placement');expect(placed).not.toEqual(before);
  expect(await page.evaluate(p=>JSON.parse(localStorage.getItem('pair:'+p)!).left.placement,path)).toEqual(placed);
  await page.reload();await expect(page.locator('.thumb')).toHaveCount(9);await page.locator('.thumb').last().click();
  await expect.poll(()=>state(page,'s.pairDocument?.left.placement')).toEqual(placed);
});
test('per-hole Post-Dev grades only its own pixels and undo removes the composite (synthetic engine, real WebGL)',async({page})=>{
  await page.goto('/?open=&pairFixture=1');await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.locator('.thumb').nth(1).click({modifiers:['Control']});await page.getByTestId('create-pair').click();
  await expect.poll(()=>state(page,'s.pairInfo?.complete')).toBe(true);
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const pixels=()=>page.evaluate(()=>{
    const im=(window as unknown as {__spk:{frameImages:{print:{width:number;height:number;data:Uint8Array;pregraded?:boolean}}}}).__spk.frameImages.print;
    return {pregraded:!!im.pregraded,colors:[.24,.5,.76].map(u=>Array.from(im.data.slice((Math.floor(im.height/2)*im.width+Math.floor(im.width*u))*4,(Math.floor(im.height/2)*im.width+Math.floor(im.width*u))*4+3)))};
  });
  const before=await pixels();await page.getByTestId('pair-right').click();
  const post=page.getByRole('tab',{name:'Post-Dev',exact:true});if(await post.count())await post.click();
  const value=page.getByTestId('adj-exposure').locator('input');await value.fill('1');await value.press('Enter');
  await expect.poll(()=>state(page,'s.pairDocument?.right.adjustments?.exposure')).toBe(1);
  await expect.poll(async()=> (await pixels()).pregraded).toBe(true);
  const after=await pixels();expect(after.colors[0]).toEqual(before.colors[0]);expect(after.colors[1]).toEqual(before.colors[1]);
  expect(after.colors[2]).not.toEqual(before.colors[2]);expect(await state(page,'s.sidecar.adjustments.exposure')).toBe(0);
  await page.keyboard.press('Control+z');await expect.poll(async()=>(await pixels()).pregraded).toBe(false);
});
test('the frame-only enlarger keeps the film and other hole unchanged (synthetic host)',async({page})=>{
  await page.goto('/?open=&pairFixture=1');await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.locator('.thumb').nth(1).click({modifiers:['Control']});await page.getByTestId('create-pair').click();
  await expect.poll(()=>state(page,'s.pairInfo?.complete')).toBe(true);await page.getByTestId('pair-left').click();
  await page.getByTestId('print-scope').click();await page.getByRole('menuitem',{name:'Frame',exact:true}).click();
  const value=page.getByTestId('enlarger-brightness').locator('input');await value.fill('0.5');await value.press('Enter');
  await expect.poll(()=>state(page,'s.pairDocument?.left.print?.brightnessStops')).toBe(.5);
  expect(await state(page,'s.pairDocument.right.print.brightnessStops')).toBe(0);
  expect(await state(page,'s.sidecar.params.printBrightnessStops')).toBe(0);
  await expect.poll(()=>state(page,'s.pairUpdating')).toBe(false);
  expect(await state(page,'s.lastError')).toBeNull();
});

test('WebGL Original comparison samples both pair holes and keeps the rebate developed',async({page})=>{
  await openRoll(page);
  const samples=await page.evaluate(async()=>{
    const rendererPath='/src/canvas/glRenderer.ts',framePath='/src/shared/filmFrame.ts',geometryPath='/src/shared/geometry.ts',adjPath='/src/shared/adjustments.ts';
    const [{GLRenderer},{pairProjection},{GEOMETRY_DEFAULT},{ADJUSTMENTS_DEFAULT}]=await Promise.all([import(rendererPath),import(framePath),import(geometryPath),import(adjPath)]);
    const canvas=document.createElement('canvas');canvas.width=100;canvas.height=80;
    const renderer=new GLRenderer(canvas),gl=renderer.gl;
    const developed=new Uint8Array(100*80*4),original=new Uint8Array(100*80*4);
    for(let y=0;y<80;y++)for(let x=0;x<100;x++){
      const i=(y*100+x)*4;developed.set([0,0,255,255],i);original.set(x<50?[255,0,0,255]:[0,255,0,255],i);
    }
    renderer.setImage({width:100,height:80,data:developed});renderer.setOriginal({width:100,height:80,data:original});
    const frame=pairProjection({valid:true,vertical:false,gates:[[.1,.2,.45,.2,.45,.8,.1,.8],[.55,.2,.9,.2,.9,.8,.55,.8]]},[[0,0,18/37,1],[19/37,0,18/37,1]],{width:100,height:80});
    renderer.draw({viewport:{width:100,height:80},offset:{x:0,y:0},outSize:{width:100,height:80},display:GEOMETRY_DEFAULT,editingCrop:null,sourceSize:{width:100,height:80},adjustments:ADJUSTMENTS_DEFAULT,compare:2,frame,split:.5,surround:0});
    return [27,72,50].map(x=>{const pixel=new Uint8Array(4);gl.readPixels(x,40,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel);return [...pixel];});
  });
  expect(samples).toEqual([[255,0,0,255],[0,255,0,255],[0,0,255,255]]);
});
test('pair camera preview retains the owner crop, turn, flip and placement turn (real WebGL pixels)',async({page})=>{
  await openRoll(page);
  const result=await page.evaluate(async()=>{
    const previewPath='/src/canvas/pairPlacementPreview.tsx',pairsPath='/src/shared/pairs.ts';
    const [{framePairCamera},{decodePair}]=await Promise.all([import(previewPath),import(pairsPath)]);
    const hole=decodePair({folder:'C:/synthetic-fixture',left:{path:'C:/synthetic-fixture/camera.tif',geometry:{crop:{x:.25,y:1/6,width:.5,height:2/3},quarterTurns:1,flipH:true},placement:{quarterTurns:3}}}).left;
    const pixels=new Uint8Array(8*6*4);
    for(let y=0;y<6;y++)for(let x=0;x<8;x++)pixels.set([x*24,y*32,90,255],(y*8+x)*4);
    const out=framePairCamera({width:8,height:6,data:pixels,colorSpace:'srgb'},hole);
    return {width:out.width,height:out.height,pixels:[...out.data]};
  });
  expect([result.width,result.height]).toEqual([4,4]);
  // Hand oracle: owner crop x=2..5/y=1..4; the two turns with the
  // owner's H flip leave x forward and y reversed in the camera preview.
  const expected:number[]=[];for(let y=4;y>=1;y--)for(let x=2;x<=5;x++)expected.push(x*24,y*32,90,255);
  expect(result.pixels).toEqual(expected);
});
test('IME Process keys operate the canvas but preserve text composition (synthetic source)',async({page})=>{
  await page.goto('/?open=&pairFixture=1');await expect(page.getByTestId('tier-badge')).toHaveText('full');
  await page.locator('.thumb').nth(1).click({modifiers:['Control']});await page.getByTestId('create-pair').click();
  await expect.poll(()=>state(page,'s.pairInfo?.complete')).toBe(true);
  const consumed=await page.evaluate(()=>!document.body.dispatchEvent(new KeyboardEvent('keydown',{key:'Process',code:'KeyC',keyCode:229,bubbles:true,cancelable:true,isComposing:true})));
  expect(consumed).toBe(true);await expect(page.getByTestId('pair-placement-bar')).toBeVisible();
  await page.keyboard.press('Escape');await expect(page.getByTestId('pair-placement-bar')).toHaveCount(0);
  const field=page.getByTestId('pair-exposure').locator('input');await field.focus();
  const typed=await field.evaluate(el=>el.dispatchEvent(new KeyboardEvent('keydown',{key:'Process',code:'KeyC',keyCode:229,bubbles:true,cancelable:true,isComposing:true})));
  expect(typed).toBe(true);expect(await state(page,'s.pairPlacing')).toBe(false);
});

test('the window: two rails, the bar, the canvas, the filmstrip', async ({ page }) => {
  await openRoll(page);
  await expect(page.getByTestId('left-rail')).toContainText('Film and Print');
  await expect(page.getByTestId('right-rail')).toContainText('Parameters');
  await expect(page.locator('.thumb')).toHaveCount(8);
  await expect(page.getByTestId('histogram')).toBeVisible();
  await expect(page.getByTestId('navigator').locator('canvas')).toBeVisible();
});

test('panel widths follow both grips, survive reload and reset on double click', async ({ page }) => {
  await openRoll(page);
  const left = page.getByRole('separator', { name: 'Resize film and print panel' });
  const right = page.getByRole('separator', { name: 'Resize parameters panel' });
  const before = await page.getByTestId('left-rail').boundingBox();
  const grip = await left.boundingBox();
  await page.mouse.move(grip!.x+grip!.width/2, grip!.y+100);
  await page.mouse.down(); await page.mouse.move(grip!.x+65, grip!.y+100, {steps:4}); await page.mouse.up();
  await expect.poll(async () => (await page.getByTestId('left-rail').boundingBox())!.width).toBeGreaterThan(before!.width+50);
  await right.focus(); await page.keyboard.press('Home');
  await expect(right).toHaveAttribute('aria-valuenow', '280');
  await page.keyboard.press('End');
  await expect(right).toHaveAttribute('aria-valuenow', '364');
  await page.reload();
  await expect(right).toHaveAttribute('aria-valuenow', '364');
  await left.dblclick(); await right.dblclick();
  await expect(left).toHaveAttribute('aria-valuenow', '254');
  await expect(right).toHaveAttribute('aria-valuenow', '288');
  const canvas = await page.getByTestId('canvas').boundingBox();
  expect(canvas!.width).toBeGreaterThan(400);
  await page.setViewportSize({width:1100,height:700});
  await left.focus(); await page.keyboard.press('End');
  await right.focus(); await page.keyboard.press('End');
  const controlsFit = () => page.getByTestId('topbar').evaluate((bar) => {
    const box = bar.getBoundingClientRect();
    return [...bar.querySelectorAll('button')].filter(b => getComputedStyle(b).display !== 'none').every(b => {
      const r = b.getBoundingClientRect();
      return r.width >= 20 && r.left >= box.left && r.right <= box.right;
    });
  });
  expect(await controlsFit()).toBe(true);
  await page.evaluate(() => {
    const settings = (window as unknown as {__spk:{settingsStore:{getState():{set(k:string,v:string|number):void}}}}).__spk.settingsStore.getState();
    settings.set('interfaceScale',130); settings.set('language','simplifiedChinese');
  });
  await expect(page.getByRole('separator',{name:'调整参数栏宽度'})).toBeVisible();
  expect(await controlsFit()).toBe(true);
  await page.getByTestId('zoom-pill').click();
  await expect(page.getByRole('menuitem',{name:'100 %',exact:true})).toBeVisible();
  await page.keyboard.press('Escape');
  await page.getByTestId('export-button').click();
  await expect(page.getByTestId('export-page')).toBeVisible();
});

test('a film edit reaches the sidecar and the engine', async ({ page }) => {
  await openRoll(page);
  await page.locator('[data-stock="kodak_gold_200"]').click();
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_gold_200');
  await expect(page.getByTestId('tier-badge')).toHaveText('full', { timeout: 20_000 });
  await page.keyboard.press('Control+z');
  expect(await state(page, 's.sidecar.params.filmStock')).toBe('kodak_portra_400');
});

test('new frames inherit the current body, keep individual seeds and retain their roll numbers', async ({ page }) => {
  await page.goto('/?open=&allFeatures=1');
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const first = await state(page, 's.sidecar.params.filmEdge');
  expect(first.seeded).toBe(true); expect(first.frameNumber).toBe(1);
  await page.getByRole('button', {name:'Another',exact:true}).click();
  await expect.poll(() => state(page, 's.sidecar.params.filmEdge.cameraSeed')).toBe(first.cameraSeed+1);
  await page.locator('.thumb').nth(1).click();
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  const second = await state(page, 's.sidecar.params.filmEdge');
  expect(second.cameraSeed).toBe(first.cameraSeed+1);
  expect(second.frameSeed).not.toBe(first.frameSeed); expect(second.frameNumber).toBe(2);
  await page.locator('.thumb').nth(0).click();
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  expect(await state(page, 's.sidecar.params.filmEdge.frameSeed')).toBe(first.frameSeed);
  await page.locator('.thumb').nth(2).click();
  await page.locator('.thumb').nth(3).click();
  await expect.poll(() => state(page, 's.sidecar.params.filmEdge.frameNumber')).toBe(4);
  await page.reload();
  await expect(page.getByTestId('tier-badge')).toHaveText('full');
  expect(await state(page, 's.sidecar.params.filmEdge.frameSeed')).toBe(first.frameSeed);
  expect(await state(page, 's.sidecar.params.filmEdge.cameraSeed')).toBe(first.cameraSeed+1);
});

test('trap 32: an arrow typed in a field does not change the frame', async ({ page }) => {
  await openRoll(page);
  const first = await state(page, 's.selection');
  const field = page.getByRole('textbox', { name: 'Film Exposure value' });
  await field.click();
  await page.keyboard.press('ArrowLeft');
  await page.keyboard.press('ArrowRight');
  expect(await state(page, 's.selection')).toBe(first);
  await page.keyboard.press('Escape');
  await page.getByTestId('canvas').click();
  await page.keyboard.press('ArrowRight');
  await expect.poll(() => state(page, 's.selection')).not.toBe(first);
});

test('Escape cancels a slider numeric draft, while Enter commits it',async({page})=>{
  await openRoll(page);
  const field=page.getByRole('textbox',{name:'Film Exposure value',exact:true});
  const before=await state(page,'s.sidecar.params.exposureCompensationEV');
  await field.fill('2');await field.press('Escape');
  expect(await state(page,'s.sidecar.params.exposureCompensationEV')).toBe(before);
  await field.fill('1');await field.press('Enter');
  await expect.poll(()=>state(page,'s.sidecar.params.exposureCompensationEV')).toBe(1);
});

test('Escape cancels a unit numeric draft, while Enter commits it',async({page})=>{
  await openRoll(page);
  const section=page.locator('[data-section="filmFormat"]');
  await section.getByRole('button',{name:'135',exact:true}).click();
  await page.getByRole('menuitem',{name:'Custom',exact:true}).click();
  const field=section.locator('.unit-field'),before=await state(page,'s.sidecar.params.sideLengthMM');
  await field.fill('50');await field.press('Escape');
  expect(await state(page,'s.sidecar.params.sideLengthMM')).toBe(before);
  await field.fill('36');await field.press('Enter');
  await expect.poll(()=>state(page,'s.sidecar.params.sideLengthMM')).toBe(36);
});

test('a quarter turn swaps the output size readout', async ({ page }) => {
  await openRoll(page);
  const before = await page.getByTestId('crop-size').textContent();
  await page.getByTestId('rotate-right').click();
  const after = await page.getByTestId('crop-size').textContent();
  const [w, h] = before!.split(' · ')[0]!.split(' × ');
  expect(after!.startsWith(`${h} × ${w}`)).toBe(true);
});

test('a framed photograph can be reframed on its original with a gate-locked crop', async ({ page }) => {
  await openRoll(page);
  // An explicit layout fixture for the interaction regression, not a claim
  // that the mock develops a real film edge. Real pixels are tested separately.
  await page.evaluate(() => {
    const app = (window as unknown as { __spk: { sessionStore: { getState(): { sidecar: { params: { filmEdge: object } }; imageVersion: number }; setState(v: object): void }; frameImages: { print: { frame?: object } } } }).__spk;
    const s = app.sessionStore.getState();
    app.frameImages.print.frame = { native: { width: 1900, height: 1700 }, original: [1, 0, 0, 1, 0, 0], gate: [1, 0, 0, 1, 0, 0] };
    app.sessionStore.setState({ sidecar: { ...s.sidecar, params: { ...s.sidecar.params, filmEdge: { ...s.sidecar.params.filmEdge, active: true } } }, imageVersion: s.imageVersion + 1 });
  });
  await page.getByTestId('crop-tool').click();
  await expect(page.locator('.crop-overlay')).toBeVisible();
  await expect(page.getByTestId('crop-reference')).toContainText('135');
  const corner = await page.locator('[data-crop-handle="bottomRight"]').boundingBox();
  expect(corner).not.toBeNull();
  await page.mouse.move(corner!.x + corner!.width / 2, corner!.y + corner!.height / 2);
  await page.mouse.down();
  await page.mouse.move(corner!.x - 90, corner!.y - 60, { steps: 3 });
  await page.mouse.up();
  await expect.poll(() => state(page, 's.sidecar.geometry.crop.width')).toBeLessThan(0.95);
  const ratio = await state(page, 's.sidecar.geometry.crop.width * 1800 / (s.sidecar.geometry.crop.height * 1200)');
  expect(ratio).toBeCloseTo(36.25 / 24.3, 2);
});

test('the language switch renames the rails', async ({ page }) => {
  await openRoll(page);
  await page.evaluate(() => (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', 'simplifiedChinese'));
  await expect(page.getByTestId('left-rail')).toContainText('胶片与相纸');
  await page.evaluate(() => (window as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: string): void } } } }).__spk.settingsStore.getState().set('language', 'english'));
  await expect(page.getByTestId('left-rail')).toContainText('Film and Print');
});

test('a bare date crop shows the original with its free crop, without locking a 135 gate', async ({ page }) => {
  await openRoll(page);
  // Explicit geometry fixture: verifies UI ownership, not mock date rendering.
  await page.evaluate(() => {
    const app = (window as unknown as { __spk: { sessionStore: { getState(): { sidecar: { geometry: object }; imageVersion: number }; setState(v: object): void }; frameImages: { print: { frame?: object } } } }).__spk;
    const s = app.sessionStore.getState();
    app.frameImages.print.frame = { filmEdge: false, native: { width: 900, height: 840 },
      original: [0.5, 0, 0, 0.7, 0.2, 0.1], gate: [1, 0, 0, 1, 0, 0] };
    app.sessionStore.setState({ sidecar: { ...s.sidecar, geometry: { ...s.sidecar.geometry,
      crop: { x: 0.2, y: 0.1, width: 0.5, height: 0.7 }, lockedRatio: null } }, imageVersion: s.imageVersion+1 });
  });
  await page.getByTestId('crop-tool').click();
  await expect(page.locator('.crop-overlay')).toBeVisible();
  await expect(page.getByTestId('crop-reference')).toHaveText('Original framing');
  const corner = await page.locator('[data-crop-handle="bottomRight"]').boundingBox();
  expect(corner).not.toBeNull();
  await page.mouse.move(corner!.x+corner!.width/2, corner!.y+corner!.height/2);
  await page.mouse.down();
  await page.mouse.move(corner!.x-60, corner!.y-10, {steps:3});
  await page.mouse.up();
  await expect.poll(() => state(page, 's.sidecar.geometry.crop.width')).toBeLessThan(0.5);
  expect(await state(page, 's.sidecar.geometry.lockedRatio')).toBeNull();
});

test('the export page names the file and holds the frame while it runs', async ({ page }) => {
  await openRoll(page);
  await page.getByTestId('export-button').click();
  await expect(page.getByTestId('export-page')).toBeVisible();
  await expect(page.getByTestId('export-sample')).toContainText('DSC_0001_Portra_400');
  await page.getByTestId('export-run').click();
  await expect.poll(() => state(page, 's.batchExporting')).toBe(false);
  await expect(page.getByTestId('export-page')).toContainText('DSC_0001');
});
