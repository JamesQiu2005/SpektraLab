#!/usr/bin/env bash
# setup-deps.sh -- every build-time dependency of the Linux/Windows host, pinned.
#
#   engine/setup-deps.sh [deps-dir]        (default: <repo>/build/deps)
#
# - LibRaw 0.22.2 (engine/setup-libraw.sh: zip SHA-256, or git commit + tree id)
# - Khronos Vulkan-Headers, tag vulkan-sdk-1.4.341.0 (commit + tree id). Headers
#   only, compile time only; Apache-2.0 OR MIT. The loader itself is not linked:
#   engine/third_party/volk opens libvulkan.so.1 / vulkan-1.dll at run time.
#
# Everything lands in a gitignored directory and is verified before use; an
# existing checkout that does not match its pin is refused, never "fixed".
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deps="${1:-$here/../build/deps}"
mkdir -p "$deps"
deps="$(cd "$deps" && pwd)"

"$here/setup-libraw.sh" "$deps" >/dev/null

pinned_clone() {   # url tag commit tree dest
  local url="$1" tag="$2" commit="$3" tree="$4" dest="$5"
  verify() {
    [[ "$(git -C "$1" rev-parse HEAD)" == "$commit" ]] &&
    [[ "$(git -C "$1" rev-parse 'HEAD^{tree}')" == "$tree" ]] &&
    [[ -z "$(git -C "$1" status --porcelain --ignored)" ]]
  }
  if [[ -d "$dest" ]]; then
    verify "$dest" || { echo "$dest does not match $tag ($commit); not touched." >&2; exit 1; }
    return
  fi
  rm -rf "$dest.partial"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" "$url" "$dest.partial"
  verify "$dest.partial" || { rm -rf "$dest.partial"; echo "$url $tag does not match its pin." >&2; exit 1; }
  mv "$dest.partial" "$dest"
}

pinned_clone https://github.com/KhronosGroup/Vulkan-Headers.git vulkan-sdk-1.4.341.0 \
  b5c8f996196ba4aa6d8f97e52b5d3b6e70f7e4e2 5ae5f51f37c6a7f597df2b9ec45b46d3ab573b1d \
  "$deps/Vulkan-Headers"

echo "dependencies verified in $deps" >&2
echo "$deps"
