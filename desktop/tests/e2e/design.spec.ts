// T2 — design conformance (PRD-W2 §4): the built pages against the Windows
// design's SVGs (desktop/design/windows), in Chromium at the drawing's size,
// on the mock backends.
//
// Every page id of INDEX.md is either IMPLEMENTED (a case below, which must
// pass) or NOT_IMPLEMENTED (with the reason); the first test holds the two
// lists to INDEX.md, so a page that is in neither — or a page added to the
// design later — fails instead of passing silently.
//
// What a case checks, all read from the page's own SVG:
//  - the window rule's rectangles: the title bar, the walls (rails), the
//    toolbar's and the filmstrip's rules, where the SVG draws its lines;
//  - named regions: a text of the drawing (a section head, a button, a rail
//    title) is on screen, with its anchor (start / middle / end, baseline)
//    within the stated tolerance of where the SVG puts it;
//  - token colours: the fills the SVG gives those regions are the computed
//    colours of the built ones.

import { expect, test, type Browser, type Page } from '@playwright/test';
import { findText, normal, readIndex, readPage, type SvgPage, type SvgText } from '../design/svg';
import { drawnOf, type Drawn } from '../design/items';
import { FIDELITY } from '../design/fidelity';

const ROLL = '/mock/Roll 01';
const TOL = { x: 14, y: 10 };

interface PageCase {
  file: string;
  viewport?: { width: number; height: number; scale?: number };
  query?: string;
  setup: (page: Page) => Promise<void>;
  /** Texts of the drawing to find on screen (exact words), optionally near a point to pick one. */
  texts: (string | { text: string; near?: { x?: number; y?: number }; tol?: { x?: number; y?: number }; shift?: { x?: number; y?: number } })[];
  /** The window rule: which walls and rules this page draws. */
  rule?: { titleBar?: boolean; leftWall?: boolean; rightWall?: boolean; toolbar?: boolean; filmstrip?: boolean };
  /** A window drawn on a page of its own (Settings, 860 × 600): this element's top-left is the drawing's (0, 0). */
  origin?: string;
  /** Regions whose computed background is a fill of the SVG: [selector, the SVG rect it is, by its x,y]. */
  fills?: [string, { x: number; y: number } | { fill: string; y0: number; y1: number }][];
  /** T2b: the regions whose drawn glyphs and controls must be built ([x0, y0, x1, y1], drawing coordinates). */
  claims?: [number, number, number, number][];
  /** T2b: drawn items (by the name T2b reports) deliberately not built on this page, each with its reason. */
  notBuilt?: Record<string, string>;
}

async function openRoll(page: Page, query = '') {
  await page.goto(`/?open=${encodeURIComponent(ROLL)}${query}`);
  await expect(page.getByTestId('frame-title')).toContainText('DSC_0001');
  await expect(page.getByTestId('status-line')).toContainText(/Developed|Edited/, { timeout: 15_000 });
  // The meter's measurement lands after the develop: a page is read once it has (never an empty plot by a race).
  await expect(page.getByTestId('latitude')).toHaveAttribute('data-state', /measured|failed|off/, { timeout: 15_000 });
}
async function openLibrary(page: Page, name: string) {
  await page.goto('/');
  await page.getByTestId('workspace-library').click();
  await page.getByTestId('recent-libraries').getByText(name, { exact: true }).click();
  await expect(page.getByTestId('library-tile').first()).toBeVisible();
}
const edit = (texts: PageCase['texts'], setup?: (p: Page) => Promise<void>, extra: Partial<PageCase> = {}): Omit<PageCase, 'file'> => ({
  query: '', texts, rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true, filmstrip: true },
  // The title bar's black and Export's accent capsule (the one accent rect in the toolbar's band).
  fills: [['[data-testid="titlebar"]', { x: 0, y: 0 }], ['[data-testid="export-button"]', { fill: '#E1A95F', y0: 32, y1: 80 }]],
  ...extra,
  setup: async (p) => { await openRoll(p, extra.query ?? ''); await setup?.(p); },
});

const EDIT_TEXTS = ['File', 'Edit', 'View', 'Frame', 'Go', 'Help', 'Develop', 'Library', 'Film & Paper', 'Format', 'Film Exposure',
  'Latitude', 'Adjust', 'Darkroom', 'Crop', 'Brightness', 'Contrast', 'Tone', 'Enlarger', 'Decode', 'Effects', 'Original', 'Export'] as const;
// Three of the drawing's eleven Adjust tiles (HSL, Channels, Vibrance) are not
// built — the v1 Layer 2 has no maths for them (R7) — so the tile grid is one
// 72 epx row shorter and everything under it in the Edit rail is 72 higher.
const UNDER_TILES = { y: -72 };
const EDIT_COMMON: PageCase['texts'] = [...EDIT_TEXTS.filter((t) => !['Edit', 'Tone', 'Crop', 'Format', 'Darkroom', 'Enlarger', 'Decode', 'Effects', 'Original'].includes(t)),
  { text: 'Edit', near: { x: 1376, y: 61 } }, { text: 'Edit', near: { x: 233, y: 102 } }, { text: 'Tone', near: { x: 1412, y: 308 } },
  { text: 'Original', near: { x: 912, y: 60 } }, { text: 'Format', near: { x: 28, y: 764 } },
  ...(['Darkroom', 'Enlarger', 'Decode', 'Effects'] as const).map((text) => ({ text, shift: UNDER_TILES })),
  { text: 'Crop', near: { x: 1244, y: 746 }, shift: UNDER_TILES }];
