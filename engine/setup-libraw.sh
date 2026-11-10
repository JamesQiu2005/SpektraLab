#!/usr/bin/env bash
# setup-libraw.sh -- the POSIX twin of setup-libraw.ps1.
#
# Fetches the one LibRaw release the native RAW path is validated against
# (0.22.2) into a gitignored dependency directory, verifies it, and applies the
# tracked Sony ARW 6 / A7 V overlay:
#
#   1. the release zip from codeload.github.com, checked against the same
#      SHA-256 setup-libraw.ps1 pins, before anything is extracted; or, when
#      that host is unreachable (some egress proxies refuse it),
#   2. a shallow `git clone` of the 0.22.2 tag, checked against the tag's
#      commit id *and* its tree id -- a content hash over every file -- so a
#      moved tag or a different tree is refused exactly as a bad zip is.
#
# An existing tree is re-verified and never accepts arbitrary local patches:
# every file must be either the pinned archive content or the exact tracked
# overlay. The overlay is then copied over the tree idempotently.
#
#   engine/setup-libraw.sh [deps-dir]      (default: <repo>/build/deps)
#
# The last line of stdout is the source directory, for SPEKTRALAB_LIBRAW_SOURCE.
set -euo pipefail
# GNU coreutils on Linux; macOS before 14 has only shasum.
command -v sha256sum >/dev/null || sha256sum() { shasum -a 256 "$@"; }

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
overlay="$here/third_party/libraw-arw6/files"

if [[ ! -d "$overlay" ]]; then
  echo "Missing tracked LibRaw ARW 6 overlay: $overlay" >&2
  exit 1
fi

verify_git_tree() {   # $1 = a checkout; pinned commit+tree, only overlay edits
  local dir="$1" path
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$git_commit" ]] || return 1
  [[ "$(git -C "$dir" rev-parse 'HEAD^{tree}')" == "$git_tree" ]] || return 1
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    [[ -f "$overlay/$path" ]] || return 1
  done < <(git -C "$dir" status --porcelain=v1 | cut -c4-)
}

verify_zip_tree() {   # $1 = pre (archive or overlay) | final (overlay required)
  python3 - "$archive" "$deps" "$overlay" "$1" <<'PY'
import hashlib, os, sys, zipfile
archive, deps, overlay, mode = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
overlay = os.path.abspath(overlay)
z = zipfile.ZipFile(archive)
overlay_files = {}
for root, _, files in os.walk(overlay):
    for name in files:
        full = os.path.join(root, name)
        overlay_files[os.path.relpath(full, overlay)] = full
if not overlay_files:
    sys.exit(f"Empty LibRaw ARW 6 overlay: {overlay}")
if mode not in ("pre", "final"):
    sys.exit(f"Unknown verification mode: {mode}")

def digest_bytes(data):
    return hashlib.sha256(data).digest()

def digest_file(path):
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).digest()

expected = set()
archive_relatives = set()
top = None
for info in z.infolist():
    if info.is_dir():
        continue
    parts = info.filename.replace('\\', '/').split('/')
    if top is None:
        top = parts[0]
    if parts[0] != top or '..' in parts:
        sys.exit(f"Unsafe LibRaw archive path: {info.filename}")
    rel = '/'.join(parts[1:])
    archive_relatives.add(rel)
    path = os.path.normpath(os.path.join(deps, *parts))
    expected.add(path)
    if not os.path.isfile(path):
        sys.exit(f"Incomplete LibRaw source tree: {path}")
    actual = digest_file(path)
    archive_digest = digest_bytes(z.read(info))
    if rel in overlay_files:
        overlay_digest = digest_file(overlay_files[rel])
        allowed = {overlay_digest} if mode == "final" else {archive_digest, overlay_digest}
        if mode == "pre" and rel == "src/tables/colordata.cpp":
            # The previous ARW 6 colour table, with LF or CRLF.
            allowed.update({
                bytes.fromhex("db2c5648071a3076d771d6eb7fa7324d5b4399e631858d24d3485635544f90eb"),
                bytes.fromhex("7b4bc930b7e0dc8af6f907d8014c1c8c5b0cab1b426f54b38fa596846b426ec2"),
            })
    else:
        allowed = {archive_digest}
    if actual not in allowed:
        sys.exit(f"Modified LibRaw source file: {path}. Existing files were not overwritten.")

for rel, full in overlay_files.items():
    path = os.path.normpath(os.path.join(deps, top, *rel.split('/')))
    expected.add(path)
    # Archive-backed overlay files were checked above, allowing either the
    # pristine archive content or this exact overlay.
    if rel in archive_relatives:
        continue
    if os.path.isfile(path):
        if digest_file(path) != digest_file(full):
            sys.exit(f"Modified LibRaw overlay file: {path}. Existing files were not overwritten.")
    elif mode == "final":
        sys.exit(f"Incomplete LibRaw overlay: {path}")
    elif os.path.exists(path):
        sys.exit(f"Unexpected non-file at LibRaw overlay path: {path}")

for root, _, files in os.walk(os.path.join(deps, top)):
    for name in files:
        path = os.path.normpath(os.path.join(root, name))
        if path not in expected:
            sys.exit(f"Unexpected file in pinned LibRaw source: {path}")
PY
}

apply_overlay() {
  local dir="$1"
  cp -R "$overlay"/. "$dir"/
}

verify_overlay_files() {   # every tracked overlay file is present, byte for byte
  local dir="$1" rel
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    cmp -s "$overlay/$rel" "$dir/$rel" || {
      echo "LibRaw overlay was not applied correctly: $dir/$rel" >&2
      return 1
    }
  done < <(cd "$overlay" && find . -type f | sed 's|^\./||')
}

if [[ -d "$source" ]]; then
  if [[ -d "$source/.git" ]]; then
    verify_git_tree "$source" || { echo "LibRaw at $source is not the pinned $version tree with only the tracked ARW 6 overlay; not touched." >&2; exit 1; }
    apply_overlay "$source"
    verify_overlay_files "$source"
    echo "LibRaw $version: existing git source verified and ARW 6 overlay applied." >&2
    echo "$source"
    exit 0
  elif [[ -f "$archive" ]]; then
    verify_zip_tree pre
  else
    echo "LibRaw at $source has no archive or git metadata to verify it against; remove it and re-run." >&2
    exit 1
  fi
  apply_overlay "$source"
  verify_zip_tree final
  echo "LibRaw $version: existing source verified and ARW 6 overlay applied." >&2
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
  apply_overlay "$source"
  verify_zip_tree final
  echo "LibRaw $version: archive SHA256 verified, extracted, and ARW 6 overlay applied." >&2
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
  apply_overlay "$tmp"
  verify_overlay_files "$tmp"
  mv "$tmp" "$source"
  echo "LibRaw $version: git commit and tree id verified, ARW 6 overlay applied." >&2
fi
echo "$source"
