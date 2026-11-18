// fidelity.ts — T2b's per-page claims and NOT_BUILT lists (tests/e2e/design.spec.ts), mirrored in
// PARITY.md ("Phase 1b"). A page with no claims claims its whole drawing. Every NOT_BUILT entry is a
// drawn item (by the name T2b reports) with the reason it is not built as drawn; T2b fails on an entry
// the page does not draw, and on one that is built after all.

type Box = [number, number, number, number];

/**
 * A T2b pass (PRD-W5 R6): the regions of the drawing it claims, the mode the window is put in first, and
 * where those regions stand now. The drawings place Develop's tools in the left rail and Edit's in the
 * right; the one window puts both in the left column, one mode at a time, so Edit's are claimed in the
 * Edit mode, moved left by the right rail's x. Inside a pass every item is still placed against its own
 * label, so a section that moved as a whole is found where it went.
 */
export interface Pass { claims: Box[]; mode?: 'develop' | 'edit'; shift?: { x: number; y: number } }

/** The picture (between the drawn walls, under the toolbar's band, over the filmstrip's): what lies over it. */
const PICTURE: Box = [321, 80, 1215, 736];
/** The left rail under the drawn workspace switch (y 84–112, the mode row now): Develop's tools; the Library's sidebar. */
const LEFT: Box = [0, 116, 320, 816];
/** The right rail (Edit's tools), and the same under its pinned meter for the pages drawn scrolled (PC-E6, PC-E9). */
const RIGHT: Box = [1216, 80, 1536, 816];
const RIGHT_BELOW_METER: Box = [1216, 204, 1536, 816];
const TO_COLUMN = { x: -1216, y: 0 };
/** The Develop column has the Latitude meter at its head (PRD-W5 §2 rule 2) where the drawing has the workspace switch:
 * what the drawing puts under the switch stands 90 epx lower (an unlabelled piece, the Navigator's well, is found there). */
const UNDER_METER = { x: 0, y: 90 };
/** The Library's column has the mode row where the drawing has its title and the switch: everything under it is 40 higher. */
const UNDER_MODE_ROW = { x: 0, y: -40 };

/**
 * Not claimed on a superseded page, because the one window has no such place (each is held by the SHELL
 * rule table in design.spec.ts instead): the toolbar's band (its pieces stand around the shared bar now),
 * the filmstrip's band (gone), the Library's grid (the browser) and Info rail (the viewer's strip), the
 * drawn workspace switch (the mode row), and the snapped pages' and the sheets' columns (folded; full-window).
 */
export const PASSES: Record<string, Pass[]> = {
  // Compare's handle stands at the middle of the shown frame: the one window's picture is 784 wide with the info
  // strip under it, so its middle is (713, 428), not the drawn (752, 408) (the drawn split was already 16 left of the
  // mock frame's middle).
  'PC-E10': [{ claims: [PICTURE], shift: { x: -39, y: 20 } }, { mode: 'develop', claims: [LEFT], shift: UNDER_METER }, { mode: 'edit', claims: [RIGHT], shift: TO_COLUMN }],
  ...Object.fromEntries(['PC-E1', 'PC-E2', 'PC-E3', 'PC-E4', 'PC-E7', 'PC-E8', 'PC-E11', 'PC-E12', 'PC-E13', 'PC-X1', 'PC-X2', 'PC-X3']
    .map((id) => [id, [{ claims: [PICTURE] }, { mode: 'develop', claims: [LEFT], shift: UNDER_METER }, { mode: 'edit', claims: [RIGHT], shift: TO_COLUMN }]])),
  ...Object.fromEntries(['PC-E6', 'PC-E9']
    .map((id) => [id, [{ claims: [id === 'PC-E9' ? [321, 80, 1215, 816] : PICTURE] }, { mode: 'develop', claims: [LEFT], shift: UNDER_METER }, { mode: 'edit', claims: [RIGHT_BELOW_METER], shift: TO_COLUMN }]])),
  // The Export dialog is drawn whole and stands where it is drawn; the window under it is not reachable.
  'PC-O1': [{ claims: [[368, 128, 1168, 688]] }],
  // Snapped: both panes fold, so nothing of the drawn rails stands on screen until F7; PC-N2 has it over the picture.
  'PC-N1': [],
  'PC-N2': [{ claims: [[0, 116, 320, 816]], shift: UNDER_METER }],
  'PC-N3': [{ mode: 'develop', claims: [[0, 116, 320, 672]], shift: UNDER_METER }, { mode: 'edit', claims: [[960, 80, 1280, 672]], shift: { x: -960, y: 0 } }],
  ...Object.fromEntries(['PC-L1', 'PC-L2', 'PC-L3', 'PC-L4', 'PC-L6'].map((id) => [id, [{ claims: [LEFT], shift: UNDER_MODE_ROW }]])),
  'PC-L0': [{ claims: [LEFT], shift: UNDER_MODE_ROW }, { claims: [[321, 80, 1215, 816]] }],
  // Full-window pages now: the sheet is not where the drawing puts it, and its tools are not built (PARITY.md).
  'PC-T1': [],
  'PC-K1': [],
};