/** The Edit rail's sections scroll; on pages drawn scrolled, only the pinned parts are held. */
const LEFT_AND_PINNED: PageCase['texts'] = ['Develop', 'Library', 'Film & Paper', 'Film Exposure', { text: 'Format', near: { x: 28, y: 764 } },
  'Latitude', { text: 'Edit', near: { x: 1376, y: 61 } }, { text: 'Original', near: { x: 912, y: 60 } }, 'Export'];

const SETTINGS_PANES: PageCase['texts'] = ['Settings', { text: 'General', near: { x: 52, y: 70 } }, { text: 'Recipes', near: { x: 52, y: 108 } }, 'Rendering', { text: 'Engine', near: { x: 52, y: 222 } }, 'Diagnostics'];

export const IMPLEMENTED: Record<string, Omit<PageCase, 'file'>> = {
  'PC-E1': edit(EDIT_COMMON),
  'PC-E2': edit(EDIT_COMMON, async (p) => {
    // A film chosen: the last print stays while it develops (a slow mock render).
    await p.locator('[data-stock="kodak_gold_200"]').click();
    await expect(p.getByTestId('status-line')).toContainText('Developing');
  }, { query: '&renderDelay=1500' }),
  'PC-E3': edit([...LEFT_AND_PINNED, 'Adjust', { text: 'Darkroom', shift: UNDER_TILES }], async (p) => {
    await p.locator('[data-tile="tone"]').click();
    await p.locator('[data-tile="enlarger"]').click();
    await expect(p.getByTestId('tile-enlarger')).toBeVisible();
  }),
  'PC-E4': edit(EDIT_COMMON, async (p) => { await p.keyboard.press('Control+1'); await expect(p.getByTestId('tb-zoom')).toContainText('100 %'); }),
  'PC-E6': edit(LEFT_AND_PINNED, async (p) => {
    await p.locator('[data-tile="curve"]').click();
    await p.locator('[data-tile="decode"]').click();
    await expect(p.getByTestId('tile-decode')).toBeVisible();
  }),
  'PC-E7': edit(LEFT_AND_PINNED, async (p) => {
    await p.locator('[data-tile="wheels"]').click();
    await p.locator('[data-tile="effects"]').click();
    await expect(p.getByTestId('tile-effects')).toBeVisible();
  }),
  'PC-E8': {
    query: '&renderDelay=4000', texts: ['Develop', 'Library', 'Film & Paper', 'Latitude', 'Adjust', 'Original', 'Export', 'Embedded preview'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true, filmstrip: true },
    setup: async (p) => {
      await p.goto(`/?open=${encodeURIComponent(ROLL)}&renderDelay=4000`);
      await expect(p.getByTestId('embedded-preview')).toBeVisible();
      await expect(p.getByTestId('status-line')).toContainText('Developing');
    },
  },
  // Crop is a stage of its own: the filmstrip steps away while it is open (the drawing has no filmstrip rule).
  'PC-E9': edit(LEFT_AND_PINNED.filter((t) => t !== 'Original'), async (p) => {
    await p.keyboard.press('c');
    await expect(p.getByTestId('tb-crop')).toHaveAttribute('aria-pressed', 'true');
    await expect(p.getByTestId('v2-filmstrip')).toHaveCount(0);
    // The drawing shows the Edit rail scrolled to Crop (its head at 336): scroll the built one there too.
    await expect(p.getByTestId('crop-body')).toBeVisible();
    await p.evaluate(() => {
      const list = document.querySelector('[data-testid="edit-sections"]')!, crop = document.querySelector('[data-testid="section-crop"]')!;
      list.scrollTop += crop.getBoundingClientRect().top - 336;
    });
  }, { rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true } }),
  'PC-E10': edit(EDIT_COMMON, async (p) => { await p.keyboard.press('y'); await expect(p.getByTestId('tb-compare')).toHaveAttribute('aria-pressed', 'true'); }),
  'PC-E11': edit(EDIT_COMMON, async (p) => { await p.getByTestId('tb-original').click(); await expect(p.getByTestId('tb-original')).toHaveClass(/on/); }),
  'PC-E12': edit([...EDIT_COMMON, 'Could not develop', 'The graphics device stopped responding.', 'Try Again'], async (p) => {
    await p.evaluate(() => (globalThis as unknown as { __spkMock: { failNextRenders(n: number): void } }).__spkMock.failNextRenders(1));
    await p.locator('[data-stock="kodak_gold_200"]').click();
    await expect(p.getByTestId('render-failed')).toBeVisible();
  }),
  'PC-E13': {
    texts: ['The engine cannot start', 'No Vulkan device was found.', 'The Library still opens; nothing develops.', 'Try Again', 'Show Details',
      'Engine stopped', 'Develop', 'Latitude', 'Export'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true, filmstrip: true },
    fills: [['[data-testid="engine-stopped"]', { x: 558, y: 324 }], ['[data-testid="engine-try-again"]', { x: 582, y: 436 }]],
    setup: async (p) => {
      await p.goto(`/?open=${encodeURIComponent(ROLL)}&hostFail=1`);
      await expect(p.getByTestId('engine-stopped')).toBeVisible();
    },
  },
  'PC-X1': edit(EDIT_COMMON, async (p) => { await p.getByTestId('tb-more').click(); await expect(p.getByTestId('more-menu')).toBeVisible(); }, {}),
  'PC-X2': edit(['Develop', 'Latitude', 'Export', 'Copy Settings'], async (p) => { await p.keyboard.press('Control+Alt+Shift+C'); await expect(p.getByTestId('copy-settings')).toBeVisible(); }),
  'PC-X3': edit(['Develop', 'Latitude', 'Export', 'Zoom to Fit', 'Show in File Explorer'], async (p) => {
    // Where the drawing's flyout opens: its top-left at (791, 424) in the window, (470, 344) in the picture.
    await p.getByTestId('picture').click({ button: 'right', position: { x: 470, y: 344 } });
    await expect(p.getByTestId('picture-menu')).toBeVisible();
  }),
  // Windows' host refuses the Digital Intermediate (README §3.8): its recipe is absent, as drawn.
  'PC-O1': edit(['Export', 'RECIPE', 'Format', 'Size', 'Colour', 'Quality', 'SAVE TO', 'Folder', 'Name', 'If it exists', 'Cancel'],
    async (p) => { await p.keyboard.press('Control+e'); await expect(p.getByTestId('export-dialog')).toBeVisible(); await expect(p.getByTestId('proof-stats')).not.toBeEmpty(); },
    { query: '&unsupported=digital_intermediate', fills: [['[data-testid="titlebar"]', { x: 0, y: 0 }], ['[data-testid="export-run"]', { fill: '#E1A95F', y0: 640, y1: 690 }]] }),
  'PC-N1': { ...edit(['Latitude', 'Adjust', { text: 'Darkroom', shift: UNDER_TILES }, 'Export'], undefined, { rule: { titleBar: true, rightWall: true, toolbar: true, filmstrip: true } }), viewport: { width: 768, height: 816 } },
  'PC-N2': { ...edit(['Develop', 'Library', 'Film & Paper', 'Latitude', 'Adjust'], async (p) => {
    await p.keyboard.press('F7');
    await expect(p.getByTestId('rail-left')).toHaveAttribute('data-mode', 'over');
  }, { rule: { titleBar: true, toolbar: true, filmstrip: true } }), viewport: { width: 768, height: 816 } },
  'PC-N3': { ...edit(['Develop', 'Navigator', 'Film & Paper', 'Latitude', 'Adjust', 'Export'], undefined, { rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true, filmstrip: true } }), viewport: { width: 1280, height: 672, scale: 1.5 } },
  'PC-L0': {
    texts: ['An empty darkroom', 'New Catalog…', 'Open Library…', 'Open Capture One Catalog…', 'Add a Folder…', 'Drop a folder or pictures here.', 'Info', 'No library open', 'No selection'],
    rule: { titleBar: true, leftWall: true, rightWall: true },
    setup: async (p) => { await p.goto('/'); await p.getByTestId('workspace-library').click(); await expect(p.getByTestId('first-run')).toBeVisible(); },
  },
  'PC-L1': {
    texts: ['Info', 'Darkroom 2026', 'All Photos', 'LIBRARY', 'Favourites', 'Recent Imports', 'LIGHT TABLE', 'COLLECTIONS', 'FOLDERS', 'Show in File Explorer', 'Name', 'Capture'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true },
    fills: [['[data-testid="library-sidebar"]', { x: 0, y: 32 }]],
    setup: async (p) => { await openLibrary(p, 'Darkroom 2026'); await p.getByTestId('library-tile').first().click(); },
  },
  'PC-L2': {
    texts: ['Info', 'Darkroom 2026', 'LIBRARY', 'LIGHT TABLE'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true },
    setup: async (p) => {
      await openLibrary(p, 'Darkroom 2026');
      const tiles = p.getByTestId('library-tile');
      // Ctrl+click picks (Meta on the Mac that runs this harness: Ctrl+click is a right-click there).
      await tiles.nth(0).click(); await tiles.nth(1).click({ modifiers: ['ControlOrMeta'] }); await tiles.nth(2).click({ modifiers: ['ControlOrMeta'] });
      await expect(p.getByTestId('info-picked')).toBeVisible();
    },
  },
  'PC-L3': {
    // The drawing shows the catalog mid-read (a "Reading · 4,210 of 9,660" line in the source well); the
    // mock helper reads at once, so the well is one 16 epx line shorter and the rows under it rise by 16.
    texts: ['Info', 'Archive', 'All Images', { text: 'CATALOG', shift: { y: -16 } }, 'Show in File Explorer', 'Name', 'Capture'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true },
    setup: async (p) => { await openLibrary(p, 'Archive'); await p.getByTestId('library-tile').first().click(); },
  },
  'PC-L4': {
    texts: ['Info', 'Coast 2026', 'SESSION', 'Capture', 'Selects', 'Output', 'Trash'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true },
    setup: async (p) => { await openLibrary(p, 'Coast 2026'); await p.getByTestId('library-tile').first().click(); },
  },
  'PC-L6': {
    texts: ['Info', 'Recent', 'New Catalog…', 'New Session…', 'Open Library…', 'Open Capture One Catalog…', 'Add a Folder…', 'Copy Photos In…', 'Close Library'],
    rule: { titleBar: true, leftWall: true, rightWall: true, toolbar: true },
    setup: async (p) => { await openLibrary(p, 'Darkroom 2026'); await p.getByTestId('library-tile').first().click(); await p.getByTestId('source-well').click(); await expect(p.getByTestId('source-menu')).toBeVisible(); },
  },
  'PC-T1': {
    // The sheet's own scale (and so the 1:1 · A4 footer under it) is not the drawing's; the sidebar is.
    texts: ['Darkroom 2026', 'LIBRARY', 'LIGHT TABLE', 'FILMS', 'COLLECTIONS'],
    rule: { titleBar: true, leftWall: true },
    setup: async (p) => { await openLibrary(p, 'Darkroom 2026'); await p.getByTestId('collection-table').click(); await expect(p.getByTestId('light-table')).toBeVisible(); },
  },
  'PC-K1': {
    texts: ['Darkroom 2026', 'LIBRARY', 'LIGHT TABLE'],
    rule: { titleBar: true, leftWall: true },
    setup: async (p) => { await openLibrary(p, 'Darkroom 2026'); await p.getByTestId('new-contact-sheet').click(); await expect(p.getByTestId('contact-sheet')).toBeVisible(); },
  },
  'PC-G1': {
    texts: [...SETTINGS_PANES, { text: 'Recipes', near: { x: 252, y: 82 } }, 'RECIPES', 'Size', 'Colour', 'Quality', 'Folder', 'Name', 'If it exists'], origin: '.v2-settings', viewport: { width: 1536, height: 816 },
    // Windows' host refuses the Digital Intermediate (README §3.8), so its recipe is not offered (three recipes, as drawn).
    setup: async (p) => { await openRoll(p, '&unsupported=digital_intermediate'); await p.keyboard.press('Control+,'); await p.getByTestId('pane-recipes').click(); await expect(p.getByTestId('settings-recipes')).toBeVisible(); },
  },
  'PC-G2': {
    texts: [...SETTINGS_PANES, { text: 'General', near: { x: 252, y: 82 } }, 'GENERAL', 'Language', 'Interface Scale', 'When Reopened', 'UPDATES', 'LAYOUT', 'Reset All Layout'], origin: '.v2-settings', viewport: { width: 1536, height: 816 },
    setup: async (p) => { await openRoll(p); await p.keyboard.press('Control+,'); await p.getByTestId('pane-general').click(); await expect(p.getByTestId('settings-general')).toBeVisible(); },
  },
  'PC-G3': {
    texts: [...SETTINGS_PANES, { text: 'Engine', near: { x: 252, y: 82 } }, 'THIS COMPUTER', 'Graphics', 'Display', 'NOT ON WINDOWS YET', 'Scene Placement', 'Digital Intermediate'], origin: '.v2-settings', viewport: { width: 1536, height: 816 },
    setup: async (p) => { await openRoll(p, '&unsupported=digital_intermediate,scene_latitude_mapping'); await p.keyboard.press('Control+,'); await p.getByTestId('pane-engine').click(); await expect(p.getByTestId('gated-note')).toBeVisible(); },
  },
};

