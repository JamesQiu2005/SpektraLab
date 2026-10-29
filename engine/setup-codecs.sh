#!/usr/bin/env bash
# Pinned source dependencies. The system supplies CMake, a compiler and NASM.
set -euo pipefail
# GNU coreutils on Linux; macOS before 14 has only shasum.
command -v sha256sum >/dev/null || sha256sum() { shasum -a 256 "$@"; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deps="${1:-$here/../build/deps/export-codecs}"
mkdir -p "$deps"
deps="$(cd "$deps" && pwd)"
fetch() {
    local name="$1" archive="$2" url="$3" sha="$4" temp
    [[ -f "$deps/$archive" ]] || curl --fail --location "$url" -o "$deps/$archive"
    printf '%s  %s\n' "$sha" "$deps/$archive" | sha256sum --check -
    temp="$(mktemp -d "$deps/.verify-XXXXXXXX")"
    tar -xf "$deps/$archive" -C "$temp"
    if [[ -d "$deps/$name" ]]; then
        if ! diff -qr "$temp/$name" "$deps/$name"; then
            rm -rf -- "$temp"
            echo "Modified codec source $name; existing files not overwritten." >&2
            return 1
        fi
    else
        mv -- "$temp/$name" "$deps/$name"
    fi
    rm -rf -- "$temp"
}
fetch libjpeg-turbo-3.2.0 libjpeg-turbo-3.2.0.tar.gz \
 https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz \
 6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e
fetch libpng-1.6.59 libpng-1.6.59.tar.xz \
 https://download.sourceforge.net/libpng/libpng-1.6.59.tar.xz \
 d80dd2a38a37f803cb9b6ac7b14bd6e74ddc3b654780a8380bdf93523fdb4389
fetch zlib-ng-2.3.3 zlib-ng-2.3.3.tar.gz \
 https://codeload.github.com/zlib-ng/zlib-ng/tar.gz/refs/tags/2.3.3 \
 f9c65aa9c852eb8255b636fd9f07ce1c406f061ec19a2e7d508b318ca0c907d1
