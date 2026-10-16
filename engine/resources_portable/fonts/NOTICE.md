# `engine/resources_portable/fonts/` -- the film edge's faces off Apple

The macOS engine draws the edge print's Helvetica text with CoreText's
Helvetica Neue, which ships with the system and cannot be redistributed. The
Windows and Linux engine draws it with these instead
(`src/pipeline/overscan_raster_portable.cpp`). `engine/CMakeLists.txt` copies
this directory to `<resources>/fonts`, where `spk_engine_create` looks for it.
It is deliberately outside `engine/resources/`, which `engine/build.sh bundle`
syncs into the macOS app: the Mac reads none of it.

| File | Face | Stands in for |
|---|---|---|
| `texgyreheros-regular.otf` | TeX Gyre Heros Regular, version 2.004 (`name` ID 5: "Version 2.004;PS 2.004;hotconv 1.0.49;makeotf.lib2.0.14853") | `HelveticaNeue` |
| `texgyreheros-bold.otf` | TeX Gyre Heros Bold, version 2.004 (same `name` ID 5) | `HelveticaNeue-Bold`, and `HelveticaNeue-Medium` (TeX Gyre Heros has no medium weight) |

SHA-256:

```
6ae1a09d5a940367b7aaaa91ee8bd8a2c333bfe193e7096e23f931357d62081f  texgyreheros-regular.otf
b170162835f4efc288886dd4231406dc47e19b614cf4416836635599d44a7d60  texgyreheros-bold.otf
```

Source: CTAN, <https://mirrors.ctan.org/fonts/tex-gyre/opentype/>, downloaded
2026-10-16 and unmodified. TeX Gyre is GUST e-foundry's extension of URW's
base-35 Nimbus Sans (<http://www.gust.org.pl/projects/e-foundry/tex-gyre>).

Licence: the GUST Font License (`GUST-FONT-LICENSE.txt`, beside the faces), an
instance of the LaTeX Project Public License 1.3c, which allows redistribution
and modification. The faces are data the engine opens at run time, not code
compiled into it, so they ship beside the GPL-3.0-or-later binaries as a
separate work under their own licence. Its request that a modified font be
renamed does not arise: the files are shipped as published.

Both faces are CFF-flavoured OpenType: 1000 units per em, caps 729 units high
(OS/2 `sCapHeight`, and the top of 'H'). overscan.cpp sizes every Helvetica
string from a measured cap height divided by Helvetica Neue's 0.714 per em, so
the portable raster scales these faces by 0.714 / 0.729 to put their caps at the
measured height. Glyph shapes and advances are TeX Gyre Heros's own; how they
compare with a Mac render of the same edge print has not been measured yet.