export const NOT_IMPLEMENTED: Record<string, string> = {
  'PC-E5': 'Film Edge and Date Back are drawn "once ported": the v1 Windows host still refuses overscan/date_imprint in the mock; with ?allFeatures=1 the v1 sections appear but are not redrawn to PC-E5',
  'PC-O2': 'the exporting flyout is checked by behaviour (T3), not against the drawing',
  'PC-L5': 'a folder source needs a folder chooser (a native dialog), which the browser harness cannot drive',
  'PC-T2': 'Actual Size has no display size in a browser (README §4.2: no 1:1 disc where the size is unknown)',
};

// ------------------------------------------------------------------ harness

async function textBoxes(page: Page, text: string) {
  return page.evaluate((t) => {
    const out: { left: number; right: number; top: number; bottom: number }[] = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
    for (let n = walker.nextNode() as HTMLElement | null; n; n = walker.nextNode() as HTMLElement | null) {
      const own = [...n.childNodes].filter((c) => c.nodeType === Node.TEXT_NODE).map((c) => c.textContent ?? '').join('').replace(/\s+/g, ' ').trim();
      const all = (n.textContent ?? '').replace(/\s+/g, ' ').trim();
      if (own !== t && !(all === t && n.children.length > 0 && [...n.children].every((c) => !(c.textContent ?? '').trim() || (c.textContent ?? '').trim() === t))) continue;
      const style = getComputedStyle(n);
      if (style.visibility === 'hidden' || style.display === 'none') continue;
      const range = document.createRange();
      range.selectNodeContents(n);
      const r = range.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0) continue;
      out.push({ left: r.left, right: r.right, top: r.top, bottom: r.bottom });
    }
    return out;
  }, text);
}

