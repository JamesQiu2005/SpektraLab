# Windows Qt Quick editor

This is a native Qt Quick/C++ application using the existing synchronous
`spk_desktop_host` and the engine's Vulkan backend. There is no Python, Node,
browser or subprocess renderer at runtime. The interface is the macOS app's
(below); the few controls whose feature is not on Windows keep their place
greyed and say why on hover, rather than being omitted. What it adds
relative to upstream's starting point is summarised in
[CHANGES-WINDOWS.md](CHANGES-WINDOWS.md); the comparison with the Mac, row by
row, is [DESIGN_ALIGNMENT.md](DESIGN_ALIGNMENT.md).

In brief: RAW (LibRaw 0.22.2), TIFF, JPEG and PNG input; a library with the
Mac's filmstrip and Settings Clipboard; the Pre-Dev rail (white balance,
Process, Latitude, Scene Placement, Tone Mask, film format and effects,
enlarger); Film Edge and Date Back; half-frame pairs; the Post-Dev grade;
canvas tools (zoom ladder, histogram, Original, before/after, crop grips);
the Mac's export page with its recipes and colour spaces; a ProPhoto RGB
working space; display colour management per monitor with a soft proof and
gamut warning; Settings and About windows; English interface text through a
JSON Localizer.

## Build (MSVC 2022)

The validated toolchain is Visual Studio 2022 17.14 (MSVC 19.44.35229,
toolset 14.44.35207) with the CMake 3.31.6 and Ninja that ship with it, Qt
6.11.3 `msvc2022_64`, on Windows 11 with an NVIDIA RTX 3070.

**Prerequisites.**

- Visual Studio 2022 with the *Desktop development with C++* workload. The
  script imports the x64 environment from `VsDevCmd.bat` into its own process
  and uses Visual Studio's bundled CMake (`CommonExtensions/Microsoft/CMake`)
  and Ninja, not whichever is first on `PATH`. If `VsDevCmd.bat` cannot find
  `vswhere.exe`, put `C:\Program Files (x86)\Microsoft Visual Studio\Installer`
  on that shell's `PATH` first.
- A GPU driver with Vulkan 1.0. `vulkan-1.dll` comes from the driver and is
  loaded at run time through volk (`engine/third_party/volk`), so no Vulkan
  SDK or import library is needed.
- Windows PowerShell 5.1.

**Dependencies.** Everything else is local, in one folder
(`-DependencyDirectory`, default `../deps` beside the checkout); the script
checks each before it configures:

```
deps/
  qt-6.11.3-msvc2022_64/   official Qt 6.11.3 msvc2022_64 archives (qtbase,
                           qtdeclarative, qtshadertools, qtsvg), extracted
  qt-6.11.3-licenses/      the licence texts pinned in dependencies/qt-licenses.json
                           (<module>/<file>; optional -- the build warns without them)
  Vulkan-Headers/          KhronosGroup/Vulkan-Headers, tag vulkan-sdk-1.4.341.0
  glslang-16.6.0/          KhronosGroup/glslang 16.6.0 Windows release (bin/glslang.exe)
  LibRaw-0.22.2/           engine/setup-libraw.ps1 (pinned, SHA-256 checked)
  tex-gyre-heros/          the CTAN faces; already copied into
                           engine/resources_portable/fonts, so the build reads the copy
```

No script fetches the MSVC Qt archives yet (`setup-qt.ps1` fetches the MinGW
SDK, below, and the same licence texts); `dependencies/qt-packages.json` pins
the MinGW archives only. Vulkan headers and glslang are build inputs only:
neither is shipped.

**Build, test and package.** From any directory:

```powershell
& <checkout>\windows_UI\build-msvc.ps1 -DependencyDirectory <deps> `
    -BuildDirectory <build> -Jobs 6 -RunTests -Package
```

| Option | Effect |
|---|---|
| `-DependencyDirectory` | the folder above (default `../deps` beside the checkout) |
| `-BuildDirectory` | the CMake/Ninja tree (default `../build/msvc-<configuration>`) |
| `-VsDevCmd` | path to `VsDevCmd.bat` (the default is the development machine's; pass yours) |
| `-QtDirectory` | a Qt other than `<deps>/qt-6.11.3-msvc2022_64` |
| `-Configuration` | `Release` (default), `RelWithDebInfo` or `Debug` |
| `-RunTests` | build every target and run CTest; without it only `SpektraLabQt` is built |
| `-Package` | after a successful Release build and deploy (and the tests, with `-RunTests`), write the zip below |
| `-Jobs N` | Ninja's parallelism (0, the default, uses every core) |
| `-Fresh` | discard the existing CMake configuration |
| `-NoDeploy` | skip windeployqt, the runtime and the licence copies |
| `-KeepGoing` | Ninja `-k 0` |

The Visual Studio environment and `PATH` are restored when the script exits.
With `-RunTests`, `TEMP`/`TMP` point into `<build>/tmp` so every test's scratch
file stays in the build tree.

**The app folder.** `<build>/app` is self-contained for x64 Windows:
`SpektraLabQt.exe`, the Qt DLLs, plugins and QML that `windeployqt` chose
(plus `platforms/qoffscreen.dll` for `--self-test` and `--snapshot`), the MSVC
runtime DLLs from Visual Studio's redistributable folder, `resources/` (the
engine's baked data, SPIR-V kernels, spektrafilm's profiles beside the
black-and-white product profiles, the TeX Gyre Heros faces, `sRGB.icc`, the
Digital Intermediate's view LUTs) and `licenses/` (every notice:
[THIRD_PARTY.md](THIRD_PARTY.md) lists them). Keep the folder whole when moving
it. The Vulkan driver is the machine's own.

**The package.** `-Package` copies that folder into
`<build>/package/SpektraLab-Windows-<version>-x64/` and zips it to
`<build>/package/SpektraLab-Windows-<version>-x64.zip`, the version being the
About window's (`SPEKTRALAB_VERSION` in `CMakeLists.txt`). Left out:
`vc_redist.x64.exe` (the runtime DLLs are already beside the executable),
debug and link artefacts, test executables and anything personal (edit
records, folder orders, preferences and recipes, which live under the user's
`AppData`, never in `app/`). It refuses to package unless the executable, the
Qt and runtime DLLs, the platform plugin, the QML, the engine resources,
fonts, B&W profiles and the licence texts are there. The zip has one top
folder; unzip it anywhere and run `SpektraLabQt.exe`. It is a development
build, unsigned and without an installer. On 2026-10-16 (1.3.3) it was
51.6 MB and 1654 files, and ran from a fresh extraction
([CHANGES-WINDOWS.md](CHANGES-WINDOWS.md#packaging)).

**Tests.** `-RunTests` runs CTest (47 tests as of 2026-10-16: 18 for the
engine and its test DLL, 4 native RAW, 3 desktop host, 22 for the Qt editor;
the engine's are described in [engine/WINDOWS.md](../engine/WINDOWS.md)). To
rerun them without rebuilding, use Visual Studio's `ctest` (a Developer
PowerShell has it on `PATH`), with `TEMP`/`TMP` pointed into the build tree:

```powershell
ctest --test-dir <build> --output-on-failure
```

None needs a private RAW. `spk_qt_recipe_export` reads EXIF from one when
configured with `-DSPEKTRALAB_TEST_RAW=<file>`.

**The RAW gates** are not in CTest: each needs camera files and a new output
directory, and copies its inputs before opening them (a develop writes an edit
record). Any file LibRaw refuses serves as the rejected RAW -- a Nikon HE/HE*
NEF, or a non-RAW file named `.NEF`.

```powershell
$env:QT_QPA_PLATFORM = 'offscreen'; $env:QT_QUICK_BACKEND = 'software'
$env:QML_DISABLE_DISK_CACHE = '1'; $env:QSG_RHI_DISABLE_DISK_CACHE = '1'
$env:PATH = "<build>\app;$env:PATH"; $env:QT_PLUGIN_PATH = "<build>\app"
# The real executable: QML, controller and engine (output directory must be new)
Start-Process <build>\app\SpektraLabQt.exe -Wait -NoNewWindow -ArgumentList `
    '--open', 'C:\photos\supported.ARW', '--reject', 'C:\photos\rejected.NEF', `
    '--self-test', 'C:\validation\self-test'
