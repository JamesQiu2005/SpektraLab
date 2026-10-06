#!/usr/bin/env bash
# stage-host.sh <cmake-build-dir> <stage-dir> <host-binary-name>
#
# Copies a built spektralab-host, the engine resources it renders with and the
# licence texts its binary and data carry into the layout HOST-PROTOCOL.md §4
# names. Shared by build-linux.sh and build-windows-cross.sh.
#
# What the binary carries, and therefore what licenses/ must hold:
#   SpektraLab, GPL-3.0-or-later            license/LICENSE
#   spektrafilm (upstream engine), GPL-3.0  license/SPEKTRAFILM_LICENSE.txt
#   profiles and LUTs, CC BY-SA 4.0         engine/resources/profiles, print LUTs
#   LibRaw 0.22.2, LGPL-2.1 (of its LGPL/CDDL dual licence), statically linked
#   stb (public domain / MIT), volk (MIT), Vulkan-Headers (Apache-2.0 OR MIT,
#   compile time only)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
build="$1"; stage="$2"; binary="$3"
deps="${SPEKTRALAB_DEPS_DIR:-$repo/build/deps}"

host="$build/engine/host/$binary"
[[ -f "$host" ]] || { echo "no $host; build first" >&2; exit 1; }
[[ -d "$build/engine/resources/vulkan" ]] || { echo "no SPIR-V in $build/engine/resources/vulkan" >&2; exit 1; }

rm -rf "$stage.partial"
mkdir -p "$stage.partial/engine" "$stage.partial/licenses"
cp "$host" "$stage.partial/"
cp -R "$build/engine/resources/." "$stage.partial/engine/"
[[ -f "$stage.partial/engine/io/sRGB.icc" ]] || { echo "io/sRGB.icc missing from resources" >&2; exit 1; }
ls "$stage.partial/engine/vulkan/"*.spv >/dev/null

lic="$stage.partial/licenses"
cp "$repo/license/LICENSE" "$lic/SpektraLab-GPL-3.0.txt"
cp "$repo/license/SPEKTRAFILM_LICENSE.txt" "$lic/spektrafilm-LICENSE.txt"
cp "$repo/modern_UI/Spektrafilm/Spektrafilm/Resources/Licenses/Profiles-and-LUTs-CC-BY-SA-4.0.txt" "$lic/"
cp "$repo/modern_UI/Spektrafilm/Spektrafilm/Resources/Licenses/Profiles-and-LUTs-CHANGELOG.txt" "$lic/"
cp "$deps/LibRaw-0.22.2/LICENSE.LGPL" "$lic/LibRaw-LGPL-2.1.txt"
cp "$deps/LibRaw-0.22.2/COPYRIGHT" "$lic/LibRaw-COPYRIGHT.txt"
cp "$here/third_party/stb/LICENSE" "$lic/stb-LICENSE.txt"
cp "$here/third_party/volk/LICENSE.md" "$lic/volk-LICENSE.txt"
cp "$deps/Vulkan-Headers/LICENSE.md" "$lic/Vulkan-Headers-LICENSE.txt"
cat > "$lic/README.txt" <<'EOF'
spektralab-host is free software under the GNU General Public License,
version 3 or (at your option) any later version (SpektraLab-GPL-3.0.txt).
The full corresponding source is the SpektraLab repository at the commit
this build was made from.

Bundled third-party components:
  LibRaw 0.22.2        LGPL-2.1, statically linked; source: libraw.org, and
                       engine/setup-libraw.sh fetches the exact pinned tree.
  stb_image, stb_image_write, stb_truetype   public domain / MIT (stb-LICENSE.txt)
  volk                 MIT (volk-LICENSE.txt)
  Vulkan-Headers       Apache-2.0 OR MIT, compile time only
Film and paper profiles and print LUTs under engine/: CC BY-SA 4.0
(Profiles-and-LUTs-CC-BY-SA-4.0.txt, with attribution in the CHANGELOG).
EOF
rm -rf "$stage"
mv "$stage.partial" "$stage"
