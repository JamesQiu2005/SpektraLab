# engine/third_party

Vendored sources and source pins. Licences are shipped with
every build that contains them (`licenses/` in the staged host directory).

| directory | what | version / pin | licence | used by |
|---|---|---|---|---|
| `metal-cpp/` | Apple's C++ Metal bindings | (see its own README) | Apache-2.0 | macOS engine only |
| `volk/` | Vulkan meta-loader: `volk.h`, `volk.c` | zeux/volk tag `vulkan-sdk-1.4.341.0`, commit `d979819fd03de3a7606d6e23d6ff4968942599da` | MIT (`volk/LICENSE.md`) | Vulkan backend (Linux, Windows): loads `libvulkan.so.1` / `vulkan-1.dll` at run time, so no SDK import library is needed to link |
| `stb/` | `stb_image.h` 2.30, `stb_image_write.h` 1.16, `stb_truetype.h` 1.26 | nothings/stb commit `2c980bb59875b0d32144a71867fbdebb2f77cd20` | public domain or MIT, at the user's choice (`stb/LICENSE`); we take MIT | `engine/host/` (JPEG/PNG decode, JPEG/PNG encode, zlib inflate for TIFF/PNG ICC), the portable overscan text raster |
| `libraw-pin/` | What proves the LibRaw source tree is the pinned one: `SHA256SUMS` of all 227 files of upstream master `42f89c16` (`0.23.0-Snapshot202611`), and a README on why master and how to move the pin. No LibRaw source is vendored or patched | LibRaw master `42f89c165763272a5482a254c446337f8048e0df`, tree `865b3ac461d5b734e5bc54683e914ff8dd82b7da` | LibRaw: LGPL-2.1 or CDDL-1.0 (the LGPL-2.1 option is taken) | `engine/cmake/LibRaw.cmake` checks the tree against it at configure time; `engine/setup-libraw.ps1` / `.sh` fetch and verify the tree |

Everything here is GPL-3.0-or-later compatible. The `metal-cpp`, `volk` and
`stb` copies are not compiled by `engine/build.sh` or the Xcode project: the
macOS app is unchanged. `libraw-pin/` holds no code. The `libraw-arw6/` overlay that the 0.22.2 pin
needed was removed on 2026-11-17: the pinned master carries all of it (`libraw-pin/README.md`).