# Library, editing and export workflows: <resources> <RAW> <rejected RAW> <new dir>
<build>\windows_UI\spk_qt_library_workflow_test.exe <build>\app\resources `
    C:\photos\supported.NEF C:\photos\rejected.NEF C:\validation\library
<build>\windows_UI\spk_qt_editing_workflow_test.exe <build>\app\resources `
    C:\photos\supported.NEF C:\photos\rejected.NEF C:\validation\editing
<build>\windows_UI\spk_qt_export_workflow_test.exe <build>\app\resources `
    C:\photos\supported.NEF C:\photos\rejected.NEF C:\validation\export
# Half-frame pairs: <resources> <RAW> <second RAW> <new dir>
<build>\windows_UI\spk_qt_pairs_workflow_test.exe <build>\app\resources `
    C:\photos\a.NEF C:\photos\b.NEF C:\validation\pairs
# Not a gate, a measurement: straighten and crop drags at full resolution,
# each step's time on the GUI thread and when the picture lands
<build>\windows_UI\spk_qt_geometry_bench.exe <build>\app\resources `
    C:\photos\supported.ARW C:\validation\geometry-bench
```

`SpektraLabQt.exe` is a GUI-subsystem executable, hence `Start-Process
-Wait`; it exits nonzero on failure and writes a JSON report and its captures.
What each gate checks is under [Validation](#validation).

### Build with MinGW (the first route, not re-validated)

The first Windows build used the official Qt 6.11.3 MinGW SDK with its
MinGW-w64 13.1 compiler (`build.ps1`, `setup-qt.ps1`). It has not been run
since the MSVC build replaced it, and later lanes were validated on MSVC only;
it is kept for reference. Do not link those Qt binaries with the earlier GCC
15 build of the engine.

```powershell
# From the repository root. The bootstrap uses only PowerShell and Windows
# bsdtar, downloads into ../deps and checks pinned SHA256 for every file.
./windows_UI/setup-qt.ps1 -DependencyDirectory ../deps
./windows_UI/build.ps1 -SourceDirectory . -BuildDirectory ./build/qt -RunTests
```

`dependencies/qt-packages.json` lists the exact official MinGW archives and
hashes; `dependencies/qt-licenses.json` each official licence text and hash.
`setup-qt.ps1 -VerifyOnly` checks the existing cache and tool versions without
network or extraction (the initial download is about 278 MB). It does not
install Vulkan headers, glslang, CMake or LibRaw. `build.ps1` also deploys the
MinGW runtime and its licences (`licenses/MinGW/`).

For a parent build, enable the native RAW and desktop host targets and call
`add_subdirectory(windows_UI)` after `add_subdirectory(engine)` (the top-level
`CMakeLists.txt` does, with `-DSPEKTRALAB_BUILD_QT=ON`). The macOS build is
untouched. Resources are synchronized on every build, including builds where
the executable itself does not need relinking; deployment is a build-script
step.

## The window

The window follows the macOS editor (`modern_UI/.../Windows/EditorWindow.swift`
and `screenshots/Screenshot_English.png`): the "Film and Print" rail, the
centre column (tool bar, canvas, filmstrip) and the "Parameters" rail with its
Pre-Dev / Post-Dev switch, flush and separated by hairlines. Both rails fold
from the tool bar's sidebar buttons and take a user width (drag the inner
edge; double-click returns it), the filmstrip folds from the tab on the
canvas's lower edge, and every section folds from its header. The design
system is ported from the Mac's `Theme.swift`: `qml/Theme.qml` (colours,
type, metrics), `qml/Icons.qml` (Segoe Fluent Icons / Segoe MDL2 Assets
glyphs; nothing bundled) and the controls in `qml/controls` -- `MacSection`,
`ParamRow`, `ScrubSlider` with its `ValueBox` (drag, wheel, click to type,
double-click to reset; one undo step per gesture), `CheckRow`, `PillDropdown`,
`PillSwitch`, `PillButton`, `IconButton`, `StockList`, `RailMenu`. Each file
says its API at the top.

The QML is one file per pane (`qml/left`, `qml/centre`, `qml/right`,
`qml/export`, `qml/shell`); `qml/Main.qml` holds the window, dialogs and
shortcuts and `qml/EditorState.qml` the state the panes share. The window has
no menu bar: a menu button leads the tool bar with the Mac's commands that
Windows carries out (Import, Export, Undo, Redo, Select All Photos, Sync
Settings, Reset This Photo's Settings, View, Settings, About, Exit), each with
its key.

Still greyed, with the reason on hover: Lens Correction (LibRaw has no lens
profiles), Extended Dynamic Range print profiles (no HDR output path), the
paper list's Digital group on the canvas (no Cineon view of the canvas yet;
the Digital Intermediate *export* works), and in Settings every Mac setting
without a Windows backend (below).

