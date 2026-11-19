# Develop

**English** · [简体中文](README.zh-CN.md)

A film-emulation darkroom for Linux. Open a RAW or a JPEG, pick a film and a paper, and get a
physically modelled print: light traced through the film's dye layers and the paper's, with grain,
halation, DIR couplers and the enlarger's filter pack, rendered on your GPU through Vulkan.

**Develop is an unofficial Linux fork of [SpektraLab](https://github.com/JamesQiu2005/SpektraLab)**,
whose engine is derived from [spektrafilm](https://github.com/andreavolpato/spektrafilm) by Andrea
Volpato. It is not affiliated with or endorsed by either project. The film model, the measured
profiles and the print and scan model are theirs; Develop is the Linux port and the app built on it.

## What it does

- **130 film and paper stocks**: colour negative, slide, motion-picture and black-and-white films,
  printed on colour or Multigrade paper, or scanned. Sorted by brand.
- **The whole engine on Vulkan**: every effect the Mac app has renders on Linux, including the film
  edge and date back, lens aberrations and diffusion filters, light leaks, the Digital Intermediate,
  local scene layers and the HDR slide scan.
- **The editor shows what exports**: the picture on screen is the file you get.
- **Develop's own additions**:
  - Lens correction for distortion, vignetting and colour fringes from lensfun's database, plus
    "My Lenses" for manual lenses lensfun does not know.
  - Local Layers: graduated and radial masks that change the light before it reaches the film.
  - Half-frame pairs and double exposures.
  - HSL, channel mixer and vibrance.
  - Borders and watermarks.
  - Multi-photo layouts: diptychs, triptychs, grids and cinematic stills.
  - Export to JPEG, PNG and 16-bit TIFF in sRGB, Display P3, Adobe RGB or ProPhoto.
  - An Advanced panel with engine settings no SpektraLab interface exposes.

## No network, by design

Develop cannot reach the internet. A seccomp filter installed before anything else starts allows
only local sockets, and the app refuses to run if the filter cannot be put in place. It applies to
the window, its web view and the engine. There are no update checks, telemetry, remote fonts or
accounts. Your photos never leave your machine.

## Install

There is no published release yet. Build it from source (below); the build makes a `.deb` and a snap.

Develop needs a GPU with a Vulkan driver. It has been developed on Ubuntu 26.04 with Intel graphics
(Mesa). The `.deb` pulls in `libvulkan1`, `liblensfun1`, `liblensfun-data-v1`, `fonts-urw-base35`,
`fonts-liberation-sans-narrow` and `fonts-dejavu-core`. The snap carries its own copies.

## Build

```sh
engine/build-linux.sh                 # the engine and its host, staged in build/host-linux-x64
cd desktop && npm ci
npx tauri build --no-bundle           # the app: desktop/src-tauri/target/release/develop
SPEKTRALAB_BUNDLES=deb node scripts/package.mjs linux    # .deb in desktop/release/linux
sh scripts/build-snap.sh              # snap from that .deb, in desktop/release/snap
```

Building needs a C++20 compiler, CMake, Ninja, the Vulkan headers and `glslangValidator`, Node 22 with
npm, Rust (stable), the WebKitGTK 4.1 development packages Tauri asks for, and `liblensfun-dev` for
lens correction (it builds without it, minus that feature).

## Test

```sh
(cd build/linux && ctest)             # the Vulkan kernels against float64 references
python3 engine/tests/host_smoke.py --host build/host-linux-x64/spektralab-host \
    --resources build/host-linux-x64/engine
(cd desktop && npm run check)         # typecheck, lint, unit tests
(cd desktop/src-tauri && cargo test)  # includes the no-network test
```

Upstream's own engine checks (`engine/tests/*_checks.py`) run against the Linux engine as well.

## Credits and licence

**Develop is based on SpektraLab, whose engine is derived from spektrafilm by Andrea
Volpato (GPL-3.0-or-later).** spektrafilm's 28 measured film and paper profiles and the print LUTs are
used unmodified. The other profiles are built from manufacturers' published data sheets
(`engine/resources_product/NOTICE.md`). Film and paper names are their owners' trademarks; they say
which published data a profile was built from.

| | |
|---|---|
| the app and the engine | GPL-3.0-or-later (`license/LICENSE`) |
| spektrafilm's film and paper profiles, the print LUTs | CC BY-SA 4.0 (`license/SPEKTRAFILM_LICENSE.txt`) |
| lensfun (linked, and its lens database) | LGPL-3.0 / CC BY-SA 3.0 |
| stb_truetype | public domain / MIT |

SpektraLab™ and its icon belong to their owners. Develop uses its own name and icon, as SpektraLab's
licence terms ask of published forks.
