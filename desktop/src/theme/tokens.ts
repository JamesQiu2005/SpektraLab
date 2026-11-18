// tokens.ts — the v2 window's design tokens, in one place.
//
// Every value here is read off the Windows design (`desktop/design/windows/`):
// the HIG's tables (README.md §1.2 geometry, §2 sizes, type and colours) and
// the SVG pages drawn from them. `tokens.test.ts` parses the SVGs and holds
// each colour to a fill or stroke the pages actually use, and each window
// rectangle to the line or rectangle the pages draw there, so a token that
// drifts from the drawing fails.
//
// Sizes are effective pixels (epx), which is a CSS px in the webview (the
// webview's devicePixelRatio is the Windows display scale). The Interface
// Scale (Settings › General: 100 / 115 / 130 %) multiplies the rail-internal
// sizes, not the window's frame (title bar, walls).

export const colours = {
  /** README §2 "Colours, unchanged". */
  ground: '#000000',
  card: '#2D2D2C',
  plot: '#1E1F1E',
  rule: '#3A3B39',
  panel: '#141413',
  wall: '#262625',
  text: '#F9F7F3',
  secondary: '#DAD8D4',
  dim: '#898989',
  faint: '#6D6D6B',
  accent: '#E1A95F',
  selection: '#FFFFFF',
  /** Ink on the white selection and on the accent capsule (the pages' `Export`, `Edit`). */
  onSelection: '#0F0E0E',
  /** README §2 "menus and flyouts are opaque #2B2B2A". */
  flyout: '#2B2B2A',
  /** The danger red (*Engine stopped*, *Offline*), as drawn on PC-E13 and PC-L1. */
  danger: '#E8796B',
  /** A failed develop's InfoBar (PC-E12): the danger red's ground and edge. */
  dangerFill: '#442726',
  dangerEdge: '#5C3A38',
  /** A flyout's and a dialog's edge (PC-X2, PC-X3; PC-O1, Settings). */
  flyoutEdge: '#454543',
  dialogEdge: '#3A3A39',
  /** The selection frame around a chosen card / filmstrip frame. */
  selectionFrame: '#FAF8F4',
} as const;

export const geometry = {
  /** README §1.2. */
  titleBar: 32,
  railHead: 48,
  toolbar: 48,
  rail: 320,
  railMin: 280,
  railMax: 440,
  wall: 1,
  wallGrip: 6,
  filmstrip: 80,
  filmstripFrame: 56,
  margin: 14,
  row: 32,
  sectionHead: 32,
  sliderRow: 44,
  rulerRow: 50,
  switchHeight: 26,
  roundButton: 28,
  hitArea: 40,
  captionButtonWidth: 46,
  stockCard: { width: 92, height: 76 },
  adjustTile: 48,
  adjustTileRow: 72,
  /** The workspace switch, in the left rail under its head (x 14–306, y 84–112). */
  workspaceSwitch: { x: 14, y: 84, width: 292, height: 28 },
  /** The Navigator's well and its zoom row (y 124–294). */
  navigator: { y: 124, height: 170 },
  /** The Latitude meter, pinned at the right rail's top (y 82–204). */
  latitude: { y: 82, height: 122 },
  /** README §1.3. */
  minWindow: { width: 500, height: 540 },
  bothRails: 1180,
  rightRailOnly: 760,
  navigatorFoldHeight: 720,
  filmstripFoldHeight: 600,
  /** The toolbar's overflow, by the picture's width (README §1.3). */
  toolbarFull: 820,
  toolbarMid: 620,
  exportDialog: { width: 800, height: 560 },
  settingsWindow: { width: 860, height: 600 },
  corner: { window: 8, flyout: 8, button: 4 },
} as const;

export const type = {
  /** README §2: Segoe UI Variable at Microsoft's minimums; per-language faces. */
  label: 14,
  caption: 12,
  least: 12,
  menu: 13,
  dialogTitle: 20,
  paneTitle: 28,
  semibold: 600,
  regular: 400,
  fonts: {
    en: "'Segoe UI Variable Text', 'Segoe UI', system-ui, sans-serif",
    'zh-Hans': "'Microsoft YaHei UI', 'Microsoft YaHei', 'Segoe UI Variable Text', 'Segoe UI', 'PingFang SC', 'Noto Sans CJK SC', system-ui, sans-serif",
  },
} as const;

/** The CSS custom properties the stylesheet reads, written once at boot. */
export function cssVariables(): Record<string, string> {
  const px = (n: number) => `${n}px`;
  return {
    '--v2-ground': colours.ground,
    '--v2-card': colours.card,
    '--v2-plot': colours.plot,
    '--v2-rule': colours.rule,
    '--v2-panel': colours.panel,
    '--v2-wall': colours.wall,
    '--v2-text': colours.text,
    '--v2-secondary': colours.secondary,
    '--v2-dim': colours.dim,
    '--v2-faint': colours.faint,
    '--v2-accent': colours.accent,
    '--v2-selection': colours.selection,
    '--v2-on-selection': colours.onSelection,
    '--v2-flyout': colours.flyout,
    '--v2-danger': colours.danger,
    '--v2-selection-frame': colours.selectionFrame,
    '--v2-danger-fill': colours.dangerFill,
    '--v2-danger-edge': colours.dangerEdge,
    '--v2-flyout-edge': colours.flyoutEdge,
    '--v2-dialog-edge': colours.dialogEdge,
    '--v2-title-bar': px(geometry.titleBar),
    '--v2-rail-head': px(geometry.railHead),
    '--v2-toolbar': px(geometry.toolbar),
    '--v2-filmstrip': px(geometry.filmstrip),
    '--v2-filmstrip-frame': px(geometry.filmstripFrame),
    '--v2-margin': px(geometry.margin),
    '--v2-row': px(geometry.row),
    '--v2-section-head': px(geometry.sectionHead),
    '--v2-slider-row': px(geometry.sliderRow),
    '--v2-ruler-row': px(geometry.rulerRow),
    '--v2-switch': px(geometry.switchHeight),
    '--v2-caption-button': px(geometry.captionButtonWidth),
    '--v2-card-w': px(geometry.stockCard.width),
    '--v2-card-h': px(geometry.stockCard.height),
    '--v2-tile': px(geometry.adjustTile),
    '--v2-tile-row': px(geometry.adjustTileRow),
    '--v2-fs-label': px(type.label),
    '--v2-fs-caption': px(type.caption),
    '--v2-fs-menu': px(type.menu),
    '--v2-fs-dialog-title': px(type.dialogTitle),
    '--v2-fs-pane-title': px(type.paneTitle),
    // v1's tokens, re-pointed at the v2 palette so reused components agree.
    '--ground': colours.ground,
    '--card': colours.card,
    '--rule': colours.rule,
    '--text': colours.text,
    '--dim': colours.dim,
    '--secondary-text': colours.secondary,
    '--plot': colours.plot,
    '--accent': colours.accent,
    '--selection': colours.selection,
    '--on-selection': colours.onSelection,
    '--selection-frame': colours.selectionFrame,
  };
}

export function applyTokens(root: HTMLElement = document.documentElement, language: 'en' | 'zh-Hans' = 'en') {
  for (const [k, v] of Object.entries(cssVariables())) root.style.setProperty(k, v);
  root.style.setProperty('--font-ui', type.fonts[language]);
}
