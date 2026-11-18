// The one window's rule on numbers (PRD-W5 §2, R4) and the mode as state.

import { describe, expect, it } from 'vitest';
import { BROWSER, MIN_PICTURE, computeLayout, toggleRail, type LayoutInput } from './layout';
import { goBack, setWorkspace, uiStore, UI_INITIAL } from './ui';

const at = (width: number, height: number, p: Partial<LayoutInput> = {}): LayoutInput => ({
  width, height, leftHidden: false, rightHidden: false, fullGrid: false, navigatorHidden: false,
  overlay: null, railLeft: 320, browserWidth: BROWSER.width, fullScreen: false, ...p,
});

describe('the one window', () => {
  it('1536 × 816: the column at 320, the browser at the Mac’s 430, the picture between', () => {
    const l = computeLayout(at(1536, 816));
    expect([l.left, l.right]).toEqual(['docked', 'docked']);
    expect([l.leftWidth, l.rightWidth]).toEqual([320, 430]);
    expect(l.picture).toEqual({ x: 321, width: 1536 - 321 - 431 });
    expect(l.navigator).toBe('well');
    expect(l.overflow).toEqual({ zoomCropOriginal: false, navCompareTitle: false });
  });
  it('a narrow window folds the browser first (after shrinking it to 240), then the column', () => {
    // The browser gives up width before it folds: the picture keeps its least.
    const tight = computeLayout(at(1200, 816));
    expect([tight.left, tight.right]).toEqual(['docked', 'docked']);
    expect(tight.picture.width).toBe(MIN_PICTURE);
    expect(tight.rightWidth).toBe(1200 - 321 - MIN_PICTURE - 1);
    // Under column + 240 + the least picture, the browser folds; the column stays.
    const edge = 321 + BROWSER.min + 1 + MIN_PICTURE;
    expect(computeLayout(at(edge, 816)).right).toBe('docked');
    const half = computeLayout(at(edge - 1, 816));
    expect([half.left, half.right, half.picture.width]).toEqual(['docked', 'folded', edge - 1 - 321]);
    // Under column + the least picture, the column folds as well: a snapped half of a 1536 screen.
    const snapped = computeLayout(at(768, 816));
    expect([snapped.left, snapped.right, snapped.picture.width]).toEqual(['folded', 'folded', 768]);
    expect(computeLayout(at(321 + MIN_PICTURE, 816)).left).toBe('docked');
    expect(computeLayout(at(321 + MIN_PICTURE - 1, 816)).left).toBe('folded');
  });
  it('a folded pane comes over the picture, one at a time, and the picture keeps its width', () => {
    const l = computeLayout(at(768, 816, { overlay: 'right' }));
    expect([l.left, l.right, l.picture.width]).toEqual(['folded', 'over', 768]);
    expect(toggleRail('right', computeLayout(at(768, 816)), 768)).toEqual({ overlay: 'right' });
    expect(toggleRail('right', l, 768)).toEqual({ overlay: null });
  });
  it('a pane hidden by hand stays hidden at any width until opened; the column hidden gives the browser its room', () => {
    const l = computeLayout(at(1536, 816, { rightHidden: true }));
    expect(l.right).toBe('hidden');
    expect(l.picture.width).toBe(1536 - 321);
    expect(toggleRail('right', l, 1536)).toEqual({ hide: false, overlay: null });
    expect(toggleRail('right', computeLayout(at(900, 816, { rightHidden: true })), 900)).toEqual({ hide: false, overlay: 'right' });
    const noColumn = computeLayout(at(900, 816, { leftHidden: true }));
    expect([noColumn.left, noColumn.right, noColumn.picture.x]).toEqual(['hidden', 'docked', 0]);
  });
  it('the full grid gives the browser everything right of the column', () => {
    const l = computeLayout(at(1536, 816, { fullGrid: true }));
    expect([l.fullGrid, l.right, l.picture.width, l.rightWidth]).toEqual([true, 'docked', 0, 1536 - 321]);
  });
  it('the Navigator folds under 720 tall; 1280 × 672 at 150 % keeps the column and the browser', () => {
    const l = computeLayout(at(1280, 672));
    expect([l.navigator, l.left, l.right]).toEqual(['line', 'docked', 'docked']);
  });
  it('widths clamp (the column 280–440, the browser 240–900); the picture bar overflows by the picture’s width', () => {
    expect(computeLayout(at(2560, 816, { railLeft: 900, browserWidth: 2000 })).leftWidth).toBe(440);
    expect(computeLayout(at(2560, 816, { browserWidth: 2000 })).rightWidth).toBe(900);
    expect(computeLayout(at(1536, 816, { browserWidth: 10 })).rightWidth).toBe(240);
    expect(computeLayout(at(1536, 816, { browserWidth: 900 })).rightWidth).toBe(1536 - 321 - MIN_PICTURE - 1);
    expect(computeLayout(at(1300, 816)).overflow).toEqual({ zoomCropOriginal: true, navCompareTitle: false });
    expect(computeLayout(at(1300, 816, { browserWidth: 900 })).overflow).toEqual({ zoomCropOriginal: true, navCompareTitle: true });
  });
  it('full screen drops the title bar', () => {
    expect(computeLayout(at(1536, 864, { fullScreen: true })).titleBar).toBe(0);
  });
});

describe('the mode', () => {
  it('switches, remembers where it came from, and goes back', () => {
    uiStore.setState(UI_INITIAL);
    setWorkspace('library');
    expect(uiStore.getState()).toMatchObject({ workspace: 'library', previous: 'develop' });
    goBack();
    expect(uiStore.getState()).toMatchObject({ workspace: 'develop', previous: 'library' });
  });
  it('the full grid is the Library’s: entering Develop or Edit gives the picture back', () => {
    uiStore.setState({ ...UI_INITIAL, workspace: 'library', fullGrid: true });
    setWorkspace('edit');
    expect(uiStore.getState().fullGrid).toBe(false);
  });
});
