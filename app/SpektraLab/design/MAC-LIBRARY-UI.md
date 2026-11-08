# The Mac library — layout and metrics (2026-10-23)

SpektraLab 2's Library page (`Sources/Mac/LibraryUI/`). §1–§7 are the page as it was laid out on 2026-10-23;
§8 is the one window it became on 2026-10-26/27, which moved the sidebar's width and the toolbar (said in place).

**Starting point.** v2's own language — black ground, `Theme.panel` sidebar, the white selection
capsule, `Theme.text`/`dim`, the accent only for actions and state — set at macOS's own sizes.
Nothing is taken from v1 (`filmify`, `modern_UI`): not its rails, its rows, its tokens or its
density. The density comes from two references that are not SpektraLab: Xcode 27's navigator
(how an Apple app holds a lot) and Capture One's Library tool (what a photo catalog needs).

## 1. One number first: a scene point is 0.77 of a Mac point

The app is a Mac Catalyst app at the scaled idiom: every point of the Catalyst scene is drawn at 77 % on
the Mac. The figures below are **Mac points**, the units the HIG gives; the code writes them as
`MacMetric.pt(x)` = x / 0.77 (1.0 under *Optimize for Mac*, should the idiom ever change). A figure
written in scene points without that conversion comes out at 0.77 of its size: a 46-pt row is 35 Mac
points, a 34-pt title 26. Settings › Appearance's interface scale is applied on top of both
(`InterfaceScale`, `PAGES.md` §1).

## 2. Zones

```
┌──────────── 260 ────────────┬───────────────────── the rest ─────────────────────┐
│ [▤] [⏚] [ⓘ]   navigator tabs │ [◧] [Date ▾][↓]      9,661 images     [–◯–] [🔍   ] │  32
│ Catalog: Capture One… ▾  [+]│                                                      │  header
│ ▾ CATALOG COLLECTIONS       │  ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢                                │
│   All Images          9,661 │  ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢   one grid, no day breaks      │
│   ▾ Recent Imports          │  ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢                                │
│     2026年10月19日 17:45   1 │  …                                                   │
│ ▸ USER COLLECTIONS          │                                                      │
│ ▸ FOLDERS                   │                                                      │
│─────────────────────────────│                                                      │
│ [+] [ Filter            ]   │                                                      │  28
└─────────────────────────────┴──────────────────────────────────────────────────────┘
```

- **Sidebar** 260 pt (Xcode's navigator default) as drawn; since 2026-10-26 it is the window's one left
  column, as wide as the develop column and dragged at either page's wall (§8, `MacMetric.columnFigure`,
  `sidebarRange`). ⌘T or ⌃⌘S hides it. Ground `Theme.panel`; one 1-pt `Theme.wall` line between it and
  the grid.
- **Grid**: everything right of the wall, black (`Theme.background`), as v2's pages are.
- **Edit page**: the develop page's column — *Develop | Edit*, the panels, the action row —
  stands at the **left** on the Mac, the picture at the right (§6). Its contents are unchanged.

## 3. The sidebar: Xcode's frame, Capture One's contents

| Xcode 27 navigator | Capture One | SpektraLab Mac |
|---|---|---|
| a row of navigator icons at the top | tool tabs at the top of the left panel | **three tabs**: Library (`folder`), Filters (`line.3.horizontal.decrease.circle`), Info (`info.circle`) |
| an outline tree | Library tool: catalog picker, Catalog Collections, User Collections, Folders | **Library**: the source picker, then an outline of collections, each with its count |
| — | Filters tool: search, Rating, Colour Tag, Date, Keywords, Camera/Lens, each with counts | **Filters**: Rating (none, ★…★★★★★), Colour Label (none + Capture One's seven), Date (year ▸ month), Camera, Lens, File Type, Keywords (when any), and "Opened in Develop"; each value a checkmark row with its count, each facet counted with the other ticks applied (the store's `MacFacets`) |
| — | Metadata tool | **Info**: the selected frame's metadata, label/value rows |
| "+" and a Filter field at the bottom | — | **"+"** (Open Catalog or Folder…, Import…, Read Again, Remove from List, Sources, Settings) and a **Filter** field that narrows the rows of the tab shown, as Xcode's does |

Why three tabs and no more: these are the three kinds of content that exist today (where the
pictures are; which of them to show; what one of them is). Dates are a facet, not a place: Capture
One files them under Filters, and so does this. Films are not yet a facet of the store; "Opened in
Develop" is the one SpektraLab facet it has.