async function checkPage(page: Page, svg: SvgPage, c: PageCase) {
  const misses: string[] = [];
  const o = c.origin ? await page.locator(c.origin).first().boundingBox() : null;
  if (c.origin && !o) misses.push(`${c.origin} is not on screen`);
  for (const spec of c.texts) {
    const s = typeof spec === 'string' ? { text: spec } : spec;
    const found = findText(svg, s.text, s.near);
    if (!found) { misses.push(`"${s.text}" is not on the drawing`); continue; }
    const shift = 'shift' in s ? s.shift : undefined;
    const want = { ...found, x: found.x + (shift?.x ?? 0) + (o?.x ?? 0), y: found.y + (shift?.y ?? 0) + (o?.y ?? 0) };
    const boxes = await textBoxes(page, s.text);
    if (!boxes.length) { misses.push(`"${s.text}" not on screen`); continue; }
    const tol = { ...TOL, ...(s.tol ?? {}) };
    const ax = (b: (typeof boxes)[number]) => (want.anchor === 'middle' ? (b.left + b.right) / 2 : want.anchor === 'end' ? b.right : b.left);
    // The drawing's y is a baseline; a line box's baseline sits ~22 % of the font size above its bottom.
    const by = (b: (typeof boxes)[number]) => b.bottom - (b.bottom - b.top - want.size) / 2 - want.size * 0.22;
    const best = boxes.map((b) => ({ dx: ax(b) - want.x, dy: by(b) - want.y })).sort((a, b) => Math.hypot(a.dx, a.dy) - Math.hypot(b.dx, b.dy))[0]!;
    if (Math.abs(best.dx) > tol.x || Math.abs(best.dy) > tol.y)
      misses.push(`"${s.text}" at (${(want.x + best.dx).toFixed(0)}, ${(want.y + best.dy).toFixed(0)}), drawn at (${want.x.toFixed(0)}, ${want.y.toFixed(0)}) [${want.anchor}]`);
  }
  const rule = c.rule ?? {};
  const W = svg.width;
  const box = async (sel: string) => page.locator(sel).first().boundingBox();
  if (rule.titleBar) {
    const t = await box('[data-testid="titlebar"]');
    if (!t || Math.round(t.height) !== 32 || Math.round(t.width) !== W) misses.push(`title bar ${JSON.stringify(t)} is not ${W} × 32`);
  }
  const wallX = svg.lines.filter((l) => l.x1 === l.x2 && l.stroke === '#262625' && l.y2 - l.y1 > 400).map((l) => Math.floor(l.x1));
  if (rule.leftWall) {
    const want = Math.min(...wallX);
    const r = await box('[data-testid="rail-left"], [data-testid="library-sidebar"]');
    if (!r || Math.abs(r.x + r.width - want) > 1) misses.push(`left rail ends at ${r ? r.x + r.width : 'none'}, the wall is drawn at ${want}`);
  }
  if (rule.rightWall) {
    const want = Math.max(...wallX);
    const r = await box('[data-testid="rail-right"], [data-testid="info-rail"]');
    if (!r || Math.abs(r.x - want) > 1.5) misses.push(`right rail starts at ${r ? r.x : 'none'}, the wall is drawn at ${want}`);
  }
  if (rule.toolbar) {
    const line = svg.lines.find((l) => l.y1 === l.y2 && l.y1 > 40 && l.y1 < 100 && l.x2 - l.x1 > 200);
    const t = await box('[data-testid="toolbar"], .v2-toolbar.lib');
    if (!line || !t || Math.abs(t.y + t.height - Math.ceil(line.y1)) > 1.5) misses.push(`toolbar bottom ${t ? t.y + t.height : 'none'} vs the rule at ${line?.y1}`);
  }
  if (rule.filmstrip) {
    // The rule across the picture column: it starts where the picture does (after the left wall, if one is drawn).
    const leftWall = rule.leftWall ? wallX.filter((x) => x < 400) : [];
    const start = leftWall.length ? Math.min(...leftWall) + 1 : 0;
    const line = svg.lines.find((l) => l.y1 === l.y2 && l.y1 > svg.height - 120 && l.y1 < svg.height && l.x2 - l.x1 > 200 && Math.round(l.x1) === start);
    const f = await box('[data-testid="v2-filmstrip"]');
    if (!line || !f || Math.abs(f.y - line.y1) > 1.5 || Math.round(f.height) !== Math.round(svg.height - line.y1)) misses.push(`filmstrip ${JSON.stringify(f)} vs the rule at ${line?.y1}`);
  }
  for (const [sel, at] of c.fills ?? []) {
    const rect = 'fill' in at
      ? svg.rects.find((r) => r.fill === normal(at.fill) && r.y >= at.y0 && r.y + r.height <= at.y1)
      : svg.rects.find((r) => Math.abs(r.x - at.x) < 0.6 && Math.abs(r.y - at.y) < 0.6 && r.fill.startsWith('#'));
    if (!rect) { misses.push(`no filled rect at ${JSON.stringify(at)} on the drawing`); continue; }
    const got = await page.locator(sel).first().evaluate((el) => getComputedStyle(el).backgroundColor);
    const m = /rgba?\((\d+), (\d+), (\d+)/.exec(got);
    const hex = m ? '#' + [m[1], m[2], m[3]].map((v) => Number(v).toString(16).padStart(2, '0')).join('').toUpperCase() : got;
    if (hex !== normal(rect.fill)) misses.push(`${sel} is ${hex}, drawn ${rect.fill}`);
  }
  expect(misses, `${c.file}:\n  ${misses.join('\n  ')}`).toEqual([]);
}

const index = readIndex();
const byId = new Map(index.map((r) => [r.id, r]));

test('every INDEX.md page is either implemented or listed as not implemented, never both', () => {
  const ids = index.map((r) => r.id).sort();
  const listed = [...Object.keys(IMPLEMENTED), ...Object.keys(NOT_IMPLEMENTED)].sort();
  expect(listed).toEqual(ids);
  for (const id of Object.keys(IMPLEMENTED)) expect(NOT_IMPLEMENTED[id], id).toBeUndefined();
});

for (const [id, c] of Object.entries(IMPLEMENTED)) {
  const row = byId.get(id);
  test(`${id} ${row?.page ?? '(not in INDEX.md)'}`, async ({ browser }) => {
    expect(row, `${id} is not a page of INDEX.md`).toBeTruthy();
    const svg = readPage(row!.file);
    const vp = c.viewport ?? { width: svg.width, height: svg.height };
    const context = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.scale ?? 1 });
    const page = await context.newPage();
    try {
      await page.addInitScript(() => { try { localStorage.clear(); } catch { /* none */ } });
      await c.setup(page);
      await checkPage(page, svg, { ...c, file: row!.file } as PageCase);
    } finally { await context.close(); }
  });
}

