# Windows Qt frontend dependencies

SpektraLab code remains GPL-3.0-or-later. The film/paper profiles retain the
upstream CC BY-SA 4.0 notices. The four black-and-white films (Tri-X 400,
T-Max 100, Neopan 100 Acros II, HP5 Plus 400) and the Multigrade IV RC paper
in `resources/profiles/` are SpektraLab's own data, not spektrafilm's:
`PRODUCT_PROFILES_NOTICE.md`, in this folder and in `resources/`, says what
each is built from and whose trademarks the names are. This development build dynamically links the
open-source Qt 6.11.3 Windows MinGW SDK; it does not use a Qt commercial license.

The adjacent `Qt/` directory contains official Qt license texts. The exact SDK
source revisions are recorded in `Qt-SBOM/*.spdx.json`. The Qt base, declarative,
SVG and tools license texts were retrieved at those source revisions. The
shader-tools and translations SBOMs do not identify a commit, so their license
texts were retrieved from separately pinned commits on the Qt 6.11 branch;
`Qt/manifest.json` records every source URL and SHA256. SDK archive URLs and
verified hashes are in `Qt-packages.json`.

- Qt source: <https://code.qt.io/cgit/qt/> (also mirrored at <https://github.com/qt>)
- Qt licensing: <https://doc.qt.io/qt-6/licensing.html>
- Qt module and bundled third-party notices: `Qt-SBOM/` and `Qt/` in this folder
- LibRaw 0.22.2 source: <https://github.com/LibRaw/LibRaw/tree/0.22.2>
- LibRaw license choices and copyright: `LibRaw-LICENSE.LGPL`,
  `LibRaw-LICENSE.CDDL`, `LibRaw-COPYRIGHT`
- TeX Gyre Heros 2.004, the film edge's text faces (`resources/fonts/`):
  GUST Font License (LPPL 1.3c), `TeX-Gyre-Heros-GUST-FONT-LICENSE.txt` and
  `resources/fonts/NOTICE.md`; source <https://mirrors.ctan.org/fonts/tex-gyre/opentype/>
- stb_truetype 1.26, which reads them: MIT, `stb-LICENSE`;
  source <https://github.com/nothings/stb>
- MinGW-w64 compiler/runtime source and licenses:
  `MinGW/` and <https://github.com/niXman/mingw-builds-binaries/releases/tag/13.1.0-rt_v11-rev1>

The SDK and compiler are local development dependencies outside the Git source
tree. Before distributing a release binary, retain these notices and provide
corresponding source and build/relink information for the selected open-source
license terms. The current output is a local development bundle, not a signed
installer or a release-compliance certification.
