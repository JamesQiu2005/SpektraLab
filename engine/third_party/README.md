# engine/third_party

Vendored sources and tracked overlays, each pinned. Licences are shipped with
every build that contains them (`licenses/` in the staged host directory).

| directory | what | version / pin | licence | used by |
|---|---|---|---|---|
| `metal-cpp/` | Apple's C++ Metal bindings | (see its own README) | Apache-2.0 | macOS engine only |
| `volk/` | Vulkan meta-loader: `volk.h`, `volk.c` | zeux/volk tag `vulkan-sdk-1.4.341.0`, commit `d979819fd03de3a7606d6e23d6ff4968942599da` | MIT (`volk/LICENSE.md`) | Vulkan backend (Linux, Windows): loads `libvulkan.so.1` / `vulkan-1.dll` at run time, so no SDK import library is needed to link |
| `stb/` | `stb_image.h` 2.30, `stb_image_write.h` 1.16, `stb_truetype.h` 1.26 | nothings/stb commit `2c980bb59875b0d32144a71867fbdebb2f77cd20` | public domain or MIT, at the user's choice (`stb/LICENSE`); we take MIT | `engine/host/` (JPEG/PNG decode, JPEG/PNG encode, zlib inflate for TIFF/PNG ICC), the portable overscan text raster |
| `libraw-arw6/` | Tracked overlay for the pinned LibRaw 0.22.2 source: Sony ARW 6 lossy decoder and A7 V (`ILCE-7M5`) metadata | backported from LibRaw master; provenance in `libraw-arw6/README.md` | LGPL-2.1 or CDDL-1.0, matching LibRaw | Applied by `engine/setup-libraw.ps1` / `.sh` for the Windows/Linux native RAW path |

Everything here is GPL-3.0-or-later compatible. The `metal-cpp`, `volk` and
`stb` copies are not compiled by `engine/build.sh` or the Xcode project: the
macOS app is unchanged. `libraw-arw6/` is not compiled directly; its files are
copied over the verified LibRaw tree during Windows/Linux dependency setup.