// ------------------------------------------------------------------- T2b
//
// What the text anchors above cannot see: a tile with no glyph on it, a
// capsule drawn as plain text, a name that runs out of its card. Three checks
// per page, all read from the page's SVG and the built DOM, none from pixels:
//  - glyphs: every icon the drawing puts in a claimed region has a built
//    graphic (an <svg> or <img>) at its place with painted area — an inked
//    shape with a non-empty box. An empty tile face fails.
//  - controls: every control shape the drawing puts there (a tile's face, a
//    capsule, a disc, a button, a well) has a built element whose box is the
//    drawn box within tolerance.
//  - fit, in English and in 简体中文: no text is clipped by an ancestor, ellipsised
//    or wider than its own box, and no two labels of one row overlap.
// A drawn item that is deliberately not built is named in the page's
// `notBuilt` with its reason (and mirrored in PARITY.md); one that is neither
// built nor listed fails, and so does a listed one that is built. A place is
// taken relative to the item's owner — the label inside or under it, else the
// nearest text on its row in its column — so a section that moved as a whole
// is still found; with no owner on screen the drawn place is used as it is.

const GLYPH_TOL = 10;
/** How far a section may have moved from its drawn place and still be placed against its owner. */
const OWNER_REACH = 240;
const norm = (t: string) => t.replace(/\s+/g, ' ').trim();

