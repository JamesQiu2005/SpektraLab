// layout.ts — the one window's rule as arithmetic (PRD-W5 §2, R4), with no
// React in it, so the folding is tested on numbers.
//
// The window is the Mac's (`MainWindowLayout`): the LEFT COLUMN (the mode row
// and the mode's tools), the picture, and the BROWSER at the right — the
// library's rows in every mode. The column is 320 epx (280–440, dragged and
// kept); the browser 430 epx (240–900, dragged and kept, the Mac's default).
//
//   the picture keeps at least MIN_PICTURE epx; a window too narrow for that
//   folds the BROWSER first (it shrinks to 240 before it folds), then the
//   COLUMN; a folded pane comes back over the picture (F7 / F8), one at a
//   time, and Esc or a press on the picture puts it away
//   any width     a pane hidden by hand (the column toggle, the split) stays
//                 hidden until opened
//   full grid     the browser takes everything right of the column (G)
//   < 720 tall    the Navigator folds to one line
//
// The picture bar's overflow follows the picture's own width: ≥ 640
// everything; 520–640 the zoom and Original go into ···; under 520 Compare and
// Paste Settings go there as well.

import { geometry as G } from '../theme/tokens';

export type RailSide = 'left' | 'right';

/** The browser's width (Mac `MacMetric.browserRange`, `browserWidth`). */
export const BROWSER = { width: 430, min: 240, max: 900 } as const;
/** The least the picture keeps before a pane folds. */
export const MIN_PICTURE = 480;
/** The picture bar's overflow thresholds, by the picture's width. */
export const BAR = { full: 640, mid: 520 } as const;

export interface LayoutInput {
  width: number;
  height: number;
  /** The left column, hidden by hand (the column toggle, F7, Ctrl+B). */
  leftHidden: boolean;
  /** The split off: the picture has the window (the split toggle, F8). */
  rightHidden: boolean;
  /** The browser takes the window right of the column. */
  fullGrid: boolean;
  navigatorHidden: boolean;
  /** The pane brought over the picture while folded by width (one at a time). */
  overlay: RailSide | null;
  railLeft: number;
  browserWidth: number;
  fullScreen: boolean;
}

export type RailMode = 'docked' | 'folded' | 'over' | 'hidden';

export interface Layout {
  titleBar: number;
  /** The left column. */
  left: RailMode;
  /** The browser. */
  right: RailMode;
  leftWidth: number;
  /** The browser's width as shown (≤ the kept one where the window is narrow). */
  rightWidth: number;
  /** The picture: from the column's wall to the browser's. Width 0 under the full grid. */
  picture: { x: number; width: number };
  fullGrid: boolean;
  navigator: 'well' | 'line' | 'hidden';
  /** Which picture-bar groups are inside ··· . */
  overflow: { zoomCropOriginal: boolean; navCompareTitle: boolean };
  /** The width rule decided the fold (not the hand). */
  leftFoldedByWidth: boolean;
  rightFoldedByWidth: boolean;
}

export const clampRail = (w: number) => (Number.isFinite(w) ? Math.max(G.railMin, Math.min(G.railMax, Math.round(w))) : G.rail);
export const clampBrowser = (w: number) => (Number.isFinite(w) ? Math.max(BROWSER.min, Math.min(BROWSER.max, Math.round(w))) : BROWSER.width);

/** Where the width folds the panes (neither hidden by hand): the browser first, then the column. */
export function foldsByWidth(width: number, railLeft: number): { left: boolean; right: boolean } {
  const column = clampRail(railLeft) + G.wall;
  if (width - column - (BROWSER.min + G.wall) >= MIN_PICTURE) return { left: false, right: false };
  if (width - column >= MIN_PICTURE) return { left: false, right: true };
  return { left: true, right: true };
}

export function computeLayout(i: LayoutInput): Layout {
  const titleBar = i.fullScreen ? 0 : G.titleBar;
  const leftWidth = clampRail(i.railLeft);
  const kept = clampBrowser(i.browserWidth);
  // The width rule asks about the panes that are not hidden by hand: a hidden column leaves its room to the browser.
  const byWidth = foldsByWidth(i.leftHidden ? -Infinity : i.width, leftWidth);
  const leftByWidth = !i.leftHidden && byWidth.left;
  const rightByWidth = !i.fullGrid && !i.rightHidden && (i.leftHidden ? i.width - (BROWSER.min + G.wall) < MIN_PICTURE : byWidth.right);
  const mode = (hand: boolean, folded: boolean, side: RailSide): RailMode => {
    if (i.overlay === side && (hand || folded)) return 'over';
    if (hand) return 'hidden';
    if (folded) return 'folded';
    return 'docked';
  };
  const left = mode(i.leftHidden, leftByWidth, 'left');
  const right = i.fullGrid ? 'docked' : mode(i.rightHidden, rightByWidth, 'right');
  const x = left === 'docked' ? leftWidth + G.wall : 0;
  let rightWidth = kept;
  if (i.fullGrid) rightWidth = Math.max(0, i.width - x);
  else if (right === 'docked') rightWidth = Math.max(BROWSER.min, Math.min(kept, i.width - x - MIN_PICTURE - G.wall));
  else if (right === 'over') rightWidth = Math.min(kept, Math.max(BROWSER.min, i.width - 48));
  const width = i.fullGrid ? 0 : Math.max(0, i.width - x - (right === 'docked' ? rightWidth + G.wall : 0));
  const navigator = i.navigatorHidden ? 'hidden' : i.height < G.navigatorFoldHeight ? 'line' : 'well';
  return {
    titleBar, left, right, leftWidth, rightWidth,
    picture: { x, width },
    fullGrid: i.fullGrid,
    navigator,
    overflow: { zoomCropOriginal: width < BAR.full, navCompareTitle: width < BAR.mid },
    leftFoldedByWidth: leftByWidth,
    rightFoldedByWidth: rightByWidth,
  };
}

/** A pane's toggle (or F7/F8): shown ⇄ hidden when docked, over ⇄ away when folded by width. */
export function toggleRail(side: RailSide, l: Layout, width: number): { hide?: boolean; overlay?: RailSide | null } {
  const m = side === 'left' ? l.left : l.right;
  if (m === 'docked') return { hide: true };
  if (m === 'over') return { overlay: null };
  // Folded by width: bring it over the picture (one at a time).
  if (m === 'folded') return { overlay: side };
  // Hidden by hand: open it; where the width folds it, it comes over the picture.
  const f = foldsByWidth(width, l.leftWidth);
  const byWidth = side === 'left' ? f.left : f.right;
  return { hide: false, overlay: byWidth ? side : null };
}
