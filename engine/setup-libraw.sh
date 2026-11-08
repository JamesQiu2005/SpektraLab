#!/usr/bin/env bash
# setup-libraw.sh -- the POSIX twin of setup-libraw.ps1.
#
# Fetches the one LibRaw release the native RAW path is validated against
# (0.22.2) into a gitignored dependency directory, and verifies it before it
# is used:
#
#   1. the release zip from codeload.github.com, checked against the same
#      SHA-256 setup-libraw.ps1 pins, before anything is extracted; or, when
#      that host is unreachable (some egress proxies refuse it),
#   2. a shallow `git clone` of the 0.22.2 tag, checked against the tag's
#      commit id *and* its tree id -- a content hash over every file -- so a
#      moved tag or a different tree is refused exactly as a bad zip is.
#
# An existing tree is re-verified and never overwritten, so a locally patched
# LibRaw cannot silently become "the pinned source".
#
#   engine/setup-libraw.sh [deps-dir]      (default: <repo>/build/deps)
#
# The last line of stdout is the source directory, for SPEKTRALAB_LIBRAW_SOURCE.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deps="${1:-$here/../build/deps}"
mkdir -p "$deps"
deps="$(cd "$deps" && pwd)"

version=0.22.2
url="https://codeload.github.com/LibRaw/LibRaw/zip/refs/tags/$version"
zip_sha256=02275a04cf0d1477ab9fd7ee231ddea59e7b14497458da6e3ba957517d6655c7
git_url="https://github.com/LibRaw/LibRaw.git"
git_commit=b93f6e45c194f5df9b02a43b1af9a54b4f41f33f
git_tree=0fd7d10c62714db90d9fa922230916a030c2d6d3
archive="$deps/LibRaw-$version.zip"
source="$deps/LibRaw-$version"

verify_git_tree() {   # $1 = a checkout; succeeds only on the pinned commit+tree, clean
  local dir="$1"
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$git_commit" ]] || return 1
  [[ "$(git -C "$dir" rev-parse 'HEAD^{tree}')" == "$git_tree" ]] || return 1
  [[ -z "$(git -C "$dir" status --porcelain --ignored)" ]] || return 1
}

verify_zip_tree() {   # the extracted tree against the verified archive, byte for byte
  python3 - "$archive" "$deps" <<'PY'
import hashlib, os, sys, zipfile
archive, deps = sys.argv[1], sys.argv[2]
z = zipfile.ZipFile(archive)
expected = set()
for info in z.infolist():
    if info.is_dir():
        continue
    path = os.path.normpath(os.path.join(deps, info.filename))
    expected.add(path)
    if not os.path.isfile(path):
        sys.exit(f"Incomplete LibRaw source tree: {path}")
    if hashlib.sha256(z.read(info)).digest() != hashlib.sha256(open(path, 'rb').read()).digest():
        sys.exit(f"Modified LibRaw source file: {path}. Existing files were not overwritten.")
top = os.path.join(deps, z.namelist()[0].split('/')[0])
for root, _, files in os.walk(top):
    for f in files:
        p = os.path.normpath(os.path.join(root, f))
        if p not in expected:
            sys.exit(f"Unexpected file in pinned LibRaw source: {p}")
PY
}

if [[ -d "$source" ]]; then
  if [[ -d "$source/.git" ]]; then
    verify_git_tree "$source" || { echo "LibRaw at $source is not the pinned, clean $version tree; not touched." >&2; exit 1; }
  elif [[ -f "$archive" ]]; then
    verify_zip_tree
  else
    echo "LibRaw at $source has no archive or git metadata to verify it against; remove it and re-run." >&2
    exit 1
  fi
  echo "LibRaw $version: existing source verified." >&2
  echo "$source"
  exit 0
fi

if [[ ! -f "$archive" ]] && curl -fsSL --retry 2 -o "$archive.partial" "$url" 2>/dev/null; then
  mv "$archive.partial" "$archive"
fi
rm -f "$archive.partial"

if [[ -f "$archive" ]]; then
  actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  if [[ "$actual" != "$zip_sha256" ]]; then
    echo "LibRaw archive checksum mismatch ($actual); nothing was extracted or changed." >&2
    exit 1
  fi
  python3 - "$archive" "$deps" "$version" <<'PY'
import os, sys, zipfile
archive, deps, version = sys.argv[1:]
z = zipfile.ZipFile(archive)
for n in z.namelist():
    parts = n.rstrip('/').split('/')
    if parts[0] != f"LibRaw-{version}" or '..' in parts or n.startswith('/'):
        sys.exit(f"Unsafe LibRaw archive path: {n}")
z.extractall(deps)
PY
  echo "LibRaw $version: archive SHA256 verified and extracted." >&2
else
  echo "codeload.github.com unreachable; falling back to a pinned git clone." >&2
  tmp="$source.partial"
  rm -rf "$tmp"
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$version" "$git_url" "$tmp"
  if ! verify_git_tree "$tmp"; then
    rm -rf "$tmp"
    echo "LibRaw git clone does not match the pinned commit $git_commit / tree $git_tree." >&2
    exit 1
  fi
  mv "$tmp" "$source"
  echo "LibRaw $version: git commit and tree id verified." >&2
fi
echo "$source"