type Rect = { left: number; right: number; top: number; bottom: number };
/** What T2b reads of a built page, once: its texts, its glyph graphics and every visible element's box. */
interface Snapshot {
  /** Every text node's words and box, and the box of an element whose whole text they are (for words split over nodes). */
  texts: { text: string; rect: Rect; size: number; own: boolean }[];
  /** Every top-level <svg> or <img> no bigger than 64 epx, and whether it has painted area. */
  glyphs: { rect: Rect; inked: boolean }[];
  /** Every visible element's box, with a short name for the report. */
  boxes: { rect: Rect; name: string }[];
}

async function snapshot(page: Page): Promise<Snapshot> {
  return page.evaluate(() => {
    const R = (r: DOMRect) => ({ left: r.left, right: r.right, top: r.top, bottom: r.bottom });
    const shown = (el: Element) => el.checkVisibility({ opacityProperty: true, visibilityProperty: true });
    const texts: Snapshot['texts'] = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const text = (n.textContent ?? '').replace(/\s+/g, ' ').trim();
      const el = n.parentElement;
      if (!text || !el || !shown(el)) continue;
      const r = document.createRange();
      r.selectNodeContents(n);
      const b = r.getBoundingClientRect();
      if (b.width > 0 && b.height > 0) texts.push({ text, rect: R(b), size: parseFloat(getComputedStyle(el).fontSize), own: true });
    }
    for (const el of document.querySelectorAll('body *')) {
      // an element whose words are split over several nodes (an element child, or "{n} %" in JSX)
      if ((!el.children.length && el.childNodes.length < 2) || !shown(el)) continue;
      const text = (el.textContent ?? '').replace(/\s+/g, ' ').trim();
      if (!text || text.length > 60) continue;
      const r = document.createRange();
      r.selectNodeContents(el);
      const b = r.getBoundingClientRect();
      if (b.width > 0 && b.height > 0) texts.push({ text, rect: R(b), size: parseFloat(getComputedStyle(el).fontSize), own: false });
    }
    const clear = (c: string) => c === 'none' || c === 'transparent' || /rgba\(.*,\s*0\)$/.test(c);
    const inked = (s: Element) => {
      const cs = getComputedStyle(s);
      const stroke = !clear(cs.stroke) && parseFloat(cs.strokeWidth) > 0, fill = !clear(cs.fill);
      const bb = (s as SVGGraphicsElement).getBBox?.();
      return (stroke || fill) && !!bb && (bb.width > 0 || bb.height > 0) && Number(cs.opacity) > 0;
    };
    const glyphs: Snapshot['glyphs'] = [];
    for (const el of document.querySelectorAll('svg, img')) {
      if (el.parentElement?.closest('svg') || !shown(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0 || r.width > 64 || r.height > 64) continue;
      glyphs.push({ rect: R(r), inked: el.tagName.toLowerCase() === 'img' ? (el as HTMLImageElement).complete && (el as HTMLImageElement).naturalWidth > 0
        : [...el.querySelectorAll('path, circle, ellipse, rect, line, polyline, polygon')].some(inked) });
    }
    const boxes: Snapshot['boxes'] = [];
    for (const el of document.querySelectorAll('body *')) {
      const r = el.getBoundingClientRect();
      if (r.width <= 0 || r.height <= 0 || !shown(el)) continue;
      boxes.push({ rect: R(r), name: `${el.tagName.toLowerCase()}.${(typeof el.className === 'string' ? el.className : '').split(' ')[0]}` });
    }
    return { texts, glyphs, boxes };
  });
}

/** Where a drawn text's anchor is on screen: the box of those words nearest the drawn place, on its side of every wall. */
function ownerOnScreen(snap: Snapshot, o: SvgText, origin: { x: number; y: number }, walls: number[]) {
  const words = norm(o.text);
  const own = snap.texts.filter((t) => t.own && t.text === words);
  // the same words in the drawing's size (a tile's label at 12 is not the open tile's title at 14)
  const sized = own.filter((t) => Math.abs(t.size - o.size) <= 1.5);
  const found = sized.length ? sized : own.length ? own : snap.texts.filter((t) => !t.own && t.text === words);
  // ... on the drawn side of every wall: the toolbar's words are not the rail's
  const side = (x: number) => walls.map((w) => x < w);
  const want0 = side(o.x + origin.x);
  const boxes = found.map((t) => t.rect).filter((b) => side((b.left + b.right) / 2).every((s, i) => s === want0[i]));
  if (!boxes.length) return null;
  const ax = (b: Rect) => (o.anchor === 'middle' ? (b.left + b.right) / 2 : o.anchor === 'end' ? b.right : b.left);
  const by = (b: Rect) => b.bottom - (b.bottom - b.top - o.size) / 2 - o.size * 0.22;
  const want = { x: o.x + origin.x, y: o.y + origin.y };
  const best = boxes.map((b) => ({ x: ax(b), y: by(b) })).sort((p, q) => Math.hypot(p.x - want.x, p.y - want.y) - Math.hypot(q.x - want.x, q.y - want.y))[0]!;
  // The same words elsewhere on the page (a "Fit" chip in the Navigator for the toolbar's "Fit") are not this owner.
  return Math.hypot(best.x - want.x, best.y - want.y) <= OWNER_REACH ? best : null;
}

