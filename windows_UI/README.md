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
