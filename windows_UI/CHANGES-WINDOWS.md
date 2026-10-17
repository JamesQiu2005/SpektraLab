# What the Windows port gained since f1440bd

Upstream's `f1440bd` (2026-10-14) is where this branch (`windows-msvc-qt`)
started. There the Windows port built with MinGW only; the engine refused
five upstream features by name (the Cineon DI, scene latitude mapping, the
contrast mask, Film Edge and the date back); and the Qt editor was a
three-panel window with Chinese interface text, sRGB output, a small export
popup, edit records at version 1 and two Qt CTests. This page lists what was
added since, by area, as of 2026-10-16. Each item names where it is documented
or tested; nothing here claims whole-image parity with the Mac (no Mac dumps
exist yet) or validation beyond the machine named.

## Toolchain and packaging

- MSVC 2022 builds the engine and the Qt editor (`build-msvc.ps1`): Visual
  Studio's own CMake and Ninja, Qt 6.11.3 `msvc2022_64`, the MSVC runtime
  deployed beside the executable, Qt's licence texts and SBOMs, LibRaw's,
  volk's, stb's and TeX Gyre Heros's notices in `licenses/`. Validated with
  MSVC 19.44 / VS 17.14 on an RTX 3070. The MinGW route is kept, not
  re-validated.
- `-Package` writes `SpektraLab-Windows-<version>-x64.zip` from the deployed
  folder, without test binaries, the redistributable installer or anything
  personal ([README.md](README.md#build-msvc-2022)).
- `-Installer` also builds `SpektraLab-Windows-<version>-x64-Setup.exe` with
  Inno Setup 6 (`installer/SpektraLab.iss`): per user or all users, Start
  menu shortcut, uninstaller ([README.md](README.md#build-msvc-2022)).
- The executable carries the product icon (`resources/SpektraLab.ico`, the
  icon in `desktop/src-tauri/icons/`, 16-256 px) as `IDI_ICON1`, which
  Explorer, the taskbar and every Qt window use.
- CTest: 47 tests (16 at the first MinGW port).

## Engine (Vulkan)

Nothing is refused any more; `windows_unported.hpp` keeps its empty table for
the next upstream effect ([engine/WINDOWS_FEATURE_COVERAGE.md](../engine/WINDOWS_FEATURE_COVERAGE.md),
[engine/PORT_COVERAGE.md](../engine/PORT_COVERAGE.md)).

- The contrast mask (RFC-024): `spk_mask_reduce`, `spk_mask_epilogue`;
  `contrast_mask.cpp` builds off Apple with a `std::thread` partition.
- The Cineon Digital Intermediate (`spk_di_encode`,
  `spk_render_digital_intermediate`) and scene latitude mapping
  (`spk_scene_latitude`, including a pair's second frame).
- Film Edge (RFC-031/032): `overscan.cpp` compiles everywhere, four kernels
  (`spk_overscan_canvas`, `_film_present`, `_light`, `_add_mask`), a portable
  text raster (`edge_raster.cpp`, stb_truetype) with bundled TeX Gyre Heros
  standing in for Helvetica Neue; `spk_overscan_geometry` exported from the DLL.
- The date back, on the bare frame and with the film edge.
- The black-and-white product profiles deployed beside spektrafilm's.
- 42 Vulkan kernels (34 at the first port).

## Desktop host (`engine/src/desktop`)

- One settings table drives validation, open parameters and edit deltas; new
  photos take the macOS defaults; the macOS stock rules and catalogue.
- White balance at decode (Temperature, Tint, As Shot, presets, the neutral
  picker) from LibRaw's camera matrix.
- Film Edge and Date Back rows and the shooting data read from the RAW.
- Half-frame pairs: the piece, its wire and `render_pair`.
- TIFF, JPEG and PNG decoded at the door into the engine's scene-linear input.
- Frames record the output colour space their session reports; export hooks
  for the export page.

## Qt editor

- **Shell**: the macOS editor's layout and design system in QML (Theme,
  icons, rail controls), one QML file per pane, an application menu, Settings
  and About windows, a preferences file.
- **Interface text**: English, every string by key from `i18n/en.json`
  through a JSON `Localizer`, with a language choice in Settings.
- **Library**: Open Folder, flat files, Finder order, a kept per-folder
  order, crop-masked thumbnails from each file's own preview, click /
  Ctrl+click / arrows, and the Settings Clipboard with the Mac's seven groups.
- **Pre-Dev**: the Latitude plot, white balance and the neutral picker,
  Process, Scene Placement, the Tone Mask, every film-format effect row, the
  enlarger's rows, Metering with Custom.
- **Film Edge and Date Back** sections, the crop held in the gate.
- **Half-frame pairs**: holes on the canvas, the pair section and frame
  picker, per-frame edits, their own record, one-picture export.
- **Post-Dev** (Layer 2): white balance, exposure, curves, colour balance and
  vignette on the GPU canvas and in every export, saved with the photo.
- **Canvas tools**: the zoom ladder, histogram, Original, before/after and
  crop grips.
- **Export**: the Mac's export page -- recipes in its JSON, naming,
  existing-file policies, colour spaces, EXIF, TIFF preview page, the DI.
- **Colour**: ProPhoto RGB working space; display colour management per
  monitor (ICC LUT with curves, float weights in the shader, Advanced Color
  aware); the canvas soft proof and gamut warning.
- **Edits**: record version 2 (settings keyed by the table, newer fields
  kept, version 1 still read), held crop, Post-Dev, multi-row edits as one
  undo step.

## Tests added in the Qt editor

Twenty of its 22 CTests are new (all but `spk_qt_frame_output` and
`spk_qt_edit_store`); the RAW gates gained the export and pairs workflows.
See [README.md](README.md#validation). On 2026-10-16, with the commands
documented there, the self-test (7IV05267.ARW) passed and the library (150
checks), editing (271), export (119) and pairs (74) gates passed on
DSC_5601.NEF / DSC_5602.NEF.

## Packaging

`build-msvc.ps1 -Package` on 2026-10-16 (version 1.3.3, Release):
`SpektraLab-Windows-1.3.3-x64.zip`, 54 073 047 bytes (51.6 MB), 1654 files
under one top folder, every entry name with `/` separators. Extracted into a
new folder and started with `--open DSC_5601.NEF --snapshot <png>` (the
Windows platform plugin, not offscreen; `PATH` reduced to `System32` and the
Windows folder, so nothing outside the extracted folder supplied a DLL), it
opened, developed and captured the 45 MP NEF and exited 0: the capture shows
the developed print, "Rendered in 1.21 s", and the canvas managed from
ProPhoto RGB to the monitor's profile. Nothing was written into the extracted
folder; the run's edits went beside the PNG (`<png>-edits`). The machine has
Visual Studio installed, so a machine without the VC++ runtime has not been
tried.