function builtAt(snap: Snapshot, d: Drawn, at: { x: number; y: number }, box?: { x: number; y: number; width: number; height: number }, freeWidth = false): true | string | false {
  if (d.kind === 'glyph') {
    const tol = GLYPH_TOL;
    return snap.glyphs.some((g) => g.inked && at.x >= g.rect.left - tol && at.x <= g.rect.right + tol && at.y >= g.rect.top - tol && at.y <= g.rect.bottom + tol);
  }
  const b = box!;
  const tx = Math.max(8, b.width * 0.15), ty = Math.max(6, b.height * 0.15);
  let near = '', nearCost = Infinity;
  for (const { rect: r, name } of snap.boxes) {
    const dl = Math.abs(r.left - b.x), dr = freeWidth ? 0 : Math.abs(r.right - (b.x + b.width)), dt = Math.abs(r.top - b.y), db = Math.abs(r.bottom - (b.y + b.height));
    if (dl <= tx && dr <= tx && dt <= ty && db <= ty) return true;
    const cost = dl + dr + dt + db;
    if (cost < nearCost && cost < 80) { nearCost = cost; near = `${name} ${Math.round(r.right - r.left)}×${Math.round(r.bottom - r.top)} at (${Math.round(r.left)}, ${Math.round(r.top)})`; }
  }
  return near ? `nearest: ${near}` : false;
}

async function checkFidelity(page: Page, file: string, c: Omit<PageCase, 'file'>) {
  const svg = readPage(file);
  const o = c.origin ? await page.locator(c.origin).first().boundingBox() : null;
  const origin = { x: o?.x ?? 0, y: o?.y ?? 0 };
  const claims = c.claims ?? [[0, 0, svg.width, svg.height]];
  const walls = c.origin ? [] : svg.lines.filter((l) => l.x1 === l.x2 && l.stroke === '#262625' && l.y2 - l.y1 > 400).map((l) => l.x1 + 0.5);
  const notBuilt = c.notBuilt ?? {};
  const snap = await snapshot(page);
  const misses: string[] = [];
  const used = new Set<string>();
  for (const d of drawnOf(file)) {
    if (!claims.some(([x0, y0, x1, y1]) => d.at[0] >= x0 && d.at[0] <= x1 && d.at[1] >= y0 && d.at[1] <= y1)) continue;
    let dx = origin.x, dy = origin.y;
    let owner: { x: number; y: number } | null = null, by: SvgText | null = null;
    for (const w of d.owners) { owner = ownerOnScreen(snap, w, origin, walls); if (owner) { by = w; break; } }
    if (owner && by) { dx = owner.x - by.x; dy = owner.y - by.y; }
    const at = { x: d.at[0] + dx, y: d.at[1] + dy };
    // A tile drawn with its label (HSL) whose label is nowhere on screen is not built, whatever stands at its place.
    if (d.label && by !== d.label && !ownerOnScreen(snap, d.label, origin, walls)) {
      if (d.name in notBuilt) { used.add(d.name); continue; }
      misses.push(`${d.name} is not built (its label "${norm(d.label.text)}" is not on screen)`);
      continue;
    }
    const box = d.box && { x: d.box.x + dx, y: d.box.y + dy, width: d.box.width, height: d.box.height };
    // A capsule sized by its words, showing other words than the drawing's (a frame name, a count): its width is the words', not the drawing's.
    const inside = !!d.box && d.name.startsWith('control "');
    const found = builtAt(snap, d, at, box, inside && by !== d.owner);
    const ok = found === true;
    if (d.name in notBuilt) { used.add(d.name); if (ok) misses.push(`${d.name} is listed as not built, and is built — remove it from notBuilt`); continue; }
    if (!ok) misses.push(`${d.name} is not built${box ? ` as a ${box.width.toFixed(0)}×${box.height.toFixed(0)} box at (${box.x.toFixed(0)}, ${box.y.toFixed(0)})` : ` at (${at.x.toFixed(0)}, ${at.y.toFixed(0)})`}${by ? ` [placed against "${norm(by.text)}"]` : ''}${typeof found === 'string' ? ` — ${found}` : ''}`);
  }
  for (const k of Object.keys(notBuilt)) if (!used.has(k)) misses.push(`notBuilt names "${k}", which this page does not draw in its claims`);
  expect(misses, `${file} — drawn but not built:\n  ${misses.join('\n  ')}`).toEqual([]);
}

/** Every visible text: not clipped, not ellipsised, not wider than its box; no two labels of a row overlapping.
 * Text is measured by its line boxes (each line's glyph box cut to the line height), so a glyph's
 * ascender over a tight line height is not a collision; a third line under a two-line box is. */
