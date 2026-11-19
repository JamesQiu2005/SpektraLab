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
- Half-frame pairs, double exposures, HSL, channel mixer, vibrance, watermarks, light leaks, lens
  characters and the film edge, as in SpektraLab's Mac app.
- Export to JPEG, PNG and 16-bit TIFF in sRGB, Display P3, Adobe RGB or ProPhoto.

## How Develop differs from SpektraLab

SpektraLab is a Mac app on Metal. Its repository also has Windows viewers and an engine that builds
on Linux, but on Linux and Windows that engine refused many of the Mac's effects. Develop is a full
Linux editor built on that engine.

**What Develop adds**

| | Develop | SpektraLab |
|---|---|---|
| Linux desktop editor | yes, with a `.deb` and a snap | engine and host only |
| Engine effects on Vulkan (Linux, Windows) | all of them: film edge and date back, Digital Intermediate, scene latitude, contrast mask, lens aberrations and diffusion filters, light leaks, scene layers, HDR slide scan | most of these refused |
| Colour on Vulkan | fixed: a red cast on every Vulkan render since 2.4.0 (a blur mode the Vulkan kernels lacked) | red cast |
| Film and paper stocks | 130, including 93 new film profiles built from manufacturers' published data sheets | 38 |
| Network | none: blocked by a seccomp filter, no update checks | checks for updates |
| Lens correction | lensfun's database, plus "My Lenses" for manual lenses it does not know | on the Mac only |
| Local Layers | graduated, radial and whole-frame masks of exposure and warmth, on the engine's scene layers | (engine feature) |
| Multi-photo layouts | diptychs, triptychs, grids and cinematic stills, with gaps and borders | no |
| Borders | a print border of any grey | no |
| Advanced panel | development contrast, lens and scanner softness, highlight headroom, scanner white and black points | not exposed |

**What SpektraLab has that Develop does not**

- The photo library, Capture One catalogue reading and the Light Table.
- HDR: showing a picture on an HDR screen and exporting HDR (gain-map) files. The engine's HDR slide
  scan is ported, but Linux's web view cannot show HDR.
- Check for Updates. Left out on purpose: Develop has no network access.
- The iPhone and iPad app, and builds for the Mac and Windows.

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
