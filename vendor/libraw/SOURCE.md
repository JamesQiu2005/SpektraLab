# LibRaw in spkraw-host

`macos/spkraw-host` is SpektraLab's RAW decoder helper (engine/raw-helper). It statically links
LibRaw 0.23.0-Snapshot202611, unmodified, under the LGPL-2.1 option of
LibRaw's LGPL-2.1 / CDDL-1.0 dual licence (`LICENSE.LGPL`, `COPYRIGHT` here).

- Source: https://github.com/LibRaw/LibRaw, commit `42f89c165763272a5482a254c446337f8048e0df`
  (`engine/third_party/libraw-pin/README.md` has the tree id and archive checksum).
- Rebuild, with your own LibRaw if you wish: `engine/raw-helper/build-mac.sh` (fetches and verifies the
  pinned tree with `engine/setup-libraw.sh`; the helper's own source is in `engine/`, GPL-3.0-or-later).
- Built universal (arm64, x86_64) for macOS 13.0 and later, without OpenMP.