async function checkFit(page: Page) {
  return page.evaluate(() => {
    const out: string[] = [];
    type Box = { left: number; right: number; top: number; bottom: number };
    const leaves: { el: Element; lines: Box[]; text: string }[] = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    const name = (el: Element, text: string) => `${text ? `"${text.slice(0, 40)}" ` : ''}(${el.tagName.toLowerCase()}${typeof el.className === 'string' && el.className ? '.' + el.className.split(' ')[0] : ''}${el.getAttribute('data-testid') ? `[${el.getAttribute('data-testid')}]` : ''})`;
    for (let t = walker.nextNode(); t; t = walker.nextNode()) {
      const text = (t.textContent ?? '').replace(/\s+/g, ' ').trim();
      const el = t.parentElement;
      if (!text || !el || el.closest('script, style, svg, [aria-hidden="true"], .v2-menubar-measure, [data-fit="scale"], textarea')) continue;
      let hidden = false;
      for (let a: Element | null = el; a; a = a.parentElement) {
        const cs = getComputedStyle(a);
        if (cs.visibility === 'hidden' || cs.display === 'none' || Number(cs.opacity) === 0) { hidden = true; break; }
      }
      if (hidden) continue;
      const cs = getComputedStyle(el);
      const lh = cs.lineHeight === 'normal' ? parseFloat(cs.fontSize) * 1.2 : parseFloat(cs.lineHeight);
      const range = document.createRange();
      range.selectNodeContents(t);
      const lines = [...range.getClientRects()].filter((r) => r.width > 0 && r.height > 0).map((r) => {
        const cut = Math.max(0, (r.height - lh) / 2);
        return { left: r.left, right: r.right, top: r.top + cut, bottom: r.bottom - cut };
      });
      if (!lines.length) continue;
      leaves.push({ el, lines, text });
      if (cs.textOverflow === 'ellipsis' && el.scrollWidth > el.clientWidth + 1) out.push(`${name(el, text)} is ellipsised`);
      if (cs.display !== 'inline' && el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1) out.push(`${name(el, text)} is wider than its box (${el.scrollWidth} > ${el.clientWidth})`);
      outer: for (const box of lines) {
        for (let a: Element | null = el; a && a !== document.body; a = a.parentElement) {
          const s = getComputedStyle(a);
          if (s.overflowX === 'visible' && s.overflowY === 'visible') continue;
          const ab = a.getBoundingClientRect();
          const sx = /auto|scroll/.test(s.overflowX), sy = /auto|scroll/.test(s.overflowY);
          if (sx || sy) {
            // A scroller may hold text out of view along its scrolling axis, not across it.
            const across = sy && !sx ? box.left < ab.left - 1 || box.right > ab.right + 1 : sx && !sy ? box.top < ab.top - 1 || box.bottom > ab.bottom + 1 : false;
            if (across) { out.push(`${name(el, text)} runs out of its scroller ${name(a, '')}`); break outer; }
            break;
          }
          if (box.left < ab.left - 1 || box.right > ab.right + 1 || box.top < ab.top - 1 || box.bottom > ab.bottom + 1) {
            out.push(`${name(el, text)} is clipped by ${name(a, '')}`);
            break outer;
          }
        }
      }
    }
    // Labels of one row: two leaves under one parent or one grandparent must not overlap.
    for (let i = 0; i < leaves.length; i++) for (let j = i + 1; j < leaves.length; j++) {
      const a = leaves[i]!, b = leaves[j]!;
      if (a.el === b.el || a.el.contains(b.el) || b.el.contains(a.el)) continue;
      const pa = a.el.parentElement, pb = b.el.parentElement;
      const kin = pa === pb || pa?.parentElement === pb?.parentElement || pa === pb?.parentElement || pb === pa?.parentElement;
      if (!kin) continue;
      const hit = a.lines.some((p) => b.lines.some((q) => Math.min(p.right, q.right) - Math.max(p.left, q.left) > 1 && Math.min(p.bottom, q.bottom) - Math.max(p.top, q.top) > 1));
      if (hit) out.push(`${name(a.el, a.text)} overlaps ${name(b.el, b.text)}`);
    }
    return [...new Set(out)];
  });
}

for (const [id, c] of Object.entries(IMPLEMENTED)) {
  const row = byId.get(id);
  const open = async (browser: Browser) => {
    const svg = readPage(row!.file);
    const vp = c.viewport ?? { width: svg.width, height: svg.height };
    const context = await browser.newContext({ viewport: { width: vp.width, height: vp.height }, deviceScaleFactor: vp.scale ?? 1 });
    const page = await context.newPage();
    await page.addInitScript(() => { try { localStorage.clear(); } catch { /* none */ } });
    await c.setup(page);
    return { context, page };
  };
  test(`T2b ${id} glyphs and controls`, async ({ browser }) => {
    const { context, page } = await open(browser);
    try { await checkFidelity(page, row!.file, { ...c, ...FIDELITY[id] }); } finally { await context.close(); }
  });
  for (const lang of ['english', 'simplifiedChinese'] as const) {
    test(`T2b ${id} fits (${lang === 'english' ? 'English' : '简体中文'})`, async ({ browser }) => {
      const { context, page } = await open(browser);
      try {
        if (lang !== 'english') {
          // The language switches live (Settings ▸ General ▸ Language): every string is looked up at render.
          await page.evaluate(() => (globalThis as unknown as { __spk: { settingsStore: { getState(): { set(k: string, v: unknown): void } } } }).__spk.settingsStore.getState().set('language', 'simplifiedChinese'));
          await expect(page.locator('html')).toHaveAttribute('lang', 'zh-Hans');
        }
        await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
        const bad = await checkFit(page);
        expect(bad, `${row!.file} in ${lang}:\n  ${bad.join('\n  ')}`).toEqual([]);
      } finally { await context.close(); }
    });
  }
}
