# Windows Qt Quick frontend

This is a native Qt Quick/C++ application using the existing synchronous
`spk_desktop_host`. There is no Python, Node, browser or subprocess renderer at
runtime. The upstream SwiftUI theme supplied the grey rails, centre canvas,
warm accent and bottom strip; unsupported controls are omitted deliberately.

Implemented: multi-file RAW import and drag/drop; independent per-photo
film/paper, decode, exposure, grain, halation, glare, film format and filter
settings; a navigator and selected-photo strip; free/ratio cropping; and
TIFF16, PNG8/16, JPEG8 export with JPEG quality and optional downsize. Batch
export processes selected photos serially, supports cancellation between files,
and skips existing files. Single export refuses overwrites. Output stays sRGB
with the bundled ICC profile. Select-all and synchronization copy supported
settings to selected photos, preserving their own crops by default.

The QML is one file per pane (`qml/left`, `qml/centre`, `qml/right`,
`qml/export`, shared controls in `qml/controls`); `qml/Main.qml` holds the
window, dialogs and shortcuts and `qml/EditorState.qml` the state the panes
share. Every user-visible QML string is looked up by key from
`i18n/en.json` through the C++ `Localizer`; English is the only shipped
language, and [i18n/README.md](i18n/README.md) says how to add another.

Ctrl+O imports, Ctrl+E opens export options, Ctrl+0 fits and Ctrl+1 selects
physical 100%. Double-click also switches fit/100%. Changes update the preview
automatically after a 180 ms settling delay. The filmstrip restores each
photo's wanted edits, including edits pending when the user switches away.
Edits automatically save under the application's local data directory (`Edits`)
and restore when the same photo is reopened. RAW files and their directories
are not modified. Save failures, incompatible records, changed sources and
conflicting writes from another app instance remain visible and preserve the
existing record. After a concurrent-write conflict, restart the application and
reopen the photo to load the other instance's saved settings. Undo/redo is per
photo, bounded to 64 in-memory steps, and a
slider drag is one step. Undo history itself is not persisted. Only the current
photo is fully decoded/developed; unvisited
photos have an explicit placeholder until opened. Small thumbnails are retained,
not one full RAW/GPU session per imported photo.

Crop is post-render geometry and does not re-run the emulsion. Preview,
navigator and exports share the same rounded source-pixel edges. The first
Windows crop supports free drag, 1:1, 3:2, 4:3 and 16:9, clockwise/counterclockwise
quarter turns, horizontal/vertical flips and -45 to +45 degree straightening.
Straightening applies on release, uses original 16-bit samples and zooms to
fill the crop; quarter turns/flips are lossless. The crop editor uses the
unrotated source explicitly, while presets describe the final output ratio.
Masked full-photo strip thumbnails remain pending. The strip currently
shows the cropped output. See [DESIGN_ALIGNMENT.md](DESIGN_ALIGNMENT.md) for the
author's drawing transcription and upstream comparison.

Slide film is scanned directly, matching the upstream macOS film-stage rule.
The host resolves this from each profile's `info.type`, including Provia 100F,
Velvia 100, Ektachrome 100 and Kodachrome 64. Paper and paper-brightness controls
are disabled for slides; their previous settings return with negative film.
The colour model, profile data and shader maths are unchanged.

All engine work runs on one serial worker. Edits during a render are coalesced
into the newest settings; superseded results never replace the displayed frame
or newer controls. File dialogs pause pending updates until they close; opening
and exporting lock conflicting commands. A failed
current render retains the displayed frame and restores its controls; a retry
is available. Export captures that same immutable frame, including when a new
preview is pending, and pending edits resume after export succeeds or fails.
Closing during work waits for the current operation. A failed image-publication
allocation is reconciled against the displayed source/decode mode on the next
render.

Ctrl+Z undoes the current photo; Ctrl+Shift+Z / Ctrl+Y redo. Text editors retain
their own undo shortcuts. Synchronization is undoable on each recipient photo.
Batch export and file dialogs lock history commands along with other edits.
`--edit-store <absolute-directory>` overrides the persistent directory; all
automated tests inject an isolated directory, including `--self-test` and
`--snapshot`, so no test reads or writes the user's real edit store. Persistent
photo identity includes canonical path, size, modification time and first/last
64 KiB hash. Renamed/moved source files are not automatically matched yet.

## Build

Use the official Qt 6.11.3 Windows MinGW SDK with its MinGW-w64 13.1 compiler.
Do not link these Qt binaries with the earlier GCC 15 Windows build. Build into
an independent directory; the script changes only its own process PATH.
Use `-Fresh` to discard an existing CMake configuration before rebuilding.

```powershell
# From the repository root. The bootstrap uses only PowerShell and Windows
# bsdtar, downloads into ../deps and checks pinned SHA256 for every file.
./windows_UI/setup-qt.ps1 -DependencyDirectory ../deps
./windows_UI/build.ps1 -SourceDirectory . -BuildDirectory ./build/qt -RunTests
```

Local dependencies are in the workspace's `deps/qt-6.11.3`, alongside Vulkan
headers, glslang and LibRaw used by the engine. `-DependencyDirectory` overrides
that location. The output `app/` is self-contained for this Windows machine;
keep the complete directory with its DLLs, QML plugins, resources and notices.
The Vulkan driver is supplied by Windows/the installed GPU driver.

