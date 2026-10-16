# Windows build: third-party components and notices

This file is copied into the application's `licenses/` folder, which the About
window lists; "this folder" below means that folder. Paths starting with
`resources/` are beside `SpektraLabQt.exe`. The source tree's copy is
`windows_UI/THIRD_PARTY.md`.

SpektraLab's code is GPL-3.0-or-later (`LICENSE`). The Windows build is
dynamically linked against the open-source Qt 6.11.3 (`msvc2022_64`); it does
not use a Qt commercial licence.

## Shipped in the application folder

| Component | What and where | Licence | Notice in this folder |
|---|---|---|---|
| SpektraLab | `SpektraLabQt.exe`, the engine compiled into it, `resources/vulkan/*.spv` | GPL-3.0-or-later | `LICENSE` |
| spektrafilm profiles and print LUTs | `resources/profiles/` (the 28 spektrafilm profiles), `resources/print_luts.json`, `resources/spektrafilm_constants.bin`, `resources/neutral_print_filters.json`; by Andrea Volpato, <https://github.com/andreavolpato/spektrafilm> | CC BY-SA 4.0 | `SPEKTRAFILM_LICENSE.txt` |
| Black-and-white product profiles | Tri-X 400, T-Max 100, Neopan 100 Acros II, HP5 Plus 400 and Multigrade IV RC in `resources/profiles/`; SpektraLab's own data (Hanze Qiu), not spektrafilm's | no separate licence is stated; they ship with SpektraLab | `PRODUCT_PROFILES_NOTICE.md` (also `resources/PRODUCT_PROFILES_NOTICE.md`): what each is built from and whose trademarks the names are |
| Digital Intermediate view LUTs | `resources/di/*.cube`, the macOS bundle's own files, copied beside each DI export | SpektraLab's, GPL-3.0-or-later | `LICENSE` |
| sRGB ICC profile | `resources/io/sRGB.icc`, a standard sRGB matrix/TRC profile generated once with Pillow 12.3.0 ImageCms (LittleCMS 2.19); neither is a runtime dependency | SpektraLab's | provenance and SHA-256 in `resources/io/README.txt` |
| Qt 6.11.3 | the `Qt6*.dll`, plugin folders and `qml/` that windeployqt deploys; source <https://code.qt.io/cgit/qt/> (mirrored at <https://github.com/qt>), licensing <https://doc.qt.io/qt-6/licensing.html> | LGPL-3.0-only (modules), with bundled third-party code under the licences its SBOMs list | `Qt/<module>/` (official licence texts), `Qt/manifest.json` (each text's source URL and SHA-256), `Qt-SBOM/` (the SDK's SPDX/CycloneDX SBOMs: exact source revisions and bundled third-party components) |
| LibRaw 0.22.2 | RAW decoding, statically linked; source <https://github.com/LibRaw/LibRaw/tree/0.22.2> | LGPL-2.1 or CDDL-1.0, at the user's choice | `LibRaw-LICENSE.LGPL`, `LibRaw-LICENSE.CDDL`, `LibRaw-COPYRIGHT` |
| TeX Gyre Heros 2.004 | the film edge's text faces, `resources/fonts/` (stand-ins for Helvetica Neue); source <https://mirrors.ctan.org/fonts/tex-gyre/opentype/>, unmodified | GUST Font License (LPPL 1.3c) | `TeX-Gyre-Heros-GUST-FONT-LICENSE.txt`; version and SHA-256 in the source tree's `engine/resources_portable/fonts/NOTICE.md` |
| stb (`stb_image` 2.30, `stb_image_write` 1.16, `stb_truetype` 1.26) | compiled in: JPEG/PNG decode and encode, zlib inflate, the font outlines; <https://github.com/nothings/stb> commit `2c980bb` | MIT (or public domain; MIT taken) | `stb-LICENSE` |
| volk (tag `vulkan-sdk-1.4.341.0`) | compiled in: loads `vulkan-1.dll` from the GPU driver at run time; <https://github.com/zeux/volk> | MIT | `volk-LICENSE.md` |
| Microsoft Visual C++ runtime | `vcruntime140*.dll`, `msvcp140*.dll`, `concrt140.dll`, `vccorlib140.dll`, from Visual Studio 2022's redistributable folder | Microsoft's redistribution terms for Visual Studio's distributable code | none copied |
| Direct3D shader compilers | `d3dcompiler_47.dll`, `dxcompiler.dll`, `dxil.dll`, which windeployqt copies for Qt's D3D backends | Microsoft's redistribution terms for the Windows SDK | none copied |

Not shipped: the Vulkan loader (`vulkan-1.dll` is the GPU driver's) and
`vc_redist.x64.exe` (the zip package leaves it out; the runtime DLLs are
already beside the executable).

## Used to build, not shipped

| Component | Use | Licence |
|---|---|---|
| Vulkan-Headers, tag `vulkan-sdk-1.4.341.0` (<https://github.com/KhronosGroup/Vulkan-Headers>) | headers only, compiled against | Apache-2.0 / MIT |
| glslang 16.6.0 (<https://github.com/KhronosGroup/glslang>) | compiles the GLSL kernels to the shipped SPIR-V | BSD-3-Clause and others, per its `LICENSE.txt` |
| Visual Studio 2022 (MSVC, CMake, Ninja) | the compiler and build tools | Microsoft's licence; CMake BSD-3-Clause; Ninja Apache-2.0 |

The older MinGW build (`build.ps1`) also deploys the MinGW-w64 runtime and
copies its licences to `MinGW/` (source:
<https://github.com/niXman/mingw-builds-binaries/releases/tag/13.1.0-rt_v11-rev1>)
and the Qt archive list to `Qt-packages.json`; the MSVC build has neither.

## Distribution

The SDKs and compilers are local development dependencies outside the Git
source tree. Before distributing a binary, retain these notices and provide
the corresponding source and build/relink information that the selected
licence terms require (GPL-3.0-or-later for SpektraLab, the LGPL for Qt and,
if chosen, LibRaw). The application folder and its zip are a development
build: not a signed installer, and not a release-compliance certification.
