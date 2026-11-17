# The SpektraLab HIG for Windows (2026-10-23)

This is the house guideline for SpektraLab 2.0 on Windows, and the drawings made from it. It is written for the
friends who build the Windows app. The pages are listed in [INDEX.md](INDEX.md).

Read in this order:
1. This file.
2. [`../mac/README.md`](../mac/README.md), the Mac HIG this file adapts.
3. `../ipad/README.md` §1–3.
4. The Windows app as it is: `windows_UI/README.md` on the desktop repository's `Windows_Linux` branch.

> **The rule above every other** (the owner's rule for the Mac, 2026-10-23, carried to Windows).
> - **The iPad's editor is what Windows gets.** Where the iPad and the desktop behave differently in Develop and Edit,
>   **the iPad's behaviour wins**.
> - **The Mac HIG's layout decisions are the starting point:**
>   - two rails, with Develop | Edit both on screen;
>   - Library | Edit as a workspace switch;
>   - the Navigator at the top left, and Latitude pinned at the top right;
>   - no glass on the panels;
>   - the colours, the accent rule and the white selection;
>   - the words, ranges, rests and detents.
> - **The app is built on the Windows app's own frame:** `windows_UI/` (Qt Quick and QML over C++), its synchronous
>   `spk_desktop_host` and its **one serial engine worker**. The Mac's `RenderScheduler`, the phone's scheduler and the
>   mobile engine stay out.
> - So every piece names three things:
>   - **the iPad page and component it looks and behaves like**;
>   - **the Mac HIG section** that placed it;
>   - **the `windows_UI` file it is built on**, or *new* (a new QML type or C++ class in that app's idiom);
>   - and **whose behaviour wins**. **§3.7 is that map.**
> - **A feature the Windows engine refuses is never drawn as a working control.** §3.8 says how each one appears
>   until it is ported.

**How to read the tags.** Every decision carries its source:
- **[iPad]**: the iPad app as built, and `design/ipad/`.
- **[Mac HIG]**: `design/mac/README.md` (cited by section).
- **[Win-Qt]**: the current Windows app, `windows_UI/` at `origin/Windows_Linux` b68ed6c7 (cited by file), and the
  engine at the same commit.
- **[Microsoft]**: Microsoft's Windows design guidance, read 2026-10-23. §12 gives each page and its date.
- **[proposal]**: mine, open to the owner.

Words in this file explain. Words on a page follow V5's rule: names, values, states, actions.

---

## 0. The short version

1. **The window is the Mac HIG's, under a Windows title bar.**
   - Rails: the left rail, the picture and the right rail. The filmstrip sits under the picture. Each rail is 320 epx
     **[Mac HIG §1]**.
   - Title bar: a 32 epx title bar runs across the window. It holds the app's icon, the menu bar
     (File Edit View Frame Go Help), the window's title, and the caption buttons at the trailing edge
     **[Microsoft: title bar]**.
   - Nothing is kept clear at the leading edge.
2. **Units are effective pixels (epx).** The primary drawing is **1920 × 1080 at 125 %**: 1536 × 864 epx, with the
   window maximised above the taskbar at **1536 × 816**. It is the commonest Windows screen (§1.2).
3. **Develop is the left rail and Edit is the right rail, both always on screen.** The controls are the iPad's, in the
   Mac HIG's sections **[iPad] [Mac HIG §3]**.
4. **The Windows worker's states, in V5's words.**
   - One serial worker. An edit settles for 180 ms before it renders. Edits made during a render are folded into the
     newest one.
   - The last picture stays until the new one lands. A failed render keeps the last print and offers Try Again.
   - Every render is the whole frame **[Win-Qt]** (§7).
5. **What the engine refuses is not on screen.** Today that is Film Edge, Date Back, Scene Placement, Digital
   Intermediate and the Half-Frame Pair. The app reads `capabilities.backend.unsupported_features`, so each one
   appears in its place when it is ported, with no redesign (§3.8).
6. **Windows idioms where Windows has them:**
   - Ctrl, Alt and Shift for the keys, Alt access keys, F11 for full screen;
   - Snap layouts work, and the window can be as narrow as 500 epx;
   - Show in File Explorer;
   - Segoe UI Variable at Microsoft's minimum sizes, and Segoe Fluent Icons by name;
   - a ContentDialog for Export;
   - contrast themes and Narrator.
7. **No Mica, no Acrylic.** The owner's no-glass rule stands. Menus and flyouts are opaque (§2).

---

## 1. The window rule

### 1.1 One window, three columns

| | decision | why | source |
|---|---|---|---|
| layout | left rail · picture · right rail; the filmstrip under the picture only; the toolbar over the picture only | the Mac HIG's window, which is the owner's | [Mac HIG §1.1] |
| title bar | **one 32 epx title bar across the window**, drawn by the app: the app's icon (16 epx), the menu bar, the window's title in caption type, centred in the empty room, and the caption buttons at the right | Microsoft: "The standard title bar has a height of 32px"; "you can place text, a search box, or custom menus in the title bar area" | [Microsoft: title bar, title bar customization] |
| rails under it | each rail runs from the title bar to the bottom; its 48 epx head holds its title (*Develop*, *Edit*) | the Mac's 52 pt head, at 48 (a multiple of 4: Microsoft asks for "multiples of 4 epx") | [Mac HIG §1.1] [Microsoft: screen sizes] |
| the leading edge | **nothing is reserved**. The Mac kept 80 pt clear for the window controls; on Windows they are in the title bar at the right, so the left rail's head and a folded rail's toolbar start at the edge | the system draws Close "in the upper-right for left-to-right languages"; all four of our languages are left to right | [Microsoft: title bar customization] |
| rail width | **320 epx** each by default; drag the wall between 280 and 440; double-click the wall for 320; remembered | the Mac's (§2 shows an epx is about a Mac point here) | [Mac HIG §1.1] |
| walls | 1 epx `#262625`; a 6 epx drag strip; an accent line and the resize cursor on hover | | [Mac HIG §1.1] |
| filmstrip | **80 epx**, frames 56 tall; Ctrl+Shift+F hides it | 8 epx less than the Mac's 88 pt: the Windows window is 129 epx shorter | [proposal] |
| picture | fitted whole on black; an upright frame is never cropped to fill | | [iPad] |
| one window | one editor window, as Win-Qt has. Settings is its own window. Export is a ContentDialog (§6.6) | Win-Qt holds one `PreviewHost` on one worker | [Win-Qt: PreviewController.hpp] |
| corners | square while maximised or snapped; 8 epx when restored | "Window corners are not rounded when windows are snapped or maximized"; "app windows … 8px" | [Microsoft: geometry] |
| full screen | **F11**: the title bar and the taskbar go; the toolbar stays; Esc or F11 leaves | the Windows key for it (File Explorer's F11) | [Microsoft: keyboard shortcuts] |
| the picture alone | Ctrl+B hides both rails; Ctrl+Shift+F hides the filmstrip | the Mac's ⌘B and ⇧⌘F | [Mac HIG §1.1] |

**Building the title bar in Qt Quick.**
- The window is frameless (`Qt::FramelessWindowHint` with the system's resize border kept).
- A small C++ class, **new `WindowChrome`** (a `QAbstractNativeEventFilter`), answers `WM_NCHITTEST`:
  - `HTCAPTION` over the empty room;
  - `HTMAXBUTTON` over the maximise button, so Snap layouts open on hover;
  - the resize edges.
- The menu bar and caption buttons are QML (**new `TitleBar.qml`**).
- Why: Microsoft says, for Win32 apps, "make sure you are responding appropriately to WM_NCHITTEST (with a return value
  of HTMAXBUTTON for the maximize/restore button)", or Snap layouts will not show **[Microsoft: snap layouts]**.
- All empty space in the title bar drags the window **[Microsoft: title bar]**.
- The caption buttons are 46 × 32 epx each. That is Windows 11's own size, measured. Microsoft's pages give no width
  **[proposal]**.

### 1.2 Geometry: 1920 × 1080 at 125 %, maximised (epx, window coordinates)

**The drawing size.**

| | |
|---|---|
| the screen | **1920 × 1080 at 125 %** = 1536 × 864 epx |
| the window | maximised above the 48 epx taskbar: **1536 × 816** |
| why 1080p | StatCounter's desktop screen sizes for September 2026 (read 2026-10-23) put 1920 × 1080 first (28.07 %). 1536 × 864, which is that screen at 125 %, is second (10 %). Windows reports sizes in epx, so the second line is the same panel. |
| why 125 % | It is the size people see on a 15.6-inch 1080p laptop, the commonest Windows laptop. |
| the tighter case | 1080p at **150 %** (1280 × 720 epx; 4.71 %, fourth) is drawn as PC-N3. It is the 13- and 14-inch 1080p laptop. |
| the rule of thumb | If both rails fit at 1280 wide, they fit everywhere wider. |

| | x | y |
|---|---|---|
| title bar (icon, menus, title, caption buttons) | 0–1536 | 0–32 |
| left rail | 0–320 | 32–816 |
| its head (title "Develop") | | 32–80 |
| Library \| Edit | 14–306 | 84–112 |
| Navigator (well, then Fit · 100 % · 200 %) | 14–306 | 124–294 |
| left sections (scroll under the fixed head, switch and Navigator) | 0–320 | 298–816 |
| wall | 320 | |
| toolbar | 321–1215 | 32–80 |
| picture room | 321–1215 (894 wide) | 80–736 (656 tall) |
| filmstrip | 321–1215 | 736–816 |
| wall | 1215 | |
| right rail | 1216–1536 | 32–816 |
| its head (title "Edit") | | 32–80 |
| Latitude meter (pinned) | 1230–1522 | 82–204 |
| right sections (scroll under the meter) | 1216–1536 | 204–816 |
| caption buttons | 1398–1536 | 0–32 |

The picture room is 894 × 656, against the Mac's 870 × 805. The screen is wider and shorter, and the title bar and
taskbar take 80 epx. Nothing in the rails is cut for it. The rails scroll, as they do on the Mac.

### 1.3 When the window is narrow, or short

**Minimum window: 500 × 540 epx** **[proposal]**. Win-Qt's is 1100 × 740 (`Main.qml`), which refuses Snap's halves.
Microsoft: "Your app should support a minimum width of at most 500 effective pixels (epx)" **[Microsoft: snap layouts]**.

| window width | what shows | how |
|---|---|---|
| ≥ 1180 | both rails | 1180 = 2 × 320 + a 540 epx picture (the Mac's threshold). 1536 at 125 % and 1280 at 150 % both clear it |
| 760–1180 | the right rail and the picture; **the left rail folds by itself** | its button (and F7) brings it back **over the picture** with a shadow. Esc, a click on the picture or the button again puts it away. Widen the window and it returns, unless you folded it yourself. A half of the 125 % screen (768) lands here: the right rail keeps a 447 epx picture beside it |
| 500–760 | **the picture alone**; both rails fold by themselves and come over it, one at a time | a third of 1536 (512) or a half at 150 % (640). F7 and F8 bring them; Esc puts them away |
| any width | either rail, by hand | F7 (left), F8 (right), Ctrl+B (both). A rail folded by hand stays folded until you open it |

**Height:**
- **under 720 epx tall:** the Navigator folds to one line, *Navigator · Fit · 100 % · 200 %*. Its well comes back with
  View › Navigator or a taller window. That case is 1080p at 150 %, whose maximised window is 672 tall (PC-N3).
- **under 600 epx tall:** the filmstrip folds by itself as well.

**Why the left rail folds first:** as on the Mac. It holds what is chosen once a frame. The right rail holds what is
moved again and again, and the meter that judges it **[Mac HIG §1.3]**.

**Why Windows goes narrower than the Mac.** Snap is how Windows people put two windows side by side. A photo editor
that refuses a half-screen tile is one that "doesn't snap". The rails coming over the picture keep every control
reachable at any width. Nothing changes what the app can do; only what is on screen at once changes.

**The toolbar at narrow widths:**

| picture side | toolbar |
|---|---|
| ≥ 820 | everything (§5) |
| 620–820 | the zoom, Crop and Original go into **···** |
| under 620 | ‹ ›, Compare and Paste Settings go into ··· as well |

There is one overflow and it is ···. Fluent's command bar does the same: "primary commands will move into the
SecondaryCommands area" **[Microsoft: command bar]**.

Drawn: PC-N1 (snapped to the right half, 768 × 816, the left rail folded), PC-N2 (the left rail over the picture) and
PC-N3 (1080p at 150 %, both rails, the Navigator folded).

---

## 2. Sizes: the Mac's pieces in epx, Microsoft's type

**An epx here is about a Mac point.**

| screen | one unit |
|---|---|
| a 15.6-inch 1080p panel at 125 % (4.45 epx a mm) | 0.225 mm |
| a 14-inch 1080p panel at 150 % | 0.24 mm |
| the 14-inch MacBook Pro's point (Mac HIG §4.5: 5.0 pt a mm) | 0.20 mm |

So **the geometry is the Mac HIG's numbers, read as epx**, and the pieces come out 10–20 % larger on the glass. That is
right for a mouse at arm's length, and close to Microsoft's touch targets **[proposal]**:

| token | iPad | Mac (pt) | Windows (epx) |
|---|---|---|---|
| rail | 393 | 320 (280–440) | **320** (280–440) |
| margin | 16 | 14 | 14 |
| row | 44 | 32 | 32 (Microsoft: touchable "32 epx tall if the width is at least 120 epx") |
| round button | 44 | 28 | 28 drawn, **40 × 40 hit area** |
| capsule, pill | 36 / 44 | 24 / 28 | 24 / 28 drawn, 40 tall hit area |
| switch, segmented | 30 | 26 | 26 |
| Adjust tile | 60 | 48 (72 a row) | 48 (72 a row) |
| stock card | 115 × 96 | 92 × 76 | 92 × 76 |
| slider row | 58 | 40–44 | 44 |
| tick-ruler row | 64 | 48–50 | 50 |
| section head | — | 32 | 32 |
| rail head, toolbar | — | 52 | **48** |
| title bar | — | (the menu bar, the system's) | **32** |
| filmstrip | 96 | 88 | **80** |

**Type: Segoe UI Variable at Microsoft's minimums.**

Microsoft gives a floor: "Minimum values | 14px Semibold, 12px Regular | Text smaller than these sizes and weights are
illegible in some languages", and "Use Semibold instead of Bold for emphasis" **[Microsoft: typography]**. Two of our
four languages are the ones it means. So the Mac's sizes move up:

| use | Mac | Windows | Fluent ramp |
|---|---|---|---|
| row label, value, section head, toolbar title, rail title | 12.5–13 semibold | **14 Semibold** (14 Regular for values) | Body / Body Strong 14/20 |
| status line, chips, captions, tile names, section caps, meter numbers | 10–11.5 | **12 Regular** | Caption 12/16 |
| least | 10 | **12** | Caption |
| dialog title, Settings' pane title | — | 20 / 28 Semibold | Subtitle 20/28, Title 28/36 |
| bold | 700 | never; 600 (Semibold) | |

- Every text in the pages goes through this mapping (`gen_windows.py`: `win_type`).
- It fits in a 320 rail. The tightest case is *Colour Wheels* at 12 under its tile: it spills 3 epx past its 73 epx
  cell, into its neighbours' empty margins. Checked in PC-E1.
- **Fonts by language** **[Microsoft: typography, international fonts]**:

  | language | font |
  |---|---|
  | English | Segoe UI Variable (Text optical size), falling back to Segoe UI on Windows 10 |
  | 简体中文 | Microsoft YaHei UI |
  | 繁體中文 | Microsoft JhengHei UI |
  | 日本語 | Yu Gothic UI |

  Set them per locale on the QML `font.family`, never by hand-made fallback lists in each control. Win-Qt sets
  "Segoe UI" 12 for everything (`Main.qml`). That goes.
- Numbers keep Segoe UI Variable's tabular figures in values and rulers, so a value does not jitter while dragged.

**Display scaling.**
- Qt 6 is per-monitor DPI aware. QML sizes are epx at 100 / 125 / 150 / 175 / 200 % and beyond. Dragging the window
  to another monitor re-lays it out.
- Microsoft lists "scaling plateaus of 100%, 125%, 150%, 175%, 200%, 225%, 250%, 300%, 350%, and 400%", and asks that
  sizes and positions be "in multiples of 4 epx" (text excepted) **[Microsoft: screen sizes]**. The rails, rows,
  heads and margins are multiples of 4, except the Mac's 14 margin and 26 switch, which stay: they are inside a 320
  rail and do not meet a window edge.
- **The picture's 100 % is screen pixels**, as Win-Qt's `FrameCanvas` already does (`effectiveDevicePixelRatio`). At
  125 % a picture pixel is 0.8 epx. That is what a photographer means by 100 %.

**Interface Scale** (Settings › General): 100 / 115 / 130 % scale *these* sizes. Win-Qt has none; it is new.
- Windows' own *Text size* (Settings › Accessibility, "100% to 225%") is read at start and when it changes. Interface
  Scale follows it up to 130 %. Past 130 %, the menus, dialogs, tooltips and Settings follow it fully, and the rails
  stop at 130 % (416 epx; two still fit at 1536) **[proposal]**.
- Microsoft says "WinUI apps support text scaling by default" and that controls "must also resize and reflow". Qt Quick
  does not do it for us **[Microsoft: text scaling]**.

**Colours, unchanged** **[Mac HIG §2]**:

| token | value |
|---|---|
| ground | `#000` |
| card | `#2D2D2C` |
| plot | `#1E1F1E` |
| rule | `#3A3B39` |
| panel | `#141413` |
| wall | `#262625` |
| text, secondary | `#F9F7F3`, `#DAD8D4` |
| dim, faint | `#898989`, `#6D6D6B` |
| accent | `#E1A95F`, for actions and state only |
| selection | white |

Win-Qt's `Theme.qml` holds the desktop's older set: ground `#5f5f5f`, card `#2d2d2c`, selection `#f1f0eb`, accent
`#e1a95f`. Its grey rails and grey ground become black, and `panel` and `wall` are new tokens.

**No glass: no Mica, no Acrylic.**

| | what Microsoft says |
|---|---|
| Mica | for "the background of long-lived windows" |
| Acrylic | "used only for transient, light-dismiss surfaces such as flyouts and context menus" **[Microsoft: materials]** |

The owner killed glass on iPad on 2026-10-10 because it "killed the consistency" **[Mac HIG §2]**, and that decides it:
- **the title bar, the rails, the toolbar and the filmstrip are opaque black**;
- **menus and flyouts are opaque `#2B2B2A`** with a 0.6 epx edge and a shadow.

Three more reasons, all Microsoft's:
- Mica already "falls back to a solid colour" with transparency off, in Battery Saver, or on low-end hardware. So
  Windows itself treats a solid colour as a correct state.
- Acrylic "is GPU-intensive", and our GPU is the engine's.
- Qt Quick draws its own menus. A system backdrop would apply to the whole window, not to a menu.

**Corners** **[Microsoft: geometry]**. Microsoft: "8px" for windows, flyouts and dialogs, and "4px" for buttons and
list backplates.
- **The system's shapes get Windows' corners:** the window, menus, flyouts, the ContentDialog, its buttons, tooltips
  and Settings' list.
- **Our own pieces keep the iPad's shapes:** capsules, tiles, cards and the white selection. They are the app's look,
  as they are on the Mac.

**Symbols: Segoe Fluent Icons, by name** **[Microsoft: Segoe Fluent Icons]**. No glyph is drawn by hand in the app.

| piece | glyph (code point) |
|---|---|
| left rail, right rail | DockLeft (E90C), DockRight (E90D) |
| previous, next | ChevronLeft (E76B), ChevronRight (E76C) |
| ··· | More (E712) |
| Paste Settings, Copy Settings | Paste (E77F), Copy (E8C8) |
| Crop | Crop (E7A8) |
| Export | Export (EDE1) |
| Import | Import (E8B5) |
| a section's ↺ | Undo (E7A7) |
| an open tile's 🗑 · ↶ · ✓ | Delete (E74D), Undo (E7A7), Accept (E8FB) |
| Settings, Info | Settings (E713), Info (E946) |
| search, filter, sort | Search (E721), Filter (E71C), Sort (E8CB) |
| folder, library | Folder (E8B7), Library (E8F1) |
| a photo, a collection | Photo (E91B), PhotoCollection (E7AA) |
| favourite | Heart (EB51), HeartFill (EB52) |
| rating | FavoriteStar (E734), FavoriteStarFill (E735) |
| read-only | Lock (E72E) |
| rotate | Rotate (E7AD) |
| zoom | ZoomIn (E8A3), ZoomOut (E71F) |
| full screen | FullScreen (E740), BackToWindow (E73F) |
| grid, list | GridView (F0E2), List (EA37) |
| Refresh (a Capture One source) | Refresh (E72C) |
| Brightness, Colour, Contrast, Effects (tiles) | Brightness (E706), Color (E790), Contrast (E7A1), Effects (E794) |
| caption buttons | ChromeMinimize (E921), ChromeMaximize (E922), ChromeRestore (E923), ChromeClose (E8BB) |

- **Not in the font:** Compare, Flip, and several Adjust tiles (Tone, HSL, Channels, Vibrance, Saturation,
  Temperature, Curve, Vignette, the Darkroom's Enlarger and Decode). They come from **Fluent System Icons**. Microsoft
  says those are "open-source under the MIT License", which is GPL-compatible. They are bundled as SVG at 20 epx, in
  the same 1 epx line **[proposal]**.
- Segoe Fluent Icons is "not included by default on Windows 10", and Microsoft says "you may not ship it to another
  platform". So on Windows 10 the same Fluent System Icons SVGs stand in for every glyph **[Microsoft]**.
- The drawings approximate the glyphs; the names above are the ones to use.

---

## 3. Develop and Edit, both on screen

### 3.1–3.6: as the Mac HIG, with these differences

The rule, the two rails, their sections, "nothing shows twice on one screen", the Navigator and the Latitude meter,
and the homes of the desktop's controls are **the Mac HIG's §3.1–3.6, unchanged**, except where §3.8 gates a section.
Read them there. The differences on Windows:

| Mac HIG | Windows | why | source |
|---|---|---|---|
| §3.2 left rail: Film & Paper · Format · Film Edge · Date Back | **Film & Paper · Format**. Film Edge and Date Back come back in their places when the engine has them (§3.8) | `overscan` and `date_imprint` are refused | [Win-Qt: engine.cpp capabilities] |
| §3.2 the papers' strip scrolls "with a trackpad swipe, with ⇧ and the wheel" | a precision touchpad's two-finger swipe, **Shift+wheel**, a finger or pen drag, or the arrows at the strip's ends on hover | Windows' horizontal-wheel convention | [proposal] |
| §3.3 Darkroom › Decode: White Balance · Scene Placement (· Lens) | **White Balance · Lens · RAW**. *RAW* is Win-Qt's decode choice, **Compatible \| Highlights (experimental)**, per frame. Scene Placement comes back when `scene_latitude_mapping` is ported | Win-Qt has the decode mode per photo ("兼容模式" / "高光扩展（实验）"), and it belongs to the source, as Lens does | [Win-Qt: Main.qml "RAW 解码", preview_host.hpp `DecodeMode`] |
| §3.5 the meter shades Scene Placement's pull | no shading until Scene Placement is ported. The meter itself works: the scene-latitude *analysis* runs off Apple | PORT_PLAN §2: "The *analysis* `spk_scene_latitude` already works off Apple" | [Win-Qt: engine/PORT_PLAN.md] |
| §3.6 Paper pill's shelves include Digital Intermediate | no DI shelf, no DI in Settings › Rendering or Export until `digital_intermediate` is ported | refused | [Win-Qt] |
| §3.6 Grain, Halation, Glare on/off become strengths (0 is off) | the same; Win-Qt's `grain_active` and similar flags are set false at 0 and true above it | Win-Qt draws an on/off box and a strength ("颗粒 / 强度") | [Win-Qt: Main.qml `Effect`, preview_host.hpp] |
| §3.6 Size: Custom | Format's size cards write `film_format_mm`. Win-Qt's seven lengths (18–90 mm) and a custom length live in ···, Custom Size… | Win-Qt's "画幅长边" ComboBox | [Win-Qt] |
| §3.5 the Navigator's well | folds to one line under 720 epx tall (§1.3) | the 1080p-at-150 % window is 672 tall | [proposal] |

**The detent at rest has no trackpad tap on Windows** (Mac HIG §6.3 used the Force Touch trackpad).
- Windows' precision touchpads give apps no haptic call. So **the detent is the 1.2 % hold and nothing else**, plus the
  rest tick that is already drawn.
- Where a pen reports a haptic controller (Windows 11's pen haptics, on pens that have them), the detent may send it
  one short tap while the pen drags **[proposal; check on a device before it ships]**.
- Settings › General has no Haptics row unless such a pen is present.

### 3.7 What each piece looks like, and what it is built on

The columns:
- **Looks like:** the iPad page (`design/ipad/INDEX.md`) and the iOS component to read.
- **Mac HIG:** the section that placed it.
- **Built on:** a file under `windows_UI/` at `origin/Windows_Linux` b68ed6c7, or **new**. New means new QML in
  `windows_UI/qml/` or a C++ class in `windows_UI/src/`, in that app's idiom: Qt Quick Controls "Basic" style
  (`main.cpp`), `Theme.qml` tokens, `PreviewController` properties.
- **Wins:** *iPad*, *Win-Qt* (the Windows app's behaviour stays), *Windows* (the platform's convention), or *both*.

| piece | looks like (iPad) | Mac HIG | built on (Windows) | wins |
|---|---|---|---|---|
| the window, rails, walls, folding | W-D1's column, twice; `App/WindowLayout.swift` | §1 | `Main.qml`'s top `RowLayout` (rails 246 / 288 → 320 / 320; `minimumWidth: 1100` → 500); **new** `RailWall.qml` (drag, double-click); **new** `WindowLayout` rules in QML by window width (§1.3) | both |
| title bar, menu bar, caption buttons | — | §6.1 | **new** `TitleBar.qml` (`MenuBar` from QtQuick.Controls, the caption buttons); **new** C++ `WindowChrome` (`WM_NCHITTEST`: caption, `HTMAXBUTTON`, edges) | Windows |
| a rail's head | W-D1's head, without its switch | §3.1 | `Main.qml`'s rail title `Text` ("胶片与相纸", "参数 · 显影前") → *Develop*, *Edit*; the Pre-Dev words go | iPad |
| Library \| Edit | `DesignSystem/Segmented.swift` | §4.1 | **new** `WorkspaceSwitch.qml` | Mac HIG (a workspace) |
| a section and its head (▾, title, ↺, ···, summary) | — (1.3.3's); V5's reset scope | §3.1 | `Section.qml` (today a rule and a bold title) gains the disclosure, ↺, ···, the folded summary and Ctrl+click | Mac HIG |
| Navigator | — (1.3.3's) | §3.5 | `Main.qml`'s "导航图" section: its `FrameCanvas` (enabled: false) stays; Fit · 100 % · 200 % and the view's rectangle are added | Win-Qt's canvas |
| film cards, paper cards | W-D1: `StockCards.swift` | §3.2 | **new** `StockCard.qml`, replacing `Main.qml`'s `FilmGroup` lists and the paper `ListView`. Each card's picture is a small render (§8.6) | iPad |
| the film grid's grip | — | §3.2 | **new** (a `DragHandler` on the grid's lower edge) | Mac HIG |
| Film Exposure dial, tick rulers | W-D1, W-E2: `TickRuler.swift`, `InputFeedbackRules.swift` | §3.2, §6.3 | **new** `TickRuler.qml` (a C++ `QQuickPaintedItem` for the scale); replaces the Qt `Slider` inside `Main.qml`'s `Adjustment` component; keeps its `beginEditGesture` / `endEditGesture` (one drag, one undo step) | iPad's face and detents; Win-Qt's gesture |
| Format | W-D2: `DevelopPanels.swift` | §3.2 | `Main.qml`'s "胶片画幅与效果" (the `film_format_mm` ComboBox, the three `Effect`s) → size cards and two rulers | iPad |
| Film Edge, Date Back | W-F1: `FilmEdgeSteps.swift` | §3.2 | **gated** (§3.8); new when `overscan` and `date_imprint` are ported | — |
| Half-Frame Pair | W-P1 | §3.2 | **gated** with `overscan` (§3.8) | — |
| Latitude meter | `LatitudeMeter.swift` | §3.5 | **new** `LatitudeMeter.qml` on a **new** host call to the engine's scene-latitude analysis. Win-Qt shows none today ("暂不显示示意统计") | both: the iPad's look, the engine's numbers |
| Adjust: tiles, a tile's bar, the controls | W-E1: `AdjustPanel.swift`, `EditTool.swift`, `AdjustSliders.swift`, `CurvePanel.swift`, `ColourPads.swift`, `HSLPanel.swift` | §3.3, §3.6 build note | **new**, all of it. Win-Qt has no post-development grading ("后期调色仍待独立实现"). A Layer 2 pass, two ways: live on the display (a shader on `FrameCanvas`'s texture: no worker job, so a drag moves the picture at once) and the same maths in `FrameOutput` for export (16-bit). The iOS Layer 2 kernel's maths is the reference; a test holds the two equal | iPad |
| Darkroom (three tiles) | `AdjustPanel.swift` (`EditTile`, `EditToolBar`), `EditTool.swift` | §3.3 | **new** tiles | iPad |
| Darkroom › Enlarger | `DevelopPanels.swift` (Enlarger) | §3.3 | `Main.qml`'s "放大机 · 相纸亮度" (`exposureEv` → `print_exposure`, `yFilterShift`, `mFilterShift`) → pills and rulers; Pre-flash a **new** `RenderSettings` field | iPad |
| Darkroom › Decode | the Decode tile | §3.3 | `Main.qml`'s "RAW 解码" ComboBox → the RAW pill; White Balance and Lens **new** (LibRaw decode work, which Win-Qt's DESIGN_ALIGNMENT says they need) | iPad; Win-Qt's RAW |
| Darkroom › Effects | the Effects tile | §3.3 | `Main.qml`'s `Effect`s (Glare) → pills; Couplers, Sub-layers and Scatter **new** `RenderSettings` fields (ordinary `set_params` deltas) | iPad |
| Film Exposure | W-D1 | §3.2 | `Main.qml`'s "输入 / 相机 › 胶片曝光" (`filmExposureEv`) moves under the films | iPad |
| Crop | W-E3: `Features/Frame/` | §6.9 | `Main.qml`'s crop section and `cropOverlay`; `FrameOutput`'s `Geometry` (free, 1:1, 3:2, 4:3, 16:9; quarter turns; flips; ±45° straighten on 16-bit samples). Added: 5:4, 7:5, original ratio; the iPad's stage; while straightening, the shown picture turns on the GPU and the 16-bit straighten commits on release, as Win-Qt does now | iPad's stage; Win-Qt's geometry |
| toolbar | W-D1's picture bar and action row | §5 | `Main.qml`'s top `RowLayout` (导入 RAW, 导出, 裁切, 撤销, 重做, 适合, 100%) rearranged; Import, Undo and Redo move to the menus | both |
| status line | the iPad's words | §7 | `PreviewController::status_` (Simplified Chinese strings today) → V5's words, translated (§9.2) | iPad's words, Win-Qt's states |
| the picture, badges | W-D1, W-D1-zoom | §7 | `FrameCanvas` (C++). `Main.qml`'s centred `BusyIndicator` and its "FULL" badge go | Win-Qt's canvas; the iPad's quiet-badge rule |
| Compare, the Original | W-X1, W-X2 | §6.8 | **new**; needs the source original: a **new** host call that renders the decode without the film (Win-Qt lists "original/split comparison" as future work) | iPad |
| filmstrip | `FilmStrip.swift` | §4.4 | `Main.qml`'s `photoStrip` (132 epx tiles, 160 tall, a check box per tile) → 80 tall; the check boxes stay for touch (§6.3) | both |
| Copy Settings, Paste to N, presets | W-X4: `CopySettingsSheet.swift`, `PresetSheet.swift` | §6.7 | `PreviewController::syncSelectedSettings` ("同步设置", which keeps each crop) → Paste to N; the groups and presets **new** | iPad |
| undo | — | §6.1 | `PreviewController::undo/redo`, per photo, 64 steps, a drag is one step | Win-Qt |
| edits kept between runs | — | — | `EditStore` (`%LOCALAPPDATA%\SpektraLab\SpektraLab Windows\Edits`), saved 350 ms after a change; RAW files and folders are never written | Win-Qt |
| Library | W-L1, W-L2, W-L0: `LibraryWidePage.swift`, `LibrarySidebar.swift`, `SelectMode.swift`, `FirstRunView.swift` | §4 | **new**. Catalogs, sessions and Capture One need `spklib-host` for Windows (§8.4). A folder source can be built now on Win-Qt's file list and `EditStore` | both |
| light table, contact sheets | W-T1–T4, W-K1–K14 | §4.5 | **new** | iPad |
| Export | W-O1, W-O2: `ExportSheet.swift`, `ExportProof.swift`, `RecipeChips.swift` | §6.6 | `Main.qml`'s `exportPopup` (a `Popup`) and its `FileDialog` / `FolderDialog` → a ContentDialog; `FrameOutput` (TIFF 16, PNG 8/16, JPEG 8, sRGB, long edge, never overwrites) and `exportBatch` stay | iPad's form, Win-Qt's exporter |
| Settings | W-G1: `RecipePages.swift` | §6.5 | **new** `SettingsWindow.qml` (a second `ApplicationWindow`) | both |
| menus and keys | `PadCommands.swift` | §6.1 | `Main.qml`'s `Shortcut`s → `Action`s with shortcuts, in the `MenuBar` | Windows conventions; Win-Qt's keys |
| capability gates | — | — | **new** `PreviewHost::capabilities()` → `PreviewController.unsupportedFeatures` (a `QStringList` property) (§3.8) | — |

**Never referenced, never copied:**
- the iOS app's `Sources/Engine/` and `Sources/Scheduler/`, its device policy and memory budget;
- its stock-preview service;
- `Features/Shoot/`;
- the phone's page structure;
- the Mac's `RenderScheduler` and `Session`.
- `desktop/` on the same branch is a second Windows front end (Tauri and web). It is not this app's frame (§8.5).

### 3.8 What the Windows engine refuses: the gates

**The rule** (the owner's, Mac HIG §3.6 build note): **a tile that does nothing is not shipped.**

**The facts.** The engine lists what it refuses in `capabilities.backend.unsupported_features`
(`engine/src/pipeline/engine.cpp`, `capabilities_json`). Today the list is `digital_intermediate`,
`scene_latitude_mapping`, `contrast_mask`, `overscan` and `date_imprint`. A request that turns one on "fails with
`SPK_ERR_USER` before the session changes" (`engine/PORT_PLAN.md`, owner's decision of 2026-10-06).

**How the app uses the list:**
1. At start the worker asks the host for the engine's capabilities: **new** `PreviewHost::capabilities()`.
   `PreviewController` keeps the list as `unsupportedFeatures`.
2. Every gated piece binds to it, for example `visible: !preview.unsupportedFeatures.includes("overscan")`. Nothing is
   hard-wired to "Windows".
3. **Nothing ever sends a refused request.** Settings that carry a refused feature are stripped before `set_params`:
   - a preset;
   - pasted settings;
   - a Mac catalog's edit.

   The status line says so once: *Film Edge left off · not on Windows yet*.
4. When a port lands, its name leaves the list. The piece appears in its place, as drawn on the Mac. Nothing is
   redesigned.

| feature | flag | its place (Mac HIG) | until ported | source |
|---|---|---|---|---|
| **Film Edge** | `overscan` | left rail, third section; Copy Settings' *Film Edge & Date Back*; Frame › Reset › Film Edge; Crop's *Held by Film Edge* | **absent**: no section head, no dimmed tile, no "coming soon". The left rail ends after Format | [Win-Qt] |
| **Half-Frame Pair** | `overscan` (the pair's layout lives in `overscan.cpp`) | Frame › New Half-Frame Pair; the Library's Pair; the pair section | **absent**. A pair from a Mac source shows its left frame, and the Info rail reads *Half-Frame Pair · not on Windows yet* | [Win-Qt: PORT_PLAN §4] |
| **Date Back** | `date_imprint` | left rail, fourth section; Frame › Reset › Date Back | **absent** | [Win-Qt] |
| **Scene Placement** | `scene_latitude_mapping` | Darkroom › Decode's pill; the meter's shaded pull; Copy Settings' Darkroom › Scene Placement | **absent**. The meter still reads the scene: the analysis is portable | [Win-Qt: PORT_PLAN §2] |
| **Digital Intermediate** | `digital_intermediate` | the Paper pill's shelf; Settings › Rendering; Export's DI package | **absent** | [Win-Qt] |
| **Tone Mask** | `contrast_mask` | none: it is hidden on the Mac too (its flag is off) | nothing to gate | [Mac HIG §3.6] |

**Where the list is visible:** Settings › Engine, *Not on Windows yet* (PC-G3), and Help › About. It is said once, in
one place, not on every control.

**Why absent rather than dimmed:**
- A dimmed section invites a click that does nothing, which is the owner's rule.
- A "coming soon" line is a promise, which breaks V5's words rule.
- The Mac pages already show where each piece goes. PC-E5 draws the left rail once Film Edge and Date Back are ported.

**Built but not yet on Windows** (host work, not engine refusals). The same rule holds: until a piece is built, it is
not in a release build.

| piece | the host or UI work |
|---|---|
| Adjust (all eleven tiles) | Layer 2 |
| White Balance, Lens | LibRaw decode |
| Pre-flash, Couplers, Sub-layers, Scatter, anti-halation removal, Print Effects, Extended Dynamic Range | `RenderSettings` fields |
| the Latitude meter | the analysis call |
| Compare and the Original | the decode render |
| colours other than sRGB, HEIF | `FrameOutput` |
| catalogs, sessions, Capture One | `spklib-host` for Windows |
| the light table | — |

§8 orders them.

---

## 4. The Library, sessions and catalogs

**The Mac HIG's §4 holds** (entering and leaving, the sidebar, the source well, sources and their states, the
filmstrip as the current result, the light table), with these Windows changes:

| | Windows | source |
|---|---|---|
| keys | Library **Ctrl+Alt+1**, Edit **Ctrl+Alt+2** (Go menu); back **Alt+←** (Windows' Back). Ctrl+1 stays 100 %, as Win-Qt has it | [Win-Qt: Main.qml] [Microsoft: keyboard shortcuts] [proposal] |
| into the editor | double-click, **Enter**, or the Info rail's **Develop ↵** | [Mac HIG §4.1] |
| opening from File Explorer | double-clicking a `.spkcatalog`, `.spksession` or `.cocatalog` lands in the Library, through a file association the installer writes (§8.1) | [proposal] |
| the Info rail's foot | **Show in File Explorer**; for Capture One, **Open in Capture One** above it | [proposal] |
| folders in the sidebar | by volume as Windows names it: *Local Disk (C:)*, *Photos (E:)*, *Travel SSD (F:)*; a missing drive is *Offline* in danger red, its tiles marked | [Mac HIG §4.3] |
| paths shown | Windows' own: `E:\Archive\2024-09`; a network share as `\\server\photos\…` | [proposal] |
| Trash (a session) | **Recycle Bin**: the helper's trash plan, then the app moves the files with undo (`IFileOperation`, allow undo), then commits | [proposal]; the Mac moves them "to the macOS Trash itself" (API-SPEC-library-helper §1) |
| edits of a folder source | in the app's own store, as Win-Qt keeps them (`EditStore`); nothing is written beside the RAW files. The Mac writes beside the frames (1.3.3's sidecars). **Win-Qt wins**: it already promises "RAW files and their directories are not modified" | [Win-Qt: README] |
| multi-pick | Ctrl+click and Shift+click; on touch, each tile shows a check box at its top right, as File Explorer's item check boxes and as Win-Qt's filmstrip already does | [Win-Qt: Main.qml photoStrip] [proposal] |

### 4.1 Capture One on Windows

- **Read-only, unchanged.** Nothing is written inside a catalog or a session. A rating key shows *Ratings are set in
  Capture One* **[Mac HIG §4.3]**.
- **Where they are.**
  - A catalog is a `Name.cocatalog` folder holding `Name.cocatalogdb`. Capture One usually keeps catalogs under the
    user's *Pictures* folder. That was not checked on a Windows install.
  - A session is a folder with `Name.cosessiondb` and its *Capture · Selects · Output · Trash*.
  - The source menu's Open Capture One Catalog… (Ctrl+Shift+O) starts there **[proposal]**.
- **Drive letters.**
  - A catalog stores where its images were, with drive letters.
  - A drive that comes back under another letter, or a catalog made on a Mac (`/Volumes/Photos SSD/…`), shows those
    folders *Offline*.
  - **Locate…** relinks a whole prefix at once (`location.relink`), for example `/Volumes/Photos SSD` → `E:\`.
  - Paths compare without case, as NTFS does.
  - **[Mac HIG §4.3, API-SPEC-library-helper `locations.list` / `location.relink`]**
- **States** as the Mac's, plus one for Windows' file locks: *Capture One is writing* · Try Again. The helper "refuses
  while Capture One is mid-write" **[API-SPEC-library-helper §1]**.
- **Refresh** is **F5** (Microsoft: "Refresh | F5 or Ctrl + R") as well as the well's *Refresh* **[Microsoft: keyboard
  accelerators]**.
- Capture One *sessions* are probe-only in the helper today ("until their formats have been checked"). PC-L4 draws the
  session as it will be.

### 4.2 Actual Size from the display's size

`DisplayInformation` gives what is needed **[Microsoft: DisplayInformation]**:
- epx a mm = `RawDpiX` ÷ 25.4 ÷ `RawPixelsPerViewPixel`;
- Win32 code can read the same raw DPI with `GetDpiForMonitor(MDT_RAW_DPI)`.

**The drawing's laptop:** a 15.6-inch 1920 × 1080 panel at 125 % gives **4.45 epx a mm**. A 135 frame is 160 × 107 epx.

**When it is not known:**
- `RawDpiX` "can return 0 when the monitor doesn't provide physical dimensions and when the user is in a clone or
  duplicate multiple-monitor setup";
- `DiagonalSizeInInches` "May return null … (when connected to a projector, or displays are duplicated)".

So on 0, on null, or while duplicated, **there is no 1:1 disc**, as an unknown iPad or Mac display shows none. A size
that is not known is never claimed **[Mac HIG §4.5]**. Lay a ruler on the glass before it ships **[proposal]**.

**The loupe** follows the pointer while **Ctrl** is held (the Mac's ⌥). Alt alone would open the menu bar's access
keys on release **[proposal]**.

---

## 5. The toolbar

It sits over the picture only, 48 epx tall. Its glyphs are Segoe Fluent Icons at 20 epx (Microsoft: "20x20px" in a
command bar's primary area). There are no plates at rest; a 4 epx plate shows on hover **[Microsoft: command bar,
geometry]**.

| place | items, in order | source |
|---|---|---|
| leading | the left rail's button (DockLeft, lit while shown); ‹ › (ChevronLeft, ChevronRight); **the title**: the frame's name and place (*_DSC0061 · 4 of 14*) over **the status line** (§7) | [Mac HIG §5] |
| middle | the zoom pill (*Fit ▾*: Fit, 50, 100, 200, 400 %); **Crop**; **Original**; **Compare** | [Mac HIG §5] |
| trailing | **···** (More: Copy Settings, Copy Settings…, Presets ▸, Save as Preset…, Undo History, **Settings…** last); **Paste Settings**; **Export** (the accent capsule, the one prominent action); the right rail's button (DockRight) | [Mac HIG §5]; Microsoft: "place the settings entry point as one of the last items in the "More" overflow menu" |

- **The window's title is the taskbar's:** *_DSC0061 — SpektraLab* in the editor, and *Darkroom 2026 — SpektraLab* in
  the Library. Win-Qt already uses `fileName + " — SpektraLab"`. It sits in the title bar in caption type.
- **The toolbar's title is the frame's.** It never reads "SpektraLab".
- The status line fits its room or drops trailing parts, never "…". A status too long for the toolbar fails the
  drawings' build.
- **Export is dimmed** until the open frame has its first print. There is no Process button.
- At narrow widths the toolbar sends items into ··· (§1.3).
- Every toolbar item is also in a menu, so the keyboard and Narrator reach it.

## 6. Menus, keys, pointer, touch, pen

### 6.1 The menu bar, in the title bar

**The decision: an in-window menu bar, not a command bar.**

| | menu bar | command bar |
|---|---|---|
| what Microsoft says | "To show a set of multiple top-level menus in a horizontal row, use menu bar"; "a MenuBar can also be used when the functionality in your app is too complex for a command bar" | the toolbar already is one (a row of icons with an overflow) |
| what we have | about 70 commands, 40 of them with keys | |
| the keyboard | Alt and F10 reach every command through access keys | a second command bar would duplicate the toolbar and hide the commands that have no icon |
| precedent | Windows photo tools (Capture One, Lightroom Classic, Photoshop) all keep a menu bar | |

**Why in the title bar:** it costs no height. The window is only 816 tall, and a separate row would take 32 epx from
the picture. Microsoft allows "custom menus in the title bar area" **[Microsoft: title bar customization]**.

**The menus:**
- Order: File, Edit, View, Frame, Go, Help.
- **There is no app menu and no Window menu.** Windows has neither.
  - The app menu's items move: About and Check for Updates… to Help; Settings… to File (and to ···, last); Quit
    becomes File › Exit (Alt+F4).
  - Minimize, Maximize and the list of windows are the system's (the caption buttons, Win+↓, Alt+Tab).
- The board `board_menus.svg` draws each menu, with its access keys underlined.

| menu | items (keys) | source |
|---|---|---|
| **File** | Open… Ctrl+O · Import… Ctrl+Shift+I · Open Recent ▸ · — · New Catalog… · New Session… · Open Library… · Open Capture One Catalog… Ctrl+Shift+O · Refresh Library F5 · — · Export… Ctrl+E · Export with the Last Recipe Ctrl+Shift+E · — · Settings… Ctrl+, · — · Exit Alt+F4 | [Win-Qt: Ctrl+O, Ctrl+E] [Mac HIG §6.1] [Microsoft: F5, Alt+F4] |
| **Edit** | Undo *Tone* Ctrl+Z · Redo Ctrl+Y · — · Cut Ctrl+X · Copy Ctrl+C · Paste Ctrl+V · Select All Ctrl+A · Select None Ctrl+Shift+A · — · Copy Settings Ctrl+Shift+C · Copy Settings… Ctrl+Alt+Shift+C · Paste Settings Ctrl+Shift+V · Presets ▸ · — · Find Ctrl+F | [Microsoft: "Redo \| Ctrl + Y"] [Win-Qt: Ctrl+Shift+Z also redoes] [Mac HIG §6.1] |
| **View** | ✓ Develop Rail F7 · ✓ Edit Rail F8 · Hide Both Rails Ctrl+B · ✓ Filmstrip Ctrl+Shift+F · ✓ Navigator · Histogram · — · Zoom In Ctrl++ · Zoom Out Ctrl+− · Zoom to Fit Ctrl+0 · 100 % Ctrl+1 · — · Compare Y · Bypass Adjustments Ctrl+Shift+B · — · Full Screen F11 | [Win-Qt: Ctrl+0, Ctrl+1] [Microsoft: "Zoom In \| Ctrl + +", "Zoom to default view \| Ctrl + 0"] [proposal: F7, F8] |
| **Frame** | Develop Again Ctrl+Enter · — · Crop C · Rotate Left Ctrl+[ · Rotate Right Ctrl+] · Flip Horizontal · Flip Vertical · — · Favourite . · Rating ▸ (0–5) · — · Reset ▸ (Film & Paper · Format · Adjust · Darkroom · Crop) · — · Show in File Explorer Ctrl+Shift+R | [Mac HIG §6.1]; Film Edge, Date Back and New Half-Frame Pair are gated (§3.8) |
| **Go** | Library Ctrl+Alt+1 · Edit Ctrl+Alt+2 · Light Table Ctrl+Shift+L · — · Previous Frame ← · Next Frame → · — · Back Alt+← | [proposal] |
| **Help** | SpektraLab Help F1 · Keyboard Shortcuts · — · Check for Updates… · Show Logs in File Explorer · Make a Diagnostic Bundle… · — · About SpektraLab | [Mac HIG §6.1] |

**Notes:**
- **Toggles are checked items, not Hide / Show words.** The Mac flips the item's words. Windows' own View menus use a
  check mark (Notepad's *Status bar*). Hide Both Rails stays words, because it is an action, not a state
  **[proposal]**.
- Unavailable items are dimmed, never hidden. The gated items are absent, because they are not unavailable: they do
  not exist yet (§3.8).
- **Access keys:**
  - Alt (or F10: "Activate the menu bar in the active window") shows them. The menu titles' keys are
    **F**ile, **E**dit, **V**iew, F**r**ame, **G**o, **H**elp **[Microsoft: access keys, keyboard shortcuts]**.
  - In 简体中文, 繁體中文 and 日本語 the key follows the word in parentheses, as in 文件(F) or ファイル(F), so the
    Latin key works on any keyboard **[proposal]**.
  - Qt Quick's `MenuBar` takes `&File`.
- **Undo** names the step (*Undo Tone*). It is per photo and bounded to 64 steps, and one drag is one step
  **[Win-Qt: README]**.
- **Cut, Copy and Paste** act on text fields and are dimmed otherwise.
- **Ctrl+Shift+V:** Windows uses it for "Paste as plain text" **[Microsoft: keyboard shortcuts]**. It is Paste
  Settings only while no text field has focus. In a field, the field gets it.

### 6.2 Keys

The Mac's ⌘ becomes Ctrl. Where a Windows convention or Win-Qt already decided a key, that wins. The full table is
`board_keys.svg`.

| key | does | source |
|---|---|---|
| Space, held | the Original, until release; Space-drag pans when zoomed | [Mac HIG §6.2] |
| \\ , held | the Original, from anywhere in the window | [Mac HIG] |
| Y | Compare | [Mac HIG] |
| Z | Fit and 100 % | [Mac HIG]; Win-Qt's double-click does the same |
| C | Crop; **Enter** keeps, **Esc** cancels | [Win-Qt: Main.qml Return / Escape in crop] |
| ← → | previous and next frame | [Mac HIG] |
| 0–5, . | rating, favourite | [Mac HIG] |
| Enter | in the Library, Develop; in crop, Done | [Mac HIG] |
| Esc | closes the open flyout or menu, then the open tile, then cancels crop; leaves full screen | [Mac HIG] |
| **F6, Shift+F6** | the next and previous pane: toolbar, left rail, picture, right rail, filmstrip | Microsoft: "Go to the next UI pane \| F6" |
| Tab, Shift+Tab | focus within a pane | [Microsoft: accessibility checklist] |
| arrows on a focused control | one step; **Ctrl** a tenth; Shift ten steps | [Mac HIG §6.2], ⌥ → Ctrl |
| Del | in the Library, a writable source: to the Recycle Bin, with undo | Microsoft: "Delete selected item (with undo) \| Del, Ctrl+D" |

**Keys Windows has, which we never use:**

| key | what Windows does with it |
|---|---|
| Win+anything | Windows' own |
| Alt+Tab, Alt+F4, Alt+Space | switch windows, close (File › Exit), the window menu |
| Ctrl+Esc, Ctrl+Shift+Esc, Ctrl+Alt+Del | Start, Task Manager, the security screen |
| Ctrl+Alt+Tab, Alt+Ctrl+Insert | the window switcher, Windows Sandbox |
| Ctrl+Shift alone, Alt+Shift alone | "switch the keyboard layout" |
| Ctrl+Space | "Enable or disable the Chinese input method editor (IME)" |
| F2, Del, Ctrl+D | kept for rename and delete, their Windows meanings |

[Microsoft: keyboard shortcuts, keyboard accelerators]

**Why these keys:**

| key | why |
|---|---|
| **F7 · F8** for the rails | Lightroom Classic's keys on Windows for the left and right panels. They are free of modifiers, so nothing clashes with the IME or AltGr. During composition in a Japanese IME, F7 and F8 convert text, but only in a text field, which takes every key first |
| **Ctrl+Shift+F** for the filmstrip | F6 is Microsoft's pane key, so the filmstrip cannot have it |
| **Ctrl+0 · Ctrl+1** for Fit · 100 % | Win-Qt's, Photoshop's, and Microsoft's "Zoom to default view \| Ctrl + 0". The Mac's ⌘0 Actual Size and ⌘9 Fit do not come over |
| **Ctrl+Alt+1 · 2** for the workspaces | Ctrl+1 is taken by 100 %. On a keyboard with AltGr, Ctrl+Alt is AltGr; that only matters in a text field, which takes the key first |
| **Ctrl (not Alt) for fine control** | Pressing and releasing Alt alone opens the menu bar's access keys. A fine drag that ends with Alt released would steal focus. So the Mac's ⌥ becomes Ctrl: for a quarter-speed drag, a tenth-step arrow, every section with Ctrl+click, and the loupe |
| **Ctrl+Y** for Redo | Microsoft's table says so. Ctrl+Shift+Z also redoes, as Win-Qt has it |

`TypingKeyGuard`'s rule stays: a focused text field takes every key first **[Mac HIG §6.2]**. Win-Qt already does it
for undo (`editingText`).

### 6.3 Mouse, touch, pen

**The Mac HIG's §6.3 holds for the mouse.** The changes:

| thing | Windows | source |
|---|---|---|
| a slider, a ruler | drag anywhere on the row, relative; **Ctrl** a quarter of the speed; **Shift** snaps; double-click (or double-tap) resets to rest; click the value to type | [Mac HIG §6.3] ⌥ → Ctrl |
| a section head | a click opens or closes it; **Ctrl+click** opens or closes every section in the rail | [proposal] |
| secondary click | right-click; **press and hold** on touch; a pen's barrel button acts as a right-click | [proposal] |
| the picture's context menu | Microsoft's **command bar flyout**: Copy Settings, Paste Settings, Compare and Export as a row of icons on top; Zoom to Fit, 100 %, Reset Crop and Show in File Explorer under it (PC-X3). Microsoft: "Command bar flyout is the recommended control for creating context menus" | [Microsoft: command bar flyout] |
| the picture | **Ctrl+wheel** or a pinch zooms; the wheel, two fingers or a finger drag pans when zoomed; double-click or double-tap toggles Fit and 100 % (Win-Qt's double-click already does) | [Win-Qt: FrameCanvas] [proposal] |
| the papers' strip | Shift+wheel sideways; a touchpad or a finger swipes it | [proposal] |
| tooltips | every glyph without a word: its name and key (*Compare (Y)*), 4 epx corners | [Mac HIG] [Microsoft: geometry] |

**Touch (Surface and other touch laptops).**
- Microsoft: "We define touchable as a minimum of 40 x 40 epx, even if the visual is smaller, or 32 epx tall if the
  width is at least 120 epx". It suggests "44 x 44 epx" where it can **[Microsoft: targeting]**.
- So every control has a **40 × 40 hit area** whatever it draws:
  - the 28 epx discs, 24 epx chips and ruler marks grab 40;
  - the 32 epx rows qualify, being wider than 120;
  - the curve's points and the colour pads' dots grab 40, as the Mac's grab 28 pt.
- Hit areas that would overlap go to the nearest target. Nothing is drawn larger for touch: one layout for every
  input, as the Mac HIG keeps one for every pointer.
- The filmstrip and the grid show a check box per frame on touch, so several can be picked without Ctrl
  **[Win-Qt: photoStrip]**.

**Pen.**
- The pen is a precise pointer. The tip clicks and drags, and hover shows hover states and tooltips.
- Pressure is not used. No control draws ink.

### 6.4 Drag and drop with File Explorer

Microsoft: drag and drop "works in all directions, including app-to-app, app-to-desktop, and desktop-to-app", and
"Copy is the most common" **[Microsoft: drag and drop]**.
- **In from File Explorer** (files and folders):
  - onto the grid: added to the open catalog or session;
  - onto a read-only source: refused, with the reason;
  - onto the editor: they open as the filmstrip. Win-Qt's `DropArea` already opens dropped RAWs.

  **[Mac HIG §6.4] [Win-Qt: Main.qml DropArea]**
- **Out to File Explorer or the desktop:** a tile or a filmstrip frame is written with the last recipe, as files
  (storage items) **[proposal]**.
- **Ctrl** while dropping forces a copy, Windows' own modifier. A drop can be undone.

### 6.5 Settings

**File › Settings… (Ctrl+,), and ··· › Settings…, last.**
- **Its own window**, 860 × 600 and restored, with the panes in a list at the left (Windows Settings' own pattern). The
  chosen pane is white.
- It is a window rather than a page in the editor so its changes show on the picture beside it.
- Microsoft: "When a user changes a setting, the app should immediately reflect the change", within "a constrained
  max width (around 1000–1100 px)" **[Microsoft: app settings]**.

| pane | holds | source |
|---|---|---|
| General | Language (System, English, 简体中文, 繁體中文, 日本語); Interface Scale 100 / 115 / 130 % (and the line about Windows' text size); When Reopened; Updates; Reset All Layout | [Mac HIG §6.5] |
| Recipes | the iPad's recipe list; each recipe's Format, Size, Colour, Quality, Folder, Name, If it exists. Today's formats are Win-Qt's: JPEG 8-bit, PNG 8 / 16-bit, TIFF 16-bit, all sRGB | [iPad W-G1] [Win-Qt: FrameOutput] |
| Library | where new catalogs go (default `Pictures\SpektraLab`); Capture One: Refresh on Open | [proposal] |
| Rendering | Fast stock preview (the cards' small renders, §8.6). There is no preview size: the Windows host renders the whole frame (§7) | [Win-Qt] [proposal] |
| **Engine** | the graphics device and backend (from `capabilities`); the display path (*sRGB · 8-bit*); **Not on Windows yet** (§3.8) | [Win-Qt] [proposal] |
| Diagnostics | the log folder, *Show Logs in File Explorer*, *Make a Diagnostic Bundle…*; the edit store's folder | [Mac HIG] [Win-Qt: EditStore] |

The Mac's Memory and Agents panes are not on Windows. The Win-Qt host has no memory cache page and no agent CLI
(§8).

### 6.6 Export: a ContentDialog with the proof

**Ctrl+E** opens the **Export dialog** for the open frame, or for the picked frames in the Library.
- **What it is:** a ContentDialog, centred over a smoke layer, 800 × 560, 8 epx corners.
  - Why not the Mac's sheet: Windows has no sheet.
  - Microsoft: dialogs "should be reserved for situations where you want the user to drop everything", and export is
    one. There can be "only one ContentDialog open per window at a time" **[Microsoft: dialogs]**.
- **The proof at the left:** the frame as it will be written, with its size and colour.
- **The recipe at the right:** recipe chips, Format, Size, Colour, Quality, Folder, Name, If it exists.
- **Buttons:** **Export** at the left and **Cancel** at the right.
  - Microsoft: "The "do it" action button(s) should appear as the leftmost buttons. The safe, nondestructive action
    should appear as the rightmost button."
  - Enter is Export, set explicitly ("By default, no default button is set"). Esc is Cancel.
- **What it writes today** (Win-Qt's `FrameOutput`):
  - JPEG 8-bit (with quality), PNG 8 or 16-bit, TIFF 16-bit;
  - sRGB with the bundled ICC profile;
  - full size or a long edge of 3840 / 2560 / 1920 / 1080;
  - **never overwriting:** *If it exists* is **Skip** (a batch skips, a single export refuses).
  - The Colour row shows *sRGB* without a menu until the exporter has more. Display P3, Adobe RGB, ProPhoto and
    Rec. 2020 appear when `FrameOutput` writes them, and HEIF when it exists (§8.8).
- **Where to:** *Beside the original* (Win-Qt's save dialog starts there), *Pictures\SpektraLab*, or *Ask each time*,
  which opens the system's Save dialog, as Win-Qt does today.
- **After Export:**
  - one frame: the dialog closes; the status line says *Exporting _DSC0061*, then *Exported*.
  - a batch: the dialog closes. The toolbar's Export wears a ring and the count (*3 of 12*: the worker reports each
    frame, `batchProgress` / `batchTotal`). A click gives a flyout with the file in hand, a bar of done frames, and
    **Stop after this frame**: Win-Qt cancels between files. **The taskbar button shows the same fraction** (Windows'
    taskbar progress) **[proposal]**.
  - The editor is look-only while a batch runs **[Win-Qt: batch export locks edits and history]**.
- `Main.qml`'s export `Popup` (its format, quality and size rows, and its two buttons) and its "导出所选 N 张"
  become this dialog.

### 6.7–6.9 Copy and Paste Settings, Compare and the Original, Crop

As the Mac HIG's §6.7–6.9, with Windows keys:
- **Copy and Paste Settings:**
  - Ctrl+Shift+C copies with the last groups; Ctrl+Alt+Shift+C (or ··· › Copy Settings…) opens the iPad's Copy
    Settings flyout; Ctrl+Shift+V pastes, or **Paste to N** for the picked frames.
  - The groups leave out what §3.8 gates.
  - **Win-Qt's rule stays:** pasting never moves another frame's crop unless *Crop* is ticked ("各自保留裁切").
    Pasting is undoable on each frame.
- **The Original:**
  - hold Space or \\, or press and hold the toolbar's *Original*; a short click latches it.
  - Bypass Adjustments is Ctrl+Shift+B.
- **Crop:**
  - C, Enter keeps, Esc cancels. **Shift** while dragging a corner keeps the ratio.
  - **Ctrl-drag** on the picture draws a straighten line (the Mac's ⌘-drag).
  - The straightened picture turns live on screen, and the 16-bit straighten commits on release, as Win-Qt's does.

---

## 7. Rendering states, as the user sees them

**The Windows worker, unchanged** **[Win-Qt: PreviewController.cpp, preview_host.hpp, README]**:
- one serial thread owns the `PreviewHost` and its engine;
- jobs are *init*, *open* (decode, develop and display in one transactional call), *render*, *export* and
  *batch-export*;
- every job has a generation number, and a reply from a retired generation never reaches the screen.

These are its states, in V5's words.

| when (Win-Qt) | status line (toolbar) | the picture | source |
|---|---|---|---|
| the engine starts (`init`; today "正在启动渲染引擎…") | *Starting the engine* | the Library and the filmstrip work; the rails wait | [Win-Qt] |
| the engine cannot start (no Vulkan device, a failed startup gate) | *Engine stopped* in danger red | a card on the picture: *The engine cannot start* · the reason · **Try Again** · **Show Details** (PC-E13). Export is dimmed; the Library still opens | [Win-Qt: init error]; Try Again re-creates the worker [proposal] |
| a frame opens (`open`, "正在解码并渲染 RAW…") | *Developing · Porta 400* | **the RAW's embedded preview**, with the capsule *Embedded preview*, until the print lands; Export dimmed. The open is one call that decodes and develops, so the line does not claim a decode step it cannot see | [Win-Qt: open_raw]; the embedded preview is [proposal] |
| a frame with a stored print restores | *Developed · Porta 400 · Porta Enduro* once the open lands | the print | [Win-Qt: EditStore] |
| an edit, after **180 ms** with no further change (`auto_apply_`) | film side: *Developing · Gold 200*; print side: *Printing · Yellow +0.10* (the host asks the engine for a reprint for print-side edits) | **the last picture stays** until the new one lands | [Win-Qt: PreviewController 180 ms; preview_host "Print-side edits request spk_reprint"] |
| edits during a render | unchanged | the render that was running finishes but is **not shown** (it is superseded); the newest settings render next, after 180 ms. The controls never jump back | [Win-Qt: `settings_revision_`, "superseded results never replace the displayed frame or newer controls"] |
| longer than a second | the elapsed time joins: *Developing · Gold 200 · 1.4 s* | | [proposal]; Win-Qt reports the time only at the end ("渲染完成 1.42 秒") |
| done, with edits | *Edited · Tone · Curve · Enlarger* (`+n` past the room) | | [iPad] |
| an Adjust move (Layer 2) | unchanged: it is a live display pass, not a worker job | live | [Mac HIG §7]; Layer 2 is new on Windows (§3.7) |
| a render fails | the status line returns to the shown print's words | **the last print stays**; the controls return to its values; an InfoBar at the picture's top: *Could not develop* · the reason · **Try Again** (PC-E12) | [Win-Qt: "A failed current render retains the displayed frame and restores its controls; a retry is available"]; the InfoBar is Fluent's |
| a RAW cannot be opened (Nikon HE, for example) | *Cannot open DSC_0101.NEF* · the reason | the previous frame and its session stay usable; the frame's tile says *Cannot read* | [Win-Qt: "A failed NEF open must leave the previous ARW and its session usable"] |
| a file dialog is open | unchanged | pending edits wait; nothing renders until it closes | [Win-Qt: `setDialogOpen`] |
| exporting one frame | *Exporting _DSC0061* | the shown frame is what is written, even if a newer edit is pending; the pending edit renders after | [Win-Qt] |
| a batch | *Exporting 3 of 12 · JPEG · sRGB* | look-only; history locked | [Win-Qt] |
| closing during work | *Closing after this develop* | the window waits for the current job | [Win-Qt: `closePending`] |
| an edit could not be saved | *Not saved* · the reason, in danger red | | [Win-Qt: `persistenceWarning`] |

**Rules:**
- **No progress bar on the picture.** The worker has no fraction for a develop. The accent dot and the elapsed time
  stand for it **[Mac HIG §7]**. A batch has a real fraction (frames done of frames), so a batch shows one: in the
  flyout and on the taskbar.
- **No spinner on the picture and no *FULL* badge.**
  - Win-Qt's centred `BusyIndicator` goes; the status line carries the state.
  - Its *FULL* badge goes too: **every Windows render is the whole frame**. The host returns full-size RGBA16 and a
    full-size 8-bit display copy (`preview_host.hpp`).
  - So there is no *Preview* badge, no *Full size* badge and nothing to wait for at 100 % (PC-E4).
  - A badge shows only while the picture is not what the controls say **[iPad]**.
- **A frame develops when it is opened.** Win-Qt already does this: there is no Process button **[Win-Qt]**. Two host
  changes, both [proposal]:
  - **a 400 ms rest before an open**, as the Mac's. Stepping through a folder with ← → then starts nothing until you
    stop. An open cannot be cancelled once begun ("cannot retarget an in-flight open"), so the rest matters more here
    than on the Mac.
  - **the newest asked frame wins.** Today the filmstrip is disabled while the worker is busy (`canBrowse`). Instead,
    the filmstrip moves at once and the white frame goes to the frame asked for. One *pending open* slot holds the
    newest request, which the worker takes next; any frame skipped in between is never opened. The worker and the
    host do not change.
- **The picture is shown as sRGB, 8-bit.** Win-Qt says a monitor's ICC profile is not applied yet. Settings › Engine
  says *sRGB · 8-bit*. Nothing claims a wide gamut it does not show.

**Not carried:**
- from the phone: its scheduler, the device policy, preview tiers, card cadence, thermal steps;
- from the Mac: `RenderScheduler`, its 220 ms debounce and 40 ms reprint, its preview size, its *Low memory* badge and
  *Render service stopped*. The Windows host is in the process, so there is no service to restart.

---

## 8. Out of scope on Windows, and open for the owner

### 8.1 Out of scope

| | why |
|---|---|
| Shoot, the camera | as on the Mac |
| the Mac's Agent CLI and MCP, its Memory pane | not in Win-Qt; nothing on screen asks for them |
| right-to-left layouts | none of the four languages; Microsoft's caption buttons would move to the left |
| Windows 10's Fluent look | the app runs on Windows 10 with the same layout; the glyphs fall back to the bundled SVGs (§2) |
| ink, pressure | §6.3 |

### 8.2 Open for the owner: one recommendation each

1. **Distribution.** *Recommendation:* the **Microsoft Store as MSIX**, and the same MSIX listed on **winget**. Keep
   the zip for testers.
   - The Store signs the package. That avoids buying a code-signing certificate, and SmartScreen's warning on an
     unsigned installer.
   - The Store also updates it.
   - Microsoft: "MSIX is the modern Windows app packaging format"; WinGet is "a comprehensive package manager
     solution"; the Store also takes "MSI/EXE" apps **[Microsoft: MSIX, WinGet, Store]**.
   - The package must carry Win-Qt's whole `app/` folder: the Qt DLLs, QML plugins, resources and notices
     (`windows_UI/README.md`). It also writes the file associations for `.spkcatalog` and `.spksession` (§4).
   - *Cost to you:* settle the GPL question for the Store first, as the Mac HIG asks for the App Store, and check the
     Store's current registration terms.
2. **ARM64.** *Recommendation:* x64 only in 2.0. Then measure on one Snapdragon X laptop:
   - first the x64 build under emulation;
   - then a native ARM64 build once the engine's Vulkan startup gate passes there.

   Microsoft says users "will want and need Arm-native Windows apps" **[Microsoft: Windows on Arm]**. The risks are
   the Vulkan driver and the MinGW toolchain (Win-Qt builds with Qt's MinGW 13.1, x64), not the UI.
3. **Updates.** *Recommendation:* the Store's updates if (1) is taken. Otherwise the Mac's: a manual Help › Check for
   Updates…, one anonymous request only when asked, and no automatic check in 2.0.
4. **The Library on Windows.** *Recommendation:* build `spklib-host` for Windows x64 from its own repository (MIT,
   `SpektraLab_library`). Until then, ship the Library with **folder sources only**:
   - the source menu lists what the helper offers, so catalogs and Capture One appear when it exists;
   - a folder source needs only Win-Qt's file list and `EditStore`.
5. **One Windows front end.** The `Windows_Linux` branch has two: `windows_UI/` (Qt Quick, this file's frame) and
   `desktop/` (Tauri and web, with its own wide-gamut export work, e8978fa1). *Recommendation:* `windows_UI/` is the
   app, as you asked. `desktop/` is kept only as a reference for its ProPhoto and Display P3 output, which
   `FrameOutput` should take over.
6. **The stock cards' pictures.** Each card is a render through its stock, and the Windows worker is serial. Rendering
   27 small frames on it would hold up every edit. *Recommendation:*
   - a **second `PreviewHost` on its own thread**, at a small size, paused while the main worker is busy;
   - the engine reports `concurrent: true`;
   - the cost is GPU memory: measure it on an 8 GB laptop.

   The other way is the stock's swatch instead of a render, which is what V5 draws for a stock with no render.
7. **Develop on open: the 400 ms rest and "the newest frame wins"** (§7). *Recommendation:* yes, both. They are host
   changes in `PreviewController`; the worker is untouched.
8. **Export colours and HEIF.** *Recommendation:* 2.0 for Windows exports sRGB, as Win-Qt does. Display P3 and
   ProPhoto follow when `FrameOutput` writes them correctly tagged. HEIF waits until the desktop's exporter has it on
   both systems.
9. **The words "Edit".** As the Mac HIG's §8.6: keep *Library | Edit* and the rail's *Edit*.

Also mine and open, though not product decisions:
- the 1080p-at-125 % drawing size and the 500 epx minimum (§1);
- the title-bar menu bar (§6.1);
- F7 / F8 / Ctrl+Alt+1 / Ctrl+Alt+2 (§6.2);
- type at Microsoft's minimums (§2);
- no Mica (§2);
- the embedded preview while a frame opens (§7);
- the pen detent tap (§3.1–3.6);
- the taskbar progress (§6.6).

---

## 9. Accessibility and languages

### 9.1 Accessibility

- **Narrator (UI Automation)** **[Microsoft: accessibility overview, checklist]**:
  - Qt Quick on Windows reaches UI Automation through its accessibility bridge. Every control sets `Accessible.name`
    and `Accessible.role`. Microsoft: "Set the accessible name (required) and description (optional)".
  - The names are the Mac HIG's VoiceOver list, word for word:
    - *Format, expanded*;
    - *Porta 400, selected*;
    - *Tone, edited*;
    - *Film Exposure, plus 0.3 EV*;
    - *7.0 stops held, 99.6 % within*.
  - A section head is a button with an expanded state.
  - A tile is a toggle button.
  - A slider or ruler is a slider with its value and unit.
  - The status line is a live region, polite.
- **Keyboard only:**
  - every command is in the menu bar, with an access key;
  - F6 moves between panes and Tab within one;
  - arrows move inside a card grid, a tile row and the filmstrip;
  - Space and Enter choose;
  - every focusable piece shows Fluent's focus rectangle (a 2 epx outer line, white on our dark ground, and a 1 epx
    inner one);
  - "Test the default tab index order" **[Microsoft: checklist]**.
- **Contrast themes** (Settings › Accessibility › Contrast themes: Aquatic, Desert, Dusk, Night sky)
  **[Microsoft: contrast themes]**:
  - **The app follows the theme's system colours:**

    | in the app | the theme's colour |
    |---|---|
    | grounds | Window |
    | text and dim text | WindowText. Microsoft: "Do not use SystemColorGrayTextColor for secondary body text" |
    | disabled items | GrayText |
    | the accent, a selection and a focus | Highlight and HighlightText |
    | buttons | ButtonFace and ButtonText |
    | walls and rules | WindowText |

  - Hotlight is for links only, and we have none.
  - "Do not hard-code colors in HighContrast."
  - **The picture, the cards' renders and the meter's histogram are never recoloured.** They are the photograph.
  - The theme is read through `SPI_GETHIGHCONTRAST` (or Qt's own contrast hint where the Qt version has one) and
    followed live.
  - Without a contrast theme, the Mac's *Increase Contrast* values are not used: Windows has no such setting.
- **Animation effects off** (Settings › Accessibility › Visual effects): sections fade instead of sliding; the switch's
  thumb jumps; the filmstrip does not glide **[Mac HIG §9.1 Reduce Motion]**.
- **Transparency effects off:** nothing changes. There is no glass.
- **Text size:** Interface Scale follows Windows' text size up to 130 %. Menus, dialogs and Settings follow it fully
  (§2).
- **Contrast of our own colours:** the Mac HIG's measurement holds. Dim `#898989` on the card is 3.9:1, under
  Microsoft's "at least 4.5:1". So dim text on a card is only for values at rest, which also show their rest tick.
- **Colour is never the only sign:**
  - an edited tile has its dot and *edited* in its name;
  - *Offline* is a word as well as red.

  Microsoft: "Ensure that your UI doesn't use color as the only way to convey information".
- **Test with Narrator and Accessibility Insights** **[Microsoft: accessibility testing]**.

### 9.2 Languages

- **Win-Qt today:** its interface strings are Simplified Chinese, written into `Main.qml` and `PreviewController.cpp`.
  The status words ("正在更新预览…" and others) are among them.
- **The Windows app ships the four:** English, 简体中文, 繁體中文 and 日本語 **[proposal]**.
  - Every string goes through Qt's `qsTr()` / `tr()` into `.ts` files.
  - The iOS app's translations are the reference for the same words, as on the Mac.
  - Language: System by default; Settings › General changes it at once (Qt reloads its translators).
- **Fonts per language** as §2. Access keys in CJK follow the word in parentheses (§6.1).
- **Text fit:**
  - every label fits a 280 epx rail at 100 % in all four languages, at 12 epx Regular or larger;
  - a section's summary drops trailing parts rather than truncate;
  - the menu bar's six titles take about 280 epx in English, 360 in 简体中文 and 440 in 日本語 (estimated, with "(F)").
    A 500 epx window's title bar has 326 epx for them, after the icon and the caption buttons.
  - **When the titles do not fit, the menu bar folds into one menu button** at the icon's right. It opens the same six
    menus as submenus, and Alt or F10 still opens it. In English that never happens above the 500 epx minimum. It
    happens under about 540 epx in 简体中文 and 620 in 日本語 **[proposal]**.
- **Not drawn:** the pages in 简体中文, 繁體中文 and 日本語.

---

## 10. What changes from the Mac, and what never changes

| | Mac | Windows |
|---|---|---|
| units, drawing size | points; the 14-inch at 1512 × 945 | **epx**; 1920 × 1080 at 125 %, maximised: 1536 × 816 |
| window controls | traffic lights at the top left; the left rail's head keeps 80 pt clear | **caption buttons at the top right**, in a 32 epx title bar; nothing reserved |
| menus | the system's menu bar, with the app menu and a Window menu | **a menu bar in the title bar**: File Edit View Frame Go Help; no app menu, no Window menu; access keys |
| keys | ⌘ ⌥ ⇧ ⌃ | Ctrl, Alt, Shift; F7 / F8 rails, F11 full screen, F6 panes, F5 refresh, F1 help; Ctrl for fine control |
| full screen | the green button, ⌃⌘F | F11 |
| narrow windows | minimum 1000 × 680; the left rail folds under 1180 | **minimum 500 × 540**; the left rail folds under 1180, both under 760; the Navigator folds under 720 tall |
| Snap / split view | — | Snap layouts from the maximise button (`HTMAXBUTTON`) |
| type | SF, 13 pt labels, 10 pt least | **Segoe UI Variable**, 14 epx Semibold labels, **12 epx least**; YaHei UI, JhengHei UI, Yu Gothic UI |
| symbols | SF Symbols | **Segoe Fluent Icons**, Fluent System Icons where it has none |
| system shapes | Apple's | 8 epx windows, flyouts and dialogs; 4 epx buttons; square when maximised |
| menus, popovers | the system's, with vibrancy | opaque flyouts and menus, no beak; no Acrylic |
| context menu | a menu | a command bar flyout |
| Export | a sheet | a ContentDialog: Export left, Cancel right |
| Settings | the app menu, a pane toolbar | File (and ··· last), a pane list at the left |
| Finder | Show in Finder | **Show in File Explorer**; drag to File Explorer; the Recycle Bin |
| the engine and its states | `RenderScheduler`, a 2560 preview, the full size after a rest | **one serial worker**, 180 ms settle, the whole frame every render, superseded renders never shown |
| what the engine lacks | — | Film Edge, Date Back, Scene Placement, DI and the Half-Frame Pair are **absent until ported** (§3.8) |
| detent feedback | the trackpad's tap | none; a pen's haptic tap where one exists |
| Actual Size | `CGDisplayScreenSize` | `DisplayInformation` raw DPI; none at 0, null or duplicated |
| touch | — | 40 × 40 epx hit areas; press and hold for menus; check boxes on tiles |
| Increase Contrast | the Mac's values | contrast themes' system colours |
| VoiceOver | — | Narrator, through UI Automation |
| export formats today | HEIF, JPEG, PNG, TIFF; five colours | JPEG, PNG, TIFF; sRGB (until `FrameOutput` has more) |
| a folder's edits | beside the frames | in the app's store; nothing written beside the RAW |

**What never changes:**
- the words: stock names, V5's words rule, *Developed* / *Developing* / *Printing* / *Edited*;
- every control's range, rest, detent and step;
- the order of the iPad's pieces inside each section;
- the accent rule (actions and state) and the white selection;
- the paper rules: a slide is never tied to a paper. Win-Qt already scans slides directly and disables paper for them;
- two rails with Develop | Edit both on screen; Library | Edit as a workspace;
- no glass on the panels;
- the frame shown whole on black;
- a picture never labelled as something it is not: no *Full size* that is not, and no wide gamut that is not shown;
- a feature that does nothing is never on screen.

---

## 11. The pages

[INDEX.md](INDEX.md) lists every page by id, with the Mac page each one answers. `design/src/gen_windows.py` writes
them:

```
python3 design/src/gen_windows.py              # every page, the boards, the contact sheet, INDEX.md
python3 design/src/gen_windows.py --preview    # and the flattened previews (macOS: Quick Look + sips)
python3 design/src/gen_windows.py PC-E1 PC-L1  # some pages only, by id
```

**The ids** start `PC-` so they never meet the iPad's `W-` ids:

| ids | pages |
|---|---|
| PC-E | the editor |
| PC-N | snapped and scaled windows |
| PC-L | the Library |
| PC-T, PC-K | the light table and contact sheets |
| PC-O | export |
| PC-G | Settings |
| PC-X | actions |

**What there is:**
- 34 pages: the Mac's 30, plus four that only Windows needs. PC-E12 is a failed develop, PC-E13 an engine that cannot
  start, PC-N3 1080p at 150 %, and PC-G3 Settings › Engine with the gates.
- Three boards: `board_window.svg` (the rule, the geometry, Snap), `board_menus.svg` (the menu bar, every menu open,
  access keys underlined) and `board_keys.svg` (keys, mouse, touch, pen, and the keys Windows keeps).
- Flattened: `preview_windows.jpg` (every page), `preview_window.jpg`, `preview_menus.jpg`, `preview_keys.jpg`.

**How the generator works.** It imports `gen_mac.py` and replaces its chrome:
- the window, the title bar and the caption buttons;
- the menus and flyouts;
- the toolbar and the glyphs;
- the type mapping (§2);
- the Info rail, the light table and Settings.

Everything inside the rails is the Mac generator's own drawing, so the two sets cannot drift.

**Pictures**, as the Mac set:
- the editor draws V5's street frame (`src/v4/*.jpg`);
- the Library, filmstrip and light table draw the owner's frames (`src/ipad/*.jpg`);
- no new photos, and no people;
- the Capture One pages show the owner's frames, not a real Capture One catalog's.

**Build checks:**
- every page parses as XML;
- a status line or title too long for the toolbar fails the build;
- a Mac word on a Windows page (⌘, ⌥, *Finder*) fails the build.

**Drawn with Segoe UI Variable named first.** The previews are flattened on a Mac, where Segoe is not installed, so
they show the Mac's system font. Widths are estimated with the Mac's metrics. Segoe UI Variable is within a few per
cent; this was not measured.

**Not drawn yet:**
- the pages in the three other languages;
- a contrast theme;
- touch-sized hit areas (they are not drawn by design);
- the Library's List view;
- Settings' Library, Rendering and Diagnostics panes;
- Presets' manage dialog;
- the Half-Frame Pair (gated);
- Film Edge's own flow;
- full screen (F11);
- the taskbar's progress;
- a restored (8 epx) editor window;
- the Library on Windows with folder sources only (§8.4).

---

## 12. Sources

**Microsoft, read 2026-10-23.** Each Learn page shows "Last updated on" a date, which it builds from a UTC time and
shows in the reader's time zone. The dates below are as shown when read. Where the page's `ms.date` metadata differs,
it follows in brackets.

| page | URL (learn.microsoft.com/en-us/… unless full) | date |
|---|---|---|
| Screen sizes and breakpoints for responsive design | windows/apps/design/layout/screen-sizes-and-breakpoints-for-responsive-design | 07/13/2026 |
| Content layout and spacing | windows/apps/design/basics/content-basics (the old …/style/spacing redirects here) | 10/14/2026 (2026-10-13) |
| Windows app title bar | windows/apps/design/basics/titlebar-design | 07/31/2024 |
| Title bar customization | windows/apps/develop/title-bar | 10/13/2026 |
| Support snap layouts for desktop apps on Windows 11 | windows/apps/desktop/modernize/ui/apply-snap-layout-menu | 06/16/2026 |
| Menu flyout and menu bar | windows/apps/develop/ui/controls/menus | 10/14/2026 (2026-10-13) |
| Command bar | windows/apps/develop/ui/controls/command-bar | 10/13/2026 |
| Commanding basics | windows/apps/design/basics/commanding-basics | 08/01/2022 (2020-09-24) |
| Keyboard accelerators | windows/apps/develop/input/keyboard-accelerators | 08/28/2026 |
| Access keys design guidelines | windows/apps/develop/input/access-keys | 12/02/2025 (2024-06-11) |
| Keyboard shortcuts in Windows | support.microsoft.com/en-us/accessibility/windows/keyboard-shortcuts-in-windows | no date shown (metadata 09/02/2026) |
| Menus and context menus | windows/apps/develop/ui/controls/menus-and-context-menus | 10/13/2026 |
| Command bar flyout | windows/apps/develop/ui/controls/command-bar-flyout | 08/28/2026 |
| Dialog controls | windows/apps/develop/ui/controls/dialogs-and-flyouts/dialogs | 07/15/2026 |
| Dialogs and flyouts | windows/apps/develop/ui/controls/dialogs-and-flyouts/ | 10/14/2026 (2026-10-13) |
| Flyout controls | windows/apps/develop/ui/controls/dialogs-and-flyouts/flyouts | 02/25/2026 (2025-02-26) |
| Typography in Windows | windows/apps/design/signature-experiences/typography | 04/14/2026 (2021-06-24) |
| International fonts | windows/apps/design/globalizing/loc-international-fonts | 06/23/2023 (2020-09-24) |
| Segoe Fluent Icons font | windows/apps/design/iconography/segoe-fluent-icons-font | 10/14/2026 (2026-10-13) |
| Icons in Windows apps | windows/apps/develop/ui/controls/icons | 09/19/2026 |
| Materials used in Windows apps | windows/apps/design/signature-experiences/materials | 11/05/2024 (2024-09-16) |
| Mica material | windows/apps/design/style/mica | 07/22/2026 |
| Acrylic material | windows/apps/design/style/acrylic | 10/02/2026 |
| Contrast themes | windows/apps/design/accessibility/high-contrast-themes | 08/29/2026 |
| Accessibility overview | windows/apps/design/accessibility/accessibility-overview | 08/21/2026 |
| Accessibility checklist | windows/apps/design/accessibility/accessibility-checklist | 07/22/2026 |
| Accessibility testing | windows/apps/design/accessibility/accessibility-testing | 07/22/2026 |
| Targeting | windows/apps/develop/input/guidelines-for-targeting | 09/27/2026 |
| Touch interactions | windows/apps/develop/input/touch-interactions | 12/02/2025 (2024-01-18) |
| Pen interactions and Windows Ink in Windows apps | windows/uwp/ui-input/pen-and-stylus-interactions | 03/04/2026 (2021-07-19) |
| Text scaling | windows/apps/develop/input/text-scaling | 03/05/2026 (2022-05-03) |
| Drag and drop | windows/apps/develop/data/drag-and-drop | 09/27/2026 |
| DisplayInformation: RawDpiX, RawDpiY, DiagonalSizeInInches, RawPixelsPerViewPixel, ScreenWidthInRawPixels | uwp/api/windows.graphics.display.displayinformation.* | no date shown (2017-02-08) |
| Guidelines for app settings | windows/apps/design/app-settings/guidelines-for-app-settings | 04/15/2026 (2026-04-08) |
| What is MSIX? | windows/msix/overview | 10/12/2026 (2026-09-30) |
| WinGet | windows/package-manager/ | 12/12/2025 (2025-02-13) |
| Create an app submission for your MSI/EXE app | windows/apps/publish/publish-your-app/msi/create-app-submission | 08/24/2026 (2022-10-30) |
| Windows on Arm documentation | windows/arm/overview | 06/25/2026 |
| Add support Arm devices to your Windows app | windows/arm/add-arm-support | 11/07/2025 (2025-11-06) |
| Geometry in Windows 11 | windows/apps/design/signature-experiences/geometry | 02/19/2026 (2021-06-24) |
| Layering and elevation in Windows | windows/apps/design/signature-experiences/layering | 02/19/2026 (2021-06-24) |
| Fluent 2: Layout, Typography, Iconography, Elevation, Shapes | fluent2.microsoft.design/… | no date shown |

**What the pages do not have, or where they were not found:**
- No page gives a caption button's width, a command bar's height or a ContentDialog's size limits. The numbers here
  for those are mine.
- The accelerator table lists neither Ctrl+Shift+Z nor F11. F11 is File Explorer's, on the support page.
- No Microsoft design page uses "Show in File Explorer" or "Open file location"; the wording here is mine.
- The pen page does not mention a barrel button.
- Segoe Fluent Icons has no Compare, Flip, Pictures or OpenFolder glyph.
- There is no standalone Segoe UI Variable page or font-fallback page; the font guidance is on Typography and
  International fonts.
- **These URLs do not exist (404):**
  - …/design/develop/title-bar
  - …/design/desktop/snap-layouts
  - …/design/style/fonts
  - …/design/style/segoe-ui-variable
  - …/design/style/segoe-ui-variable-font
  - …/design/globalizing/font-fallback
  - …/design/style/elevation
  - …/design/style/control-size-and-density
  - …/get-started/windows-on-arm
  - …/publish/publish-your-app/msix-vs-exe
  - …/distribute-through-store/how-to-publish-your-win32-app
  - …/publish/publish-your-app/msi/publish-your-app
- …/publish-your-app/msi/overview redirects to the Store's general publishing page.
- Where this file quotes Microsoft, the quote is the page's.

**Other, read 2026-10-23:** StatCounter Global Stats, *Desktop Screen Resolution Stats Worldwide*, September 2026
(gs.statcounter.com/screen-resolution-stats/desktop/worldwide): 1920 × 1080 28.07 %, 1536 × 864 10 %, 1366 × 768
7.95 %, 1280 × 720 4.71 %.

**The desktop repository, read 2026-10-23 (read only)** at `origin/Windows_Linux` b68ed6c7 (also the worktree
`windows-film-edge-cpp`, same commit):
- `windows_UI/README.md`, `DESIGN_ALIGNMENT.md`;
- `windows_UI/qml/Main.qml`, `Theme.qml`, `Section.qml`, `ActionButton.qml`;
- `windows_UI/src/PreviewController.{hpp,cpp}`, `FrameCanvas.{hpp,cpp}`, `FrameOutput.hpp`, `EditStore`, `main.cpp`;
- `engine/src/desktop/preview_host.hpp`;
- `engine/src/pipeline/engine.cpp` (`capabilities_json`);
- `engine/PORT_PLAN.md`;
- `desktop/NOTES.md` and commit e8978fa1 (the Tauri front end's wide-gamut work);
- `API-SPEC-library-helper.md` and `vendor/spklib/` on `v2-mac`.

**This repository:** `design/mac/README.md`, `INDEX.md` and `gen_mac.py`; `design/ipad/README.md` §1–3.
