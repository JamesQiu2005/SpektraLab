// layout.ts — the window rule as arithmetic (README §1.3, PC-N1–N3), with no
// React in it, so the folding is tested on numbers.
//
//   ≥ 1180 wide   both rails
//   760–1180      the right rail and the picture; the left rail folds by itself
//                 and comes back over the picture (F7)
//   500–760       the picture alone; both rails come over it, one at a time
//   any width     a rail folded by hand stays folded until opened
//   < 720 tall    the Navigator folds to one line
//   < 600 tall    the filmstrip folds as well
//
// The toolbar's overflow follows the picture's own width: ≥ 820 everything;
// 620–820 the zoom, Crop and Original go into ···; under 620 ‹ ›, Compare and
// Paste Settings go there as well.

import { geometry as G } from '../theme/tokens';

export type RailSide = 'left' | 'right';

export interface LayoutInput {
  width: number;
  height: number;
  /** Folded by hand (View › Develop Rail / Edit Rail, F7/F8, Ctrl+B). */
  leftHidden: boolean;
  rightHidden: boolean;
  filmstripHidden: boolean;
  navigatorHidden: boolean;
  /** The rail brought over the picture while folded by width (one at a time). */
  overlay: RailSide | null;
  railLeft: number;
  railRight: number;
  fullScreen: boolean;
  /** The picture alone: the rails and filmstrip are hidden by Ctrl+B / Ctrl+Shift+F. */
}

export type RailMode = 'docked' | 'folded' | 'over' | 'hidden';

export interface Layout {
  titleBar: number;
  left: RailMode;
  right: RailMode;
  leftWidth: number;
  rightWidth: number;
  /** The picture column: from the left wall to the right wall. */
  picture: { x: number; width: number };
  filmstrip: boolean;
  navigator: 'well' | 'line' | 'hidden';
  /** Which toolbar groups are inside ··· . */
  overflow: { zoomCropOriginal: boolean; navCompareTitle: boolean };
  /** The width rule decided the fold (not the hand). */
  leftFoldedByWidth: boolean;
  rightFoldedByWidth: boolean;
}

export const clampRail = (w: number) => (Number.isFinite(w) ? Math.max(G.railMin, Math.min(G.railMax, Math.round(w))) : G.rail);

export function computeLayout(i: LayoutInput): Layout {
  const titleBar = i.fullScreen ? 0 : G.titleBar;
  const leftByWidth = i.width < G.bothRails;
  const rightByWidth = i.width < G.rightRailOnly;
  const mode = (hand: boolean, byWidth: boolean, side: RailSide): RailMode => {
    if (i.overlay === side && (hand || byWidth)) return 'over';
    if (hand) return 'hidden';
    if (byWidth) return 'folded';
    return 'docked';
  };
  const left = mode(i.leftHidden, leftByWidth, 'left');
  const right = mode(i.rightHidden, rightByWidth, 'right');
  const leftWidth = clampRail(i.railLeft);
  const rightWidth = clampRail(i.railRight);
  const x = left === 'docked' ? leftWidth + G.wall : 0;
  const width = Math.max(0, i.width - x - (right === 'docked' ? rightWidth + G.wall : 0));
  const filmstrip = !i.filmstripHidden && i.height >= G.filmstripFoldHeight;
  const navigator = i.navigatorHidden ? 'hidden' : i.height < G.navigatorFoldHeight ? 'line' : 'well';
  return {
    titleBar, left, right, leftWidth, rightWidth,
    picture: { x, width },
    filmstrip,
    navigator,
    overflow: { zoomCropOriginal: width < G.toolbarFull, navCompareTitle: width < G.toolbarMid },
    leftFoldedByWidth: leftByWidth && !i.leftHidden,
    rightFoldedByWidth: rightByWidth && !i.rightHidden,
  };
}

/** A rail's button (or F7/F8): shown ⇄ hidden when docked, over ⇄ away when folded by width. */
export function toggleRail(side: RailSide, l: Layout, width: number): { hide?: boolean; overlay?: RailSide | null } {
  const m = side === 'left' ? l.left : l.right;
  if (m === 'docked') return { hide: true };
  if (m === 'over') return { overlay: null };
  // Folded by width: bring it over the picture (one at a time).
  if (m === 'folded') return { overlay: side };
  // Hidden by hand: open it; where the width folds it, it comes over the picture.
  const byWidth = side === 'left' ? width < G.bothRails : width < G.rightRailOnly;
  return { hide: false, overlay: byWidth ? side : null };
}