export const FIDELITY: Record<string, { claims?: Box[]; notBuilt?: Record<string, string> }> = {
  'PC-E1': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E2': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E3': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
    "control \"Colour\"": "the Enlarger tile's body is v1's Enlarger section (its rows of sliders) inside the v2 tile; the drawing's Colour / Brightness / Pre-flash capsule row is not redrawn",
    "control \"Brightness\" @1338,638": "as Colour: v1's Enlarger body",
    "control \"Pre-flash\"": "as Colour: v1's Enlarger body",
  } },
  'PC-E4': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E6': { notBuilt: {
    "control \"RGB\"": "the Decode tile's body is v1's Decode section inside the v2 tile; the drawing's RGB / Luma / Red capsules and the As Shot pill are not redrawn",
    "control \"Luma\"": "as RGB: v1's Decode body",
    "control \"Red\"": "as RGB: v1's Decode body",
    "control \"As Shot\"": "as RGB: v1's Decode body",
  } },
  'PC-E7': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E8': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E9': { notBuilt: {
    "glyph @544,139": "the crop frame's corner handles are v1's canvas overlay (painted in the picture), not separate graphics",
    "glyph @992,139": "as @544,139: the canvas overlay",
    "glyph @544,758": "as @544,139: the canvas overlay",
    "glyph @992,758": "as @544,139: the canvas overlay",
    "control @1508,390": "the thirds grid's toggle: v1's crop overlay has no grid to switch",
    "glyph @1507,387": "as @1508,390: no grid to switch",
  } },
  'PC-E10': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E11': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E12': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-E13': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-X1': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
    "glyph @1158,167": "··· › Presets ▸: v1 has no presets (PARITY: Presets not built)",
  } },
  'PC-X2': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
    "control \"Film & Paper\"": "Copy Settings is v1's six clipboard groups as check rows (shared/clipboard.ts); the drawing's Develop / Edit cards of switches with per-tile rows (Adjust, Darkroom › Enlarger, Pre-flash, White Balance, Effects, Crop) need the Mac's clipboard groups",
    "control @1002,186": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,226": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,266": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,340": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,380": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,420": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,460": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control @1002,540": "a switch of the drawn Develop / Edit cards: as \"Film & Paper\"",
    "control \"Save as Preset…\"": "v1 has no presets",
  } },
  'PC-X3': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-N2': { notBuilt: {
    "control \"All Photos  ·  214\"": "the filmstrip's chip: the one window has no filmstrip (PRD-W5 §2 rule 8); the browser's count says how many",
  } },
  'PC-N3': { notBuilt: {
    "control \"HSL\"": "R7: the v1 Layer 2 has no HSL set (ADJUST_TILES); a tile that does nothing is not shipped",
    "glyph \"HSL\"": "R7: as the HSL tile",
    "control \"Channels\"": "R7: the v1 Layer 2 has no channel mixer",
    "glyph \"Channels\"": "R7: as the Channels tile",
    "control \"Vibrance\"": "R7: the v1 Layer 2 has no vibrance",
    "glyph \"Vibrance\"": "R7: as the Vibrance tile",
  } },
  'PC-L0': {},
  'PC-L3': { notBuilt: {
    "control \"Archive\"": "built 76 tall: the drawing's card is mid-read (Reading · 4,210 of 9,660); the mock reads at once",
    "glyph @107,442": "Capture One's project and group glyphs: the mock's catalog gives its collections no Capture One kind (spklib 0.4 reports albums and folders only)",
    "glyph @43,502": "as @107,442",
    "glyph @27,558": "as @107,442",
    "control \"Search\"": "FILTERS › Search is the plain text field, not the drawn 26 epx capsule with its glyph",
    "glyph @30,737": "as Search",
    "glyph @60,193": "the Reading · 4,210 of 9,660 line's spinner: the mock helper reads a catalog at once, so there is no reading line",
    "glyph @42,322": "Recent Imports' dated children: the mock catalog has no import sessions under Recent Imports",
    "glyph @22,668": "a third folder, offline (Travel SSD): the mock Capture One catalog has two folders",
  } },
  'PC-L4': { notBuilt: {
    "glyph @111,250": "a session folder's glyph: the mock session's Capture / Selects / Output / Trash rows have the album glyph",
    "glyph @30,399": "FILTERS › Search's glyph: the plain text field",
  } },
  // PC-T1, PC-K1: full-window pages since PRD-W5 (nothing claimed, see PASSES); their sheet tools (add a roll,
  // zoom, fit, orientation, export the sheet) are still not built — the library has no sheet layout yet (PARITY.md).
  'PC-G1': { notBuilt: {
    "glyph @740,16": "Settings is a dialog inside the window in phase 1 (an owned top-level window waits for phase 2): Close only, no Minimise",
    "glyph @812,145": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @812,189": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @812,233": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @809,332": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @809,364": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @809,428": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @809,460": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @809,492": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
    "glyph @809,524": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end, not at the row's right edge",
  } },
  'PC-G2': { notBuilt: {
    "glyph @740,16": "Settings is a dialog inside the window in phase 1: Close only, no Minimise",
    "glyph @809,224": "Settings' rows hold v1's pill menus, whose ⌄ sits at the pill's end",
  } },
  'PC-G3': { notBuilt: {
    "glyph @740,16": "Settings is a dialog inside the window in phase 1: Close only, no Minimise",
  } },
};
