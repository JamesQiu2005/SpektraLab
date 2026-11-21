#!/usr/bin/env bash
# stage-android.sh -- put the engine host and its resources into the Android project.
#
#   engine/build-android.sh            # builds build/android-arm64/{spektralab-host,engine/}
#   desktop/scripts/stage-android.sh   # copies them into src-tauri/gen/android/app (both gitignored there)
#
# The host ships as lib/arm64-v8a/libspektralab_host.so: Android only runs programs from the app's native
# library folder (extracted at install, see the manifest). MainActivity copies assets/engine to app storage.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
src="$repo/build/android-arm64"
app="$repo/desktop/src-tauri/gen/android/app/src/main"
[[ -x "$src/spektralab-host" && -d "$src/engine/vulkan" ]] || { echo "run engine/build-android.sh first" >&2; exit 1; }
kernels=$(ls "$src/engine/vulkan"/*.spv | wc -l)
[[ "$kernels" -eq 65 ]] || { echo "expected 65 kernels in $src/engine/vulkan, found $kernels" >&2; exit 1; }
mkdir -p "$app/jniLibs/arm64-v8a"
install -m 755 "$src/spektralab-host" "$app/jniLibs/arm64-v8a/libspektralab_host.so"
rm -rf "$app/assets/engine"
mkdir -p "$app/assets"
cp -r "$src/engine" "$app/assets/engine"
echo "staged: jniLibs/arm64-v8a/libspektralab_host.so, assets/engine ($kernels kernels)"