`dependencies/qt-packages.json` lists the exact official archives and hashes;
`dependencies/qt-licenses.json` lists each official source license and hash.
`setup-qt.ps1 -VerifyOnly` verifies the existing archive/license cache and tool
versions without network or extraction. The initial download is about 278 MB.
This script does not install Vulkan headers, glslang, CMake or LibRaw; set those
up using the repository's Windows engine instructions first. It neither
downloads an unpinned "latest" SDK nor depends on a private local manifest.

For a parent build, enable the native RAW and desktop host targets and call
`add_subdirectory(windows_UI)` after `add_subdirectory(engine)`. The Qt frontend
links the existing `spk_desktop_host`; the macOS build is untouched. Resources
are synchronized on every build, including builds where the executable itself
does not need relinking. Deployment is an explicit build-script step.

## Validation

The first validated build used Qt 6.11.3 / MinGW 13.1 on an RTX 5070 Ti:
16 engine CTests passed, followed by the real 4688 x 7028 ARW scene test below.
The same decoded input produced byte-identical deterministic RGBA16 full and
print-edit outputs under this compiler and the existing GCC 15.2 baseline.
The Vulkan startup gate uses an exact product-residual reference because the
legacy MSVCRT `fmaf` returns incorrect residuals for some of the probe inputs;
the GPU comparison remains exact and also has fixed-bit regression vectors.

```powershell
$env:QT_QPA_PLATFORM='offscreen'
$env:QT_QUICK_BACKEND='software'
./build/qt/app/SpektraLabQt.exe --open C:/photos/supported.ARW `
  --reject C:/photos/unsupported-HE.NEF --self-test C:/SpektraLab-validation/new-qt-test
```

The output directory must not exist. The test drives actual QML/controller
operations and the native Vulkan engine, saves fit/100%/final PNG captures,
exports the displayed frame, checks negative-cache use, film/paper changes,
failed RAW retention, overwrite refusal with pending settings, single flight,
panning and physical-pixel scale, old-frame immutability, and injected display
publication failure recovery. It also checks automatic selection/brightness,
rapid edits before and during rendering, returning to the displayed settings,
all four slide films, negative/slide transitions, automatic decode changes and
reset. It exits nonzero on failure and writes JSON and scene captures.

`spk_qt_frame_output` is an additional CTest for shared crop geometry, actual
PNG/JPEG/TIFF pixels/depth/ICC, JPEG quality, resize, extension agreement,
atomic no-overwrite publication (including concurrent writers), and cleanup.
The explicit full-RAW library gate uses isolated copies of both photo inputs:

```powershell
# Use the same Qt/MinGW runtime PATH as build.ps1 and the SDK's plugin directory.
./build/qt/spk_qt_library_workflow_test.exe ./build/qt/app/resources `
  C:/photos/supported.ARW C:/photos/unsupported-HE.NEF `
  C:/SpektraLab-validation/new-library-test
```

It checks pending edits while switching photos, independent crops, synchronization,
preview/export pixel agreement, PNG16 and JPEG size, batch source/filename
agreement, selection locks, no-overwrite, cancellation and failed RAW retention.
The output directory must be new; missing fixtures are a hard failure.

`spk_qt_edit_store` adds strict document/version validation, atomic save failure,
source replacement (including before first save), concurrent-instance conflicts
and preservation of damaged/future records to CTest. `spk_qt_editing_workflow_test`
uses the same four arguments as the library gate and verifies history during
in-flight renders, geometry/PNG agreement, mirrored rotation direction,
destructor flushing of pending changes, recreation/reopening, per-photo history,
batch locks and visible persistence warnings. It owns copies of all inputs.

The captures are **offscreen scene captures**, not a live monitor screenshot.
Software scene display does not make the engine a CPU renderer. This gate does
not automate the native file dialogs or verify monitor profiles. At this phase
the host renders encoded sRGB and the GUI shows an 8-bit SDR texture. A QImage
sRGB tag is not a proof that the default Windows Qt swapchain applies a monitor
ICC transform. Wide-gamut, EDR/HDR, ColourSync-equivalent display validation,
original/split comparison, histogram, post-development grading and perspective
geometry are future work. TIFF and PNG16 retain 16-bit
pixels; PNG8/JPEG8 use 8-bit samples, and resizing is explicitly requested.

Nikon HE/HE* RAW remains explicitly unsupported by this LibRaw build. A failed
NEF open must leave the previous ARW and its session usable.

## Display colour management

Each window has a `ColorPipeline` (`src/ColorPipeline.hpp` is the contract).
A canvas asks it for the LUT from its frame's encoded colour space to the
display; UI chrome is never managed. The colour core is `DisplayColor.*`
(which profile) and `ColorLut.*` (the LUT, and a CPU model of the shader's
texel-centre trilinear lookup that the tests measure against).

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
above 100 %, Linear below), then looks it up in the LUT at texel centres,
clamps, and adds one 8-bit step of triangular dither when asked. The table is
a half-float 3D texture (a 2D atlas without 3D textures), shared per window
and LUT key. With the contract's 1-D curves, the shader runs shaper, table and
output curve, and interpolates the table's eight nodes in float, because 8-bit
filter weights lose the shadows of a table over linear light. Under the
identity, an 8-bit frame is drawn by a bare texture read, exactly as Qt's
texture node drew it. RGBX16FPx4 frames keep half-float precision up to the
LUT. Frames over the 16384 px texture limit are tiled with a one-texel apron.
The software backend (the self-test) runs the same path on the CPU.
`spk_qt_color_canvas` renders on D3D11 WARP through `QQuickRenderControl` and
reads back against an independent reference: exact for the identity, within
one count through every LUT, curves, tile seam and translucency case, with the
letterbox untouched. `spk_qt_color_canvas_software` runs the CPU path.

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