**The Library outline, by source**

- *A Capture One catalog* (read one way through the helper, `capture_one.link`): **Catalog
  Collections** — All Images, Recent Imports ▸ each import by its time, Recent Captures ▸, Trash;
  **User Collections** — projects, groups, albums; **Folders** — the catalog's folders. Roles come
  from the helper's `kind`, never from names; Capture One's own names (in its UI language) are
  shown as they are.
- *SpektraLab's library*: **Library** — All Images, Recent Imports ▸ by minute; **User Collections**
  — Favourites; **Folders** — In SpektraLab (copied in), each linked folder; and a Light Table row.
- The views read `MacLibraryData` (`MAC-LIBRARY-DATA.md`: sources, `tree`, `images`/`total`, `facets`,
  `query`, `apply`, `openInDevelop`); the source picker lists every source it has (catalogs,
  sessions, Capture One's, folders).

## 4. Metrics (Mac points; the HIG figure each follows)

| element | value | follows |
|---|---|---|
| outline row | **24** high, text 13 regular, counts 13 monospaced digits in `dim` | NSTableView sidebar *small* row (24); 13 pt is macOS body |
| outline indent | 14 per level, disclosure chevron 10 pt in a 14-pt box | Finder/Xcode outline |
| section header | 24 high, 11 semibold, `dim`, folds with its chevron | macOS sidebar section header (11 pt) |
| selected row | v2's white capsule (`Theme.selection`, radius 5) with `onSelection` text, 6 pt inset from each side | v2's own selection; macOS's inset rounded highlight |
| row icon | SF Symbol 13 pt in an 18-pt box, 6 pt before the text | sidebar icon size *small* |
| navigator tab bar | 30 high, icons 14 pt, chosen one in `text` on `Theme.card`, others `dim` | Xcode's navigator bar |
| bottom bar | 30 high: "+" 14 pt, Filter field 22 high, 11-pt corner, 12-pt text | Xcode's filter bar; macOS small text field (22) |
| source picker | 24 high pop-up, 12 pt | macOS small pop-up button |
| grid header | 32 high: sort pop-up, direction, count (13 semibold), size slider 100 wide, search field 160 wide | toolbar-height control row |
| grid cell | square, default 112, 64–256 by slider, ⌘+ / ⌘−, ×1.25 a step; 2-pt gutter; picture fitted (not cropped) inside a 6-pt inset | Capture One's browser; Photos' grid gap |
| selected cell | `Theme.card` rounded rect (radius 4) behind the cell, 2-pt `selectionFrame` line around it | v2: "a chosen tile wears the white frame" |
| cell badges | under the picture, 11 pt: rating stars, colour-label dot, film dot; only when set | Capture One's thumbnail labels |
| Info rows | 20 high, label 11 `dim` right-aligned in an 84-pt column, value 12 `text` | Finder's Get Info, Xcode's inspectors |

Type is never below 11 pt: "shrink the gaps, never the type" (the owner, 2026-09-28).

## 5. Keyboard and mouse

The keys are Capture One's shipped defaults, with the Mac's own conflicts resolved, in one table:
`MacShortcut` (`Sources/Mac/MacShortcuts.swift`). A page registers an action for a key with
`MacShortcutButton`; the table owns the key, so two pages never bind one key twice, and plain and
⇧-only keys reach the page by the same path as ⌘ keys. ⌘A, ⌘C and ⌘V go through the Edit menu's own
items, and a text field being edited keeps them. A page's own keys that are not Capture One's — the
arrows, Return, Delete, Escape — are `HiddenKeyEquivalent`s on that page (`MacLibraryPage`), standing down
while a field types. For the library:

| input | does |
|---|---|
| click | selects the frame (only it) |
| ⌘-click / ⇧-click | adds or removes one / the run from the anchor |
| double-click, Return | opens the frame in 冲洗 (`Route.develop`) |
| ← → ↑ ↓ | move the selection one cell / one row; with ⇧ they extend it |
| ⌘← ⌘→, ⌘Home ⌘End | previous / next, first / last picture |
| ⌘A; ⇧⌘A or Escape; ⌘I | select all; select none; invert the selection |
| Delete | remove the chosen frames (asks first) |
| ⌘+ ⌘− | larger / smaller thumbnails |
| ⌘T or ⌃⌘S; ⌘B or ⌥⌘B; G; ⌥⌘V | the sidebar; the browser; the grid; the viewer beside the grid |
| ⌘1 ⌘2 ⌘3 (or with ⌥) | the Library, Filters and Info tabs |
| ⌘C, ⇧⌘C, ⌘V | copy settings, copy choosing the groups, paste settings |
| ⇧⌘D, ⇧⌘I | export, import |
| − * + | red, yellow, green label |
| secondary click | the frame's menu: Open in Develop, Info, Export, Copy Settings, Favourite, Develop Preview, Put on Light Table, Make Half-Frame Pair |

A Capture One picture that is not a frame yet becomes one when it is first opened (read in place,
as a linked folder's frame is): browsing a 9,661-image catalog develops nothing.

## 6. The edit column on the left

The owner: "moving the gallery edit column completely to the left side (we make zero alterations to
that part at this stage)". The library itself has no per-image editing column; the one column of
editing tools the library leads to is the develop page's column. It stands at the left, as Capture
One's tools do, so the library's sidebar and the develop page's tools occupy the same place
(`DevelopRegions`); nothing inside it moved.

## 7. Not taken, and why

- **From v1**: any layout, row height or density. v1's dense rails were the problem last time.
- **From Capture One**: its toolbar of large labelled buttons (the page has a header row instead);
  its viewer column between tools and browser (SpektraLab opens the edit page instead); the toggle
  pills of the filter counts (a checkmark row is the Mac's own control); Keywords (no keyword
  exists in SpektraLab or in the catalog mirror yet); its own preview cache (thumbnails are the
  cameras' embedded previews, never Capture One's `Cache/`, per the helper's spec).
- **From Xcode**: Liquid Glass and the floating capsule bars; the run/stop controls.
- **From photo-library apps**: a large title, day headers, a Select mode with its own bars (on a
  Mac selection is always on: click, ⌘, ⇧).

## 8. One window (2026-10-26)

The owner, reading Capture One: the picture is the centre; 图库 · 冲洗 · 编辑 are **one left column**
with the mode at its top; the right browser is **shared** between the library and Develop/Edit, and its
split is dragged to choose how wide the library preview is; 文件 · 胶片与相纸 · 格式 · 编辑 are the
second layer of tabs under the mode; the histogram stays at the top of the column.

- **The mode row** (`MacModeSwitch`) leads the left column in all three modes — the develop column's
  header and the top of this page's sidebar. 冲洗 and 编辑 open the chosen picture on that surface.
- **The left column is one width**: this page's sidebar starts at the develop column's 393 scene points
  (`WindowLayout.columnWidth`), and either is dragged and kept (`PaneDividers.columnWidth`, one number).
- **The shared bar** (`MacSharedControls`) is §2's control group — the column's toggle, the viewer | grid
  split (⌥⌘V), the loupe, the sort and its direction — and it stands at the leading edge of the browser
  header here and of the develop page's picture bar there, so the two read as one bar across the window.
- **The split is one state**: on, the picture has a browser beside it; off, the picture has the window.
  It is on by default — the picture is the centre.
- **裁剪 is persistent**: the shared bar carries it in every mode. In 图库 it crops the chosen picture
  where it is browsed — the pre-film crop (`FrameEdit.geometry`), the one the film and the meter see;
  冲洗 and 编辑 keep their own (the picture before the film, the finished picture). The develop
  column's header no longer holds a Crop, so the entry survives a folded column.
- The develop page's rows are this page's rows: the same query, the same selection, the same browser
  (`MacDevelopBrowser`). A click there opens that picture on the canvas; the filmstrip, `‹ Library` and
  "1 of 1" are gone, and Export takes the browser's chosen frames.

**2026-10-27, the window shell.** The owner: "I don't want another page transition to happen when
switching between library and develop/edit." The window is one view now (`MainWindowLayout`): the bar,
the floating browser and between them the mode's content, all mounted once; the mode is the router's
path *read* (a `.develop` on it is 冲洗/编辑), so a mode press swaps only the column and the canvas, in the
frame it happens in, and the browser keeps its scroll and width. 图库 · 冲洗 · 编辑 stands in the bar —
centred from 1200 Mac points, after the shared controls below — and the columns start with the tree and
the histogram. The browser's rows are as tall as their tallest picture, the dot · ★ · tag line directly
under each; one info strip under the canvas in every mode carries the exposure, the develop's status, the
name and the rating ("N photos selected" for several). The Light Table, Import, Export and Settings stay
full-window pages.

