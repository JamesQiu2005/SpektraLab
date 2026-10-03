# Windows Qt Quick frontend, first slice

This is a native Qt Quick/C++ application using the existing synchronous
`spk_desktop_host`. There is no Python, Node, browser or subprocess renderer at
runtime. The upstream SwiftUI theme supplied the grey rails, centre canvas,
warm accent and bottom strip; unsupported controls are omitted deliberately.

Implemented: RAW open and drag/drop, real catalog film/paper selection, print
brightness, compatible/headroom decode, full-resolution fit/physical-100%
display, drag panning, immutable current-frame thumbnail, and no-overwrite
16-bit sRGB TIFF export. Ctrl+O opens, Ctrl+E exports, Ctrl+0 fits and Ctrl+1
selects 100%. Double-click also switches fit/100%. Parameter changes are staged
until Apply. Opening another image uses the currently selected settings.

All engine work runs on one serial worker. Busy state prevents conflicting
commands; a generation check rejects retired results. Opening/render failure
retains the displayed frame. Export captures that same immutable frame, and
failure preserves pending unapplied settings. Closing during work waits for
the current operation. A failed image-publication allocation is reconciled
against the displayed source/decode mode on the next Apply.

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
publication failure recovery. It exits nonzero on failure and writes JSON.

The captures are **offscreen scene captures**, not a live monitor screenshot.
Software scene display does not make the engine a CPU renderer. This gate does
not automate the native file dialogs or verify monitor profiles. At this phase
the host renders encoded sRGB and the GUI shows an 8-bit SDR texture. A QImage
sRGB tag is not a proof that the default Windows Qt swapchain applies a monitor
ICC transform. Wide-gamut, EDR/HDR, ColourSync-equivalent display validation,
crop/original comparison, histogram, sidecars, undo and multi-frame batch are
future work. TIFF retains the host's 16-bit sRGB pixels and embedded profile.

Nikon HE/HE* RAW remains explicitly unsupported by this LibRaw build. A failed
NEF open must leave the previous ARW and its session usable.