Slide film is scanned directly, matching the upstream macOS film-stage rule.
The host resolves this from each profile's `info.type`, including Provia 100F,
Velvia 100, Ektachrome 100 and Kodachrome 64. Paper and paper-brightness controls
are disabled for slides; their previous settings return with negative film.
The black-and-white films (Tri-X 400, T-Max 100, Neopan 100 Acros II, HP5 Plus
400) and the Multigrade IV RC paper are in the lists, deployed from
`engine/resources_product` beside spektrafilm's profiles, under the Mac's
stock rules.

## The library and the Settings Clipboard

**The library** (the Mac's `Filmstrip.swift`, `Library.swift`, `FrameOrder.swift`,
README "Select and sync photos"). Ctrl+O opens files, Ctrl+Shift+O (or the
menu's Open Folder) a folder: every photo in it -- not its subfolders -- in
Finder's order (numbers as numbers), and a folder or files dropped on the
canvas or the strip do the same. A TIFF, JPEG or PNG is decoded at the door
(`engine/src/desktop/raw_white_balance.hpp`): its ICC profile, else sRGB for an
8-bit file and linear ProPhoto for an untagged 16-bit/float TIFF, as the Mac's
`ImageDecoder` assumes, into the engine's scene-linear input; it has no camera
white balance or RAW decode to choose, and Photo Info says what it was read as.
Each thumbnail is the whole photograph with everything outside its crop under
a nearly opaque mask, turned and flipped as the canvas is
(`CropMaskedThumbnail.swift`); until a photo has been rendered it is the file's
own preview (a RAW's smallest embedded JPEG that covers the strip, not its
full-size one), read off the GUI thread by a quarter of the cores. A folder of
hundreds is listed in one go: the saved edits of its new files are read in
parallel and the strip is told once (measured: 300 photos listed in 0.26 s,
every preview in 3 s; a 403-file folder's snapshot 54 s before, 5.7 s after;
`spk_qt_library_workflow_test`'s large-folder block pins it). A plain click
opens a photo and selects it alone; Ctrl+click adds or removes a photo without
moving the open one, which cannot leave the selection; Left / Right step (not
while a text field has the keyboard, AGENTS.md trap 32). Dragging a thumbnail
along the strip moves it, and the order is kept for its folder (beside the
edits, `Order/<folder>-<hash>.order.json`) and laid over the listing next time,
a new file after its own neighbour. None of this moves while a batch export
runs (AGENTS.md trap 34). Only the current photo is fully decoded and
developed; small thumbnails are retained, not one full RAW/GPU session per
imported photo.

**The Settings Clipboard** (`SettingsClipboard.swift`, RFC-027; left rail,
folded by default): the seven groups -- Film & Paper, Exposure, White Balance,
Film Effects, Print Effects, Scene Placement, Masks (the Tone Mask, which this
build shows) -- choose what the next Copy (Ctrl+Shift+C) or Sync takes; the
line under them says what the clipboard holds. Paste (Ctrl+Shift+V) writes
exactly the held groups onto every selected photo (the open one live, as one
undo step; the others in their records, each with its own undo step), Sync to
N a fresh copy of the open photo's ticked groups onto the other selected
photos. Crop, Post-Dev, the decode mode, Film Edge and Date Back stay with each
photo; As Shot white balance stays the target's own camera's, and a Scene
Placement arrives as its pull-backs and is fitted again on the target. Paste
and Sync wait for a batch export. `PreviewController::setParameters` (and its
C++ form `setSettingValues`) applies several settings rows as one edit -- one
undo step, one render -- for Film Exposure's As Shot and Film Format's Reset,
All Effects On/Off and Reset Effect Strengths.

## Pre-Dev

The Parameters rail's first tab, after the Mac's `ParameterSections.swift`.
Every row is a desktop settings-table row (`engine/src/desktop/preview_host.hpp`)
sent to the engine by its wire name; new photos take the macOS defaults.

- **Latitude** draws what the Mac's `LatitudePlot` draws from the engine's
  latitude reading: the frame's histogram on the fixed -8..8 stop axis, the
  ISO 6846 window, the separation band, Below / Within / Above and the summary
  line. With no reading it says why (develop first, or the engine's
  "unmeasurable" / "no light"); a reading being replaced stays up, dimmed.
- **Input / Camera**: Metering (with Custom), Film Exposure with the Mac's
  derived As Shot box and the meter's reading; white balance at decode --
  Temperature (2000-12000 K) and Tint (-150..150) with each row's As Shot box,
  greyed for a camera LibRaw has no matrix for -- the white balance presets
  and the neutral picker (one click on the picture). Vignetting is the
  Post-Dev grade's lens fall-off, as on the Mac. Lens Correction stays greyed.
- **Film Format**: the film's size and side, which scale grain, halation and
  coupler diffusion in micrometres, and every effect row with its switch and
  strength.
- **RAW Decode** (Windows only, before Scene Placement in the pipeline's
  order): `compatible16` or the restricted-Bayer `headroom` mode
  ([engine/WINDOWS_NATIVE_RAW.md](../engine/WINDOWS_NATIVE_RAW.md)), and
  Highlights and Shadows (-100..100, up to 2 stops each): a local move on the
  scene after the meter and before Scene Placement, judged against an
  edge-aware base so a region moves as a whole and keeps its detail
  (`scene_tone_*`, API-SPEC §16). They work on flat files too; the Latitude
  reading and the placement's Fit see them.
- **Scene Placement**: Highlight and Shadow, each step brought onto the Fit's
  window, solved and committed as `Session.placeScene` does; the usable window
  is drawn on each track and the reason a row stopped is its second line.
- **Tone Mask** (the contrast mask, RFC-024): Enable, Highlights, Shadows,
  Core and Radius with the mask's curve. The Mac hides it behind a feature
  flag; Windows shows it, folded, because the engine carries it.
- **Photo Info**.

On the left rail, **Enlarger** has the print exposure (-3..3 stops), the
yellow and magenta filters and pre-flash, and **Print** the paper, its
brightness and Print Effects. **Process** (the tool bar's capsule) solves
auto-exposure and the filter pack for this paper and reports the result in
the status footer.

## Film Edge and Date Back

The left rail's two sections are the Mac's (`FilmEdgeSection.swift`,
`DateBackSection.swift`), over the engine's overscan and date imprint
(RFC-031/032; [engine/WINDOWS_FEATURE_COVERAGE.md](../engine/WINDOWS_FEATURE_COVERAGE.md)).
**Film Edge**: the format (135, half frame, XPan, 645 to 6x9, 6x12, 6x17) with
the gate's size, View (Strip / Filed), Framing in the gate, Gate, Holes,
Carrier, Body and Advance with their Another buttons, the frame number, edge
fog and spool leaks. Switching it on frames the crop in the gate and
switching it off gives the user's own crop back (`heldGeometry`), as one undo
step; with the frame cut, a crop is a new negative and re-develops. **Date
Back**: LCD / Dots / Data faces (a face its camera cannot print greyed), the
EXIF or a typed date, shooting data, In frame / Between (which needs Film
Edge), the 120 margin, size and brightness. The edge text is set in TeX Gyre
Heros, the bundled stand-in for the Mac's Helvetica Neue. Sync keeps each
recipient's film edge, date back and held crop.

## Half-frame pairs

Two frames on one frame's worth of 135, after the Mac's `Session.swift`
"the half-frame pair" and `PairOverlay.swift`: Ctrl+J (New Half-Frame Pair)
from two selected photographs, or Enter Half-Frame Pair under Film Edge's
*Half*. The canvas shows two holes, an empty one with a **+**; a click picks a
hole and the rails then act on that frame alone (its camera, white balance,
Scene Placement fitted on its hole, enlarger and Post-Dev), with "Applies to:
Frame / + Film" on the Enlarger; a right click opens the Mac's hole menu
(Replace, Crop This Frame, Turn Picture 90°, Reset Crop, Remove, Open Frame
Alone, Swap, Turn the Camera, Zoom to Fit, Export). In the crop mode a drag
moves the picture under its hole and the wheel scales it about the pointer.
The pair section under the Navigator lists Film / Left / Right with Camera
Level / Turned, Spacing and Swap. A pair is one item in the filmstrip, saved
in its own record (`<edits>/Pairs/<name>.spkpair`), and exports as one
picture with its first frame's EXIF; an empty hole refuses the export. The
neutral picker is not offered on a pair. The pair's canvas and its export are
compared in one colour space by `spk_qt_pairs_workflow_test`.

## Post-Dev

Post-Dev (Layer 2, the Parameters rail's second tab, `src/PostDev.hpp`): White
Balance, Exposure (exposure, contrast, brightness, saturation | highlights,
shadows, black and white point), Curve (RGB, Luma, Red, Green, Blue; click to
add a point, drag, drag off the plot or right-click to delete, double-click to
reset), Color Balance (Master, 3-Way, Shadow, Midtone, Highlight wheels with
their saturation and luminance arcs), with the vignette on Pre-Dev's Camera
section's Vignetting row as the Mac has it -- the Mac's grade on the
finished print, in its order and arithmetic. The canvas grades on the GPU
between the sample and the display LUT (`shaders/colorcanvas.frag` includes
`postdev.glsl`; the software backend runs the same `Grade` on the CPU), the
navigator and crop editor likewise, and the strip thumbnail and the histogram
count the graded frame. Every pixel is graded at its place on the uncropped
source, so the vignette is the print's (`PostDevView.hpp`); with Film Edge on
the whole film canvas is graded, rebate included, as the Mac grades the
engine's print (Renderer `encodeLayer2(src: base)`, Exporter `applyLayer2`), and
the crop editor's undeveloped decode is not (the Mac shows it as the Original).
Each edit is one undo step, needs no render and is saved with the photo as
`state.postDev` (a Mac sidecar's `adjustments` object reads verbatim); Sync
and the clipboard do not copy it (the Mac's `SettingsClipboard` leaves it
out); Reset This Photo's Settings resets it. Ctrl+Shift+B (or the menu's
Bypass / Restore Adjustments) switches the grade off and on, as a stored
edit. Every export -- the export page's recipes, the legacy exports, batch
export and the proof -- grades the uncropped frame before the geometry, so
the file is what the canvas shows. The Mac's filmstrip shows the print
without Layer 2; Windows grades it (AGENTS.md trap 33). Frames are encoded
ProPhoto RGB (the working space, below), so the grade pivots at ProPhoto's
mid-grey (0.3857, the Mac's) and its gains act on ProPhoto primaries.

## The canvas

All engine work runs on one serial worker. Edits during a render are coalesced
into the newest settings; superseded results never replace the displayed frame
or newer controls. Changes update the preview after a 180 ms settling delay.

**Switching photographs** shows the next one the moment the click lands: its
last developed picture as it was shown, graded (the picture cache: each
photograph's picture reduced to 2560 px when it is left, 512 MB, least
recently used out first), else its own embedded preview cut and turned like it
(the strip's at once, a 2048 px one read off the GUI thread a moment later).
It sits over the canvas until the photograph's frame lands and then fades out
over it. A thin accent bar sweeps the canvas's top edge while anything
develops, at full strength while a photograph opens. The host keeps the
decodes of photographs left (`HostOptions::decode_cache_bytes`, 1 GB: two or
so 36 MP decodes), so going back to one skips its decode -- 1.5 s of a D810
NEF -- and lands in ~0.8 s at full resolution, with its picture on screen at
once.

**The preview resolution** (Settings > Rendering: 1080, 1920, 2560 by default,
3840; read at start), as on the Mac (ARCHITECTURE.md §7.3): an open and every
edit develop the engine's `live` tier at that long edge, and 400 ms after the
edits stop the full frame follows (`PreviewHost` `Tier`, `HostOptions::
preview_long_edge`). An edit while the full frame is developing cancels it
(`cancel_full_render`, the one render that sent nothing, so the session is
kept). A crop, turn, flip or straighten does not, unless the frame is cut (a
film edge, a date on a cropped frame): a frame not cut is the same frame
whatever its geometry, so the edit applies while any render develops
(`geometryEditable`) and the render lands with its picture made again at the
newest geometry; a cut frame's geometry waits for its render, as before. The
live frame is published with a device pixel ratio of its pixels
over the full frame's, so the canvas lays it out as the full frame -- zoom,
100 %, pan and the Original's placement do not move when the full frame lands
-- and draws it filtered; `frameScale`, `fullResolution` and the reported size
say the same to the QML. Every export renders the full frame first
(`fullFrame`). Measured on a 36 MP D810 frame at 1600: a print edit 11 ms live
against 436 ms full, the first picture of an open at 2.0 s and the full frame
at 3.1 s. The self-test and `--snapshot` develop at full resolution unless
`--preview-long-edge` says otherwise; the editing workflow's last block tests
the live tier.
A geometry edit (crop, turn, flip, straighten, an undo across one, a film edge
moving the crop) and a half-frame pair's frame-by-frame grade make the canvas's
picture again from the frame already developed, never on the GUI thread: a
one-thread lane beside the worker (`requestVisible`) where the newest request
replaces one not yet started and a result lands only while it is still the
newest, so the canvas keeps the last picture until the current geometry's
lands and never shows an older crop (`pictureSettled` says when it has). The
straighten's bilinear pass runs its rows across the cores, bit-identical to one
thread. Measured with `spk_qt_geometry_bench` (below) on the 33 MP ARW and the
36 MP NEF at full resolution: a straighten step held the GUI thread 1.0-1.1 s
and a crop step on a straightened frame 0.7-0.8 s; each now returns in about
0.1 ms, and the picture lands 0.24-0.49 s after the drag stops (0.06-0.11 s for a
plain crop).
The same worker makes the canvas images before a result is delivered: the
frame's RGBA16 as `RGBX16FPx4` half floats (value/65535, 8 bytes per pixel like
the RGBA16) tagged with the colour space the session's open reply reports
(`FrameImage.hpp`; an output space it cannot name is refused, never
defaulted), a navigator image reduced to a 1024 px long edge by area
averaging, and from that the 180x120 strip thumbnail, also half floats; the
Original and the histogram are made there too. A superseded render is not
converted. File dialogs pause pending updates until they close; opening and
exporting lock conflicting commands. A failed current render retains the
displayed frame and restores its controls; a retry is available. Closing
during work waits for the current operation.

**Canvas tools** (after the Mac's `ViewportState.swift`, `TopBar.swift`,
`HistogramView.swift`, `CompareOverlay.swift`, `CropOverlay.swift`):

- Zoom: fit or 5-800 % in the Mac's steps, about a point. 100 % and every
  whole multiple put the image origin on the window's physical pixel grid.
  The wheel (with or without Ctrl), touchpad pinch or the native zoom gesture
  zoom about the pointer, a quarter stop per notch (the Mac pans on a scroll
  and zooms with Cmd/Option); Shift+wheel or a tilted wheel pans across,
  Alt+wheel up and down. Zoomed past the canvas, scroll bars on its bottom and
  right edges pan it, as does a drag; double-click and Z toggle fit/100 %.
  The zoom pill opens Fit, 25, 50, 100,
  200, 400 %; Ctrl+= / Ctrl+- step; Ctrl+0 and Ctrl+1 (or , and .) are fit and
  100 %. Zoom is locked in the crop editor. F11 is full screen.
- Histogram: RGB and luma of what the canvas shows -- the cropped print, the
  uncropped source in the crop editor, the Original while shown.
- Original: the bar's pill pins it, Space shows it while held, badge
  "original · decode". Before/after: the compare button, Y or Alt+\\; a
  divider anchored to the picture, with Before/After labels.
- Crop editor: corner blocks and edge bars, resize with the opposite side
  pinned under the aspect (Shift locks a free shape), body move, thirds while
  dragging, Ctrl-drag to straighten along a line (the Mac's Cmd-drag); drawing
  a new rectangle starts outside the frame or with Alt.

**Crop** is post-render geometry and does not re-run the emulsion. Preview,
navigator and exports share the same rounded source-pixel edges. Free drag,
1:1, 3:2, 4:3 and 16:9, clockwise/counterclockwise quarter turns,
horizontal/vertical flips and -45 to +45 degree straightening. Straightening
applies on release, uses original 16-bit samples and zooms to fill the crop;
quarter turns/flips are lossless. The crop editor uses the unrotated source
explicitly, while presets describe the final output ratio. The strip and the
export page show the whole photo under its crop mask. While Film Edge holds
the crop, the crop keeps the gate's shape and Crop says "Held by Film Edge".

## Edits, undo and persistence

Edits save automatically under the application's local data directory
(`%LOCALAPPDATA%\SpektraLab\SpektraLab Windows\Edits`) and restore when the
same photo is reopened; RAW files and their directories are not modified. The
record is version 2 (`src/EditStore.hpp`): settings keyed by the desktop
settings table and validated against its types, ranges and choices, the decode
mode, the geometry, the held crop and `postDev`. Version 1 records still load
and are rewritten as version 2 by the first save; a key this build does not
know is a newer build's and is kept as it was, and a later version is
preserved, never read. Save failures, incompatible records, changed sources
and conflicting writes from another app instance remain visible and preserve
the existing record; after a concurrent-write conflict, restart the
application and reopen the photo to load the other instance's settings.
Persistent photo identity includes canonical path, size, modification time and
first/last 64 KiB hash. Renamed/moved source files are not automatically
matched yet.

Ctrl+Z undoes the current photo; Ctrl+Shift+Z / Ctrl+Y redo. Undo/redo is per
photo, bounded to 64 in-memory steps, and a slider drag is one step; the
history itself is not persisted. Text editors retain their own undo
shortcuts. Synchronization is undoable on each recipient photo. Batch export
and file dialogs lock history commands along with other edits. The filmstrip
restores each photo's wanted edits, including edits pending when the user
switches away.

`--edit-store <absolute-directory>` overrides the persistent directory, and
the preferences (`app-settings.json`) and export recipes
(`export-recipes.json`) follow it; every automated test injects an isolated
directory, including `--self-test` and `--snapshot` (`<snapshot>-edits`), so no
test reads or writes the user's real store.

## Export

Ctrl+E opens the Mac's export page (`Export/ExportPage.swift`,
`ExportRecipe.swift`, `Exporter.swift`): the settings rail (Export Formula,
Location, Naming, Format and Size, Summary, and a Windows Metadata section),
the proof in the middle and the worklist down the right. Recipes are read and
written in the Mac's own JSON (`export-recipes.json`), with its four naming
tokens, the existing-file policies (-1, -2 suffixes / overwrite / skip) and
its four default recipes. The chain is `Exporter.filePixels`': [Post-Dev] ->
geometry -> long edge -> one conversion through `spk_output_transform`
(`engine/host/output.cpp`) -> depth -> file, tagged with an ICC for the
space (the bundled `sRGB.icc`; profiles matching the engine's curves
otherwise). TIFF 16-bit, PNG 8/16, JPEG with quality; EXIF from the camera
file (LibRaw); a TIFF preview page; the Digital Intermediate (Cineon, untagged,
the view LUTs beside it); Open With hands the finished files to the default
app, File Explorer or a chosen application. Writes publish atomically; nothing is replaced
unless the recipe says overwrite. A batch runs as one locked operation, so
the open frame and selection hold still (AGENTS.md trap 34), and Stop works
between photos.

The legacy exports (Export TIFF/PNG/JPEG and batch export) remain: they
convert into sRGB and embed `sRGB.icc`, byte for byte an sRGB recipe export of
the same frame. Single export captures the displayed frame, including when a
new preview is pending, and refuses overwrites; batch export processes
selected photos serially, supports cancellation between files and skips
existing files.

## The working space

As on the Mac (ARCHITECTURE.md §7.5), every session asks the engine for
encoded **ProPhoto RGB** (`PreviewController::kWorkingSpace`) and the canvas
receives half floats tagged with whatever the session reports (Qt 6.11's scene
graph uploads `RGBX16FPx4` as an `RGBA16F` texture on D3D11). Every export
reads the engine's RGBA16, not the display image, and leaves the working
space exactly once: the export page through the engine's output transform into
the recipe's space (`RecipeExport.hpp`), and the legacy single and batch export
through the same conversion into sRGB first (`exporting::exportLegacy`). The
hidden `--output-color-space sRGB` option opens the old sRGB session, where an
sRGB recipe export is byte-identical to the legacy writer's file; the
self-test runs in either (in a ProPhoto session it also checks the sRGB PNG
conversion). `spk_qt_frame_image` holds every engine output space's tag
against the engine's own baked primaries and transfer functions. The
histogram bins the encoded working space, as the Mac's `encodeHistogram` bins
its Layer 2 texture; the Original is put into the session's space; the
Digital Intermediate carries ProPhoto primaries, which its view LUTs assume.
The GDI viewer (`engine/tools/windows_preview.cpp`) keeps the host's sRGB
default and its BGRA8. TIFF and PNG16 retain 16-bit pixels; PNG8/JPEG8 use
8-bit samples, and resizing is explicitly requested. Output is SDR: EDR/HDR
output is future work.

Nikon HE/HE* RAW remains explicitly unsupported by this LibRaw build. A failed
NEF open must leave the previous photo and its session usable.

## Display colour management

Each window has a `ColorPipeline` (`src/ColorPipeline.hpp` is the contract).
A canvas asks it for the LUT from its frame's encoded colour space to the
display; UI chrome is never managed. The colour core is `DisplayColor.*`
(which profile) and `ColorLut.*` (the LUT, and a CPU model of the shader's
texel-centre trilinear lookup that the tests measure against). Settings ▸
Display chooses the mode, shows what the canvas is managed to and why, and
offers Reload and the dither; the tool bar's photo line says the frame's
space and the display it is managed to (`<space> -> <display>`), with a
warning badge when it falls back.

**Which profile.** In `automatic` mode, the profile is the one for the monitor
Qt reports for the window. The pipeline follows the window to another monitor.
Windows is asked in this order: `ColorProfileGetDisplayDefault` (Windows 10
build 20348 and later, loaded at run time), then `WcsGetDefaultColorProfile`,
then `GetICMProfileW`. Calibration `vcgt` curves are ignored, because the
graphics card applies them. `srgb` mode assumes an sRGB display, so sRGB frames
are drawn unchanged. `custom` mode uses a chosen `.icc` file. The intent is
relative colorimetric with clipping, which is Qt's only intent. Nodes outside
the display gamut get alpha 0, for a gamut warning.

**Windows Advanced Color.** In legacy SDR the canvas targets the display
profile. Under Auto Color Management, Windows treats the 8-bit swapchain as
sRGB and manages it to the display itself. The canvas then targets sRGB and
the status line says so. HDR also targets sRGB for now, with a note, until
there is an HDR swapchain.

**Fallbacks.** Some profiles fall back to sRGB with an English warning that
names the file and the reason: missing, unreadable, truncated, CMYK, greyscale,
or A2B-only (a profile Qt cannot use as a target).

**Profile changes.** Windows sends no notification when a profile changes. The
pipeline asks again after any of these:

- a screen change, or a screen added or removed;
- `WM_DISPLAYCHANGE`, `WM_SETTINGCHANGE` or `WM_DPICHANGED`;
- the application becoming active;
- a 3 s poll (one query measured 1.3 ms on the development machine);
- a call to `reload()`.

LUTs are built on a worker thread, in about 20 ms with curves and 56 ms
without (measured). The previous LUT is served until the new one lands, and
six LUTs are cached. `SPEKTRALAB_COLOR_LOG=1` logs each decision and build.

**Two forms.** When both the source and the display are matrix/TRC profiles,
the LUT has curves:

- the shaper decodes the source to linear light;
- a 65³ table holds the 3×3 between the two linear spaces, unclamped, with the
  gamut flag in alpha;
- a 4096-entry output curve, indexed by √u, encodes for the display.

A LUT-based (A2B/B2A) display has no 3×3 to factor out. It keeps one 65³ table
from encoded source to encoded display.

**Accuracy.** Measured on 8-bit inputs, comparing the shader model's clamped
output against Qt's own transform. The "before" column is the encoded table
that every display used before the curves; codes 1-3 were searched
exhaustively.

| case | before | with curves |
|---|---|---|
| sRGB to Adobe RGB, a channel at codes 1-3 | 3.43 counts | 0.004 counts |
| sRGB to a gamma 2.6 display | 6.72 counts | 0.354 counts (Qt's float noise in a zero channel) |
| sRGB to Display P3 | 0.085 counts | 0.000 counts |
| sRGB colours carried in ProPhoto, back to sRGB | 14.5 counts | 0.002 counts |
| sRGB to this machine's HP Z31x profile (real, via `--probe-display`) | 7.20 counts, at (255,29,0) | 0.004 counts; (255,29,0) 0.000 |

**What the canvas needs for that accuracy.** The table works in linear light,
so its errors are a fixed amount of light. A matrix with cancelling terms, and
then a display curve steep near zero, magnify that light wherever an output
channel is near zero. The table needs float32 entries and full-precision
weights (eight `texelFetch`, filtered in the shader). The curves can use the
hardware filter.

D3D11 and Vulkan promise only 8 bits of filter-weight precision. On the
replica of this machine's profile, the table under 8-bit hardware weights
misses by:

| table size | weights rounded | weights truncated |
|---|---|---|
| 65 | 1.90 counts | 3.07 counts |
| 129 | 1.41 counts | 2.18 counts |

No feasible size fixes that. A half-float table measured 0.15 counts and
half-float curves 0.27 counts. Half-float curves cost 1.34 counts on the
ProPhoto round trip. With float weights, the table size does not affect
accuracy: 9 nodes are already exact. The size only sets the gamut flag's
resolution: of ProPhoto colours, 1.2 % are misflagged at 65, 2.4 % at 33 and
4.3 % at 17. `spk_qt_color_core_test --sweep` prints these measurements.

The encoded table for LUT-based displays keeps its old limit near black. On a
synthetic wide-gamut lut16 display, the table misses Qt by up to 3.3 counts
(1.6 counts away from codes 1-3). Qt's own evaluation of that profile differs
from the display it describes by 9.2 counts, and the table adds nothing
measurable to that. Qt 6.11.3 reads lut16 PCSXYZ with 0xFFFF as 1.0, where
ICC's legacy encoding has 0x8000 as 1.0. That was measured on a synthetic
profile; whether real lut16/XYZ display profiles are read at half scale is not
yet checked against one.

**The canvas.** `FrameCanvas` (main canvas, navigator, filmstrip) draws its
image through `ColorCanvasNode`: a custom scene-graph material
(`shaders/colorcanvas.*`) that samples the frame as before (Nearest at or
above 100 %, Linear below), runs it through the LUT (shaper, table, output
curve when the LUT has curves), clamps, and adds one 8-bit step of triangular
dither when asked. The table (a 3D texture, or a 2D atlas without 3D
textures) and the curves are 32-bit float, shared per window and LUT key, and
only fetched: the shader interpolates the table's eight nodes and each
curve's two entries with float weights, so no 8-bit filter weight touches
them and no float filtering support is needed. Under the identity, an 8-bit
frame is drawn by a bare texture read, exactly as Qt's texture node drew it.
RGBX16FPx4 frames keep half-float precision up to the LUT. Frames over the
16384 px texture limit are tiled with a one-texel apron. The software backend
(the self-test) runs the same path on the CPU. `spk_qt_color_canvas` renders
on D3D11 WARP through `QQuickRenderControl` and reads back against an
independent reference and against the colour core's model of the recommended
canvas sampling: exact for the identity, within one count through every LUT,
curve, tile seam and translucency case (a float target measures the curved
path within 0.0004 counts of exact), with the letterbox untouched.
`spk_qt_color_canvas_software` runs the CPU path. Both also hold the Post-Dev
grade to `Grade::apply`: an identity or bypassed grade exact (and exactly Qt's
texture node), a full grade within one count through the identity and a LUT,
on a half-float frame, mapped onto the source, across tiles (WARP: 0 counts
off through the identity, a float target 0.0001 counts from `Grade::apply`).

**The soft proof** (`ProofTransform.hpp`, `SoftProof.hpp`). **S** (or the top
bar's Proof pill, or View ▸ Soft Proof) shows the canvas as the export page's
selected recipe will write it; **Shift+S** (View ▸ Gamut Warning, the triangle
beside the pill) paints magenta over the colours that recipe's space cannot
hold. The Mac proves on its export page only (`Export/SoftProof.swift`); the
Windows proof is that same transform on the canvas, live under every edit.
Per pixel, in the canvas shader's PROOF variants (`shaders/colorcanvas.frag`;
the CPU form is `spk::color::sampleProof`, which the software backend runs):
the frame's curve off, the engine's CAT02 3×3, CAM16-UCS gamut compression into
the recipe's space with the export's own setting (`exporting::exportTransform`:
off when the destination holds the frame's space, else the chroma knee without
the lightness shoulder), the file's clamp, then the window's display LUT *for
the recipe space* — entered past its shaper, so the table takes the recipe's
linear light. Every number is the engine's (`spk_output_transform`); the
arithmetic is `engine/host/output.cpp`'s, line for line, as the Mac's
`Canvas/Shaders.metal` `outputTransform`. A colour is flagged where the export
could not keep it: its chroma lay outside the destination before the knee
(`d > 1`, the Mac shader's `outside`, the share its export page reports as
"rolled into") or a channel stayed outside [0, 1] after the gamut map (what the
file clips). The warning colour is a display value written after the LUT and
the dither, never through a LUT (AGENTS.md trap 27).

Why per pixel and not a 3-D table of the composite: the gamut map is far from
smooth where it works hardest. Near black the hue of a saturated colour swings
with the smallest change, and colours rolled onto the destination's boundary
follow its cusps. A 65³ table of source → export → display measured 15-33
counts from the export (`spk_qt_soft_proof_test --sweep`, ProPhoto into sRGB
and Display P3 on four displays), with 0.6-4.8 % of 216 332 probes over one
count, and the error only roughly halving from 33³ to 65³. Per pixel the proof
is within one count of the file everywhere (`spk_qt_soft_proof`: at most 1.1
counts before rounding over every recipe space from a ProPhoto and an sRGB
session on four displays; the flag agrees with the export's on all but one
probe in 216 332), and the shader within one count of that CPU form on D3D11
WARP and the software backend (`spk_qt_color_canvas`), with the warning exactly
magenta wherever both flag. On this machine's RTX 3070 a 3840 × 2160 canvas
draws in 0.38 ms through the display LUT, 0.62 ms as a proof and 0.84 ms with
the warning (`spk_qt_color_canvas_test --hardware --benchmark`).

**Tests.** `spk_qt_color_core` runs on the CPU, with no GPU, no shown window
and no installed profile. Its ICC profiles are built in the test, including a
CMYK one and an A2B-only one written byte by byte. It checks:

- identity, swapped primaries, gamma 2.6, Display P3, Adobe RGB, a replica of
  the HP Z31x profile and ProPhoto, through the shader model, in both forms;
- exact filtering and the recommended canvas path, both held to half a count;
  8-bit hardware weights and half floats are measured;
- a LUT-based display (A2B/B2A lut16), which keeps the encoded table;
- the fallbacks;
- `ColorPipeline` on simulated monitors: two monitors, a screen change, a
  profile recalibrated in place (once through the poll), ACM, HDR, the three
  modes, the cache, and the old LUT served until a rebuild lands;
- `forWindow` called from a render thread.

`spk_qt_color_core_test --probe-display` prints what each Windows query says
about this machine's monitors, and the LUT accuracy for the real profile. It
only reads.

## Settings, About and the interface text

**Settings** (Ctrl+,; the Mac's `SettingsWindow.swift` pages in its order --
General, Rendering, Memory, Diagnostics, Agents -- with Display after
General). Rendering: the preview resolution (The canvas, above). General: the language (the loaded tables, or Follow the system;
applied at once and kept), the interface scale (100/115/130 %, applied at the
next start through `QT_SCALE_FACTOR`; an environment `QT_SCALE_FACTOR` wins),
Reset All Layout and this session's build. Display: above. Diagnostics: where
this session keeps its preferences, edits and licence texts, with Show in
Explorer. Every Mac setting without a Windows backend is shown greyed with the
reason under it, nothing invented: fast stock preview, DI
blue compensation, crop re-maps, decouple effects, the memory and disk-cache
readouts and caps, log level, per-node timings, job logs, log retention, the
diagnostic bundle, the update check and agent access (the `spektralab` CLI
and MCP server are macOS-only). Preferences are `app-settings.json` beside the
edit store.

**About** (`AboutWindow.swift`): name, version (the Mac's `MARKETING_VERSION`,
`SPEKTRALAB_VERSION` in `CMakeLists.txt`), engine build (`spk_build_info`), Qt
and compiler, the canvas's graphics adapter, the credits in the form CC BY-SA
asks for, the GPL's written offer with the source URL, and every text in the
deployed `licenses/` folder in a viewer, read from the files; a text the build
should carry and lacks is listed as missing.

**Interface text.** Every user-visible QML string, and the controller's status
lines, is looked up by key from `i18n/en.json` through the C++ `Localizer`;
English is the only shipped language, and [i18n/README.md](i18n/README.md)
says how to add another.

**Keys.** Ctrl+O imports files, Ctrl+Shift+O a folder, Ctrl+E opens export,
Ctrl+A selects all photos, Ctrl+Shift+C / Ctrl+Shift+V copy and paste
settings, Ctrl+J makes a half-frame pair, Ctrl+Shift+B bypasses the Post-Dev
grade, S / Shift+S soft proof and gamut warning, Space shows the Original, Y
or Alt+\\ before/after, Ctrl+, opens Settings, Ctrl+Q quits; the zoom keys are
under Canvas tools.

## Validation

**CTest** (47, all passing on 2026-10-16 with MSVC 19.44 on an RTX 3070). The
Qt editor's 22:

| test | holds |
|---|---|
| `spk_qt_frame_output` | shared crop geometry, actual PNG/JPEG/TIFF pixels/depth/ICC, JPEG quality, resize, extension agreement, atomic no-overwrite publication (including concurrent writers), cleanup |
| `spk_qt_recipe_export` | the Mac's recipe JSON, naming, existing-file policies against real files, sRGB byte identity with the old writer, every colour space from an sRGB and a ProPhoto session against an independent CIE conversion and through its embedded ICC, EXIF, preview page, DI |
| `spk_qt_frame_image` | every engine output space's canvas tag against the engine's primaries and curves |
| `spk_qt_edit_store` | strict document/version validation, version 1 to 2, atomic save failure, source replacement, concurrent-instance conflicts, damaged/future records preserved |
| `spk_qt_controller_settings`, `spk_desktop_settings_engine` | the controller's settings API (generic parameters, legacy names, defaults, locks); the settings table through the real engine on a synthetic frame |
| `spk_qt_film_edge_state` | Film Edge / Date Back rows, refusals, gate lock, held crop, Sync's rule, the record's round trip |
| `spk_qt_canvas_tools` | zoom ladder, physical alignment, clamp, crop grips, straighten line, histograms, the Original's conversion and geometry |
| `spk_qt_color_canvas`, `spk_qt_color_canvas_software` | the canvas on D3D11 WARP and the software backend (above) |
| `spk_qt_localizer` | every shipped table uses only `en.json`'s keys, and every key the QML asks for exists |
| `spk_qt_color_core`, `spk_qt_soft_proof` | the display LUT and the proof (above) |
| `spk_qt_predev` | the Fit and the placement window on a synthetic ramp through the real engine, `spk_solve`'s report, the Tone Mask curve, the white-balance rules, the neutral picker's geometry, the controller's Pre-Dev API |
| `spk_qt_postdev`, `spk_qt_postdev_gpu`, `spk_qt_postdev_glsl` | the grade and its record on the CPU; the same grade through QRhi held to the CPU path; `postdev.glsl` compiled by glslang |
| `spk_qt_pairs` | the pair's record, where each edit lands, what the engine is handed |
| `spk_qt_app_settings`, `spk_qt_shell_smoke` | the preferences file; Settings and About load offscreen with no QML warning |
| `spk_qt_library`, `spk_qt_flat_input` | folder listing, order, crop-masked thumbnails; TIFF/JPEG/PNG decoded at the door against independent conversions |

**The RAW gates** (commands under Build). The self-test drives actual
QML/controller operations and the native Vulkan engine, saves fit/100%/final
PNG captures, exports the displayed frame, checks negative-cache use,
film/paper changes, failed RAW retention, overwrite refusal with pending
settings, single flight, panning and physical-pixel scale, old-frame
immutability, injected display publication failure recovery, automatic
selection/brightness, rapid edits before and during rendering, returning to
the displayed settings, all four slide films, negative/slide transitions,
automatic decode changes and reset, and the canvas tools; it exits nonzero on
failure and writes JSON and scene captures. The library gate checks pending
edits while switching photos, independent crops, synchronization,
preview/export pixel agreement, PNG16 and JPEG size, batch source/filename
agreement, selection locks, no-overwrite, cancellation and failed RAW
retention. The editing gate verifies history during in-flight renders,
geometry/PNG agreement, mirrored rotation direction, destructor flushing of
pending changes, recreation/reopening, per-photo history, batch locks and
visible persistence warnings. The export gate covers recipe persistence,
identity on a developed frame, EXIF, policies, DI, batch Stop and a ProPhoto
session; the pairs gate Ctrl+J, per-frame edits, undo, the record across a
restart and the pair's export as one picture.

The captures are **offscreen scene captures**, not a live monitor screenshot.
Software scene display does not make the engine a CPU renderer. These gates
do not automate the native file dialogs or verify a monitor's colour; no
display has been measured with an instrument.

The first validated build (Qt 6.11.3 / MinGW 13.1 on an RTX 5070 Ti) passed
16 engine CTests and the real 4688 x 7028 ARW scene test; the same decoded
input produced byte-identical deterministic RGBA16 full and print-edit outputs
under that compiler and the earlier GCC 15.2 baseline. The Vulkan startup gate
uses an exact product-residual reference because the legacy MSVCRT `fmaf`
returns incorrect residuals for some of the probe inputs; the GPU comparison
remains exact and also has fixed-bit regression vectors.
