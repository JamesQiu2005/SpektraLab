// The window rule on numbers (README §1.3) and the workspace switch.

import { describe, expect, it } from 'vitest';
import { computeLayout, toggleRail, type LayoutInput } from './layout';
import { goBack, setWorkspace, uiStore, UI_INITIAL } from './ui';

const at = (width: number, height: number, p: Partial<LayoutInput> = {}): LayoutInput => ({
  width, height, leftHidden: false, rightHidden: false, filmstripHidden: false, navigatorHidden: false,
  overlay: null, railLeft: 320, railRight: 320, fullScreen: false, ...p,
});

describe('the window rule', () => {
  it('1536 × 816: both rails at 320, the picture 894 wide', () => {
    const l = computeLayout(at(1536, 816));
    expect([l.left, l.right]).toEqual(['docked', 'docked']);
    expect(l.picture).toEqual({ x: 321, width: 894 });
    expect(l.filmstrip).toBe(true);
    expect(l.navigator).toBe('well');
    expect(l.overflow).toEqual({ zoomCropOriginal: false, navCompareTitle: false });
  });
  it('under 1180 the left rail folds by itself; under 760 both do', () => {
    expect(computeLayout(at(1179, 816)).left).toBe('folded');
    expect(computeLayout(at(1180, 816)).left).toBe('docked');
    const half = computeLayout(at(768, 816));
    expect([half.left, half.right, half.picture.width]).toEqual(['folded', 'docked', 447]);
    const third = computeLayout(at(512, 816));
    expect([third.left, third.right, third.picture.width]).toEqual(['folded', 'folded', 512]);
  });
  it('a folded rail comes over the picture, one at a time, and the picture keeps its width', () => {
    const l = computeLayout(at(768, 816, { overlay: 'left' }));
    expect(l.left).toBe('over');
    expect(l.picture.width).toBe(447);
    expect(toggleRail('left', computeLayout(at(768, 816)), 768)).toEqual({ overlay: 'left' });
    expect(toggleRail('left', l, 768)).toEqual({ overlay: null });
  });
  it('a rail hidden by hand stays hidden at any width until opened', () => {
    const l = computeLayout(at(1536, 816, { rightHidden: true }));
    expect(l.right).toBe('hidden');
    expect(l.picture.width).toBe(1536 - 321);
    expect(toggleRail('right', l, 1536)).toEqual({ hide: false, overlay: null });
    expect(toggleRail('right', computeLayout(at(600, 816, { rightHidden: true })), 600)).toEqual({ hide: false, overlay: 'right' });
  });
  it('the Navigator folds under 720 tall, the filmstrip under 600; 150 % keeps both rails', () => {
    expect(computeLayout(at(1280, 672)).navigator).toBe('line');
    expect(computeLayout(at(1280, 672)).left).toBe('docked');
    expect(computeLayout(at(1536, 599)).filmstrip).toBe(false);
  });
  it('rails clamp to 280–440; the toolbar overflows by the picture’s width', () => {
    expect(computeLayout(at(1536, 816, { railLeft: 900, railRight: 10 })).leftWidth).toBe(440);
    expect(computeLayout(at(1536, 816, { railRight: 10 })).rightWidth).toBe(280);
    expect(computeLayout(at(1100, 816)).overflow).toEqual({ zoomCropOriginal: true, navCompareTitle: false });
    expect(computeLayout(at(930, 816)).overflow).toEqual({ zoomCropOriginal: true, navCompareTitle: true });
  });
  it('full screen drops the title bar', () => {
    expect(computeLayout(at(1536, 864, { fullScreen: true })).titleBar).toBe(0);
  });
});

describe('the workspace switch', () => {
  it('switches, remembers where it came from, and goes back', () => {
    uiStore.setState(UI_INITIAL);
    setWorkspace('library');
    expect(uiStore.getState()).toMatchObject({ workspace: 'library', previous: 'edit' });
    goBack();
    expect(uiStore.getState()).toMatchObject({ workspace: 'edit', previous: 'library' });
  });
});
