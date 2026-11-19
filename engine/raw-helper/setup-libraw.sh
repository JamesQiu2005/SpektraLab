#!/usr/bin/env bash
# setup-libraw.sh -- the POSIX twin of setup-libraw.ps1.
#
# Fetches the one LibRaw source tree the native RAW path is validated against
# into a gitignored dependency directory and verifies it. That tree is an
# upstream master checkout, not a release: LibRaw's release tags stop at
# 0.22.3, and only master decodes the modern bodies this product needs (Sony
# ARW 6 / A7 V, Canon EOS R6 Mark III, Nikon HE/HE*, Fujifilm GFX 100RF).
#
#   pin     LibRaw master 42f89c165763272a5482a254c446337f8048e0df
#           ("Planebuf limit: change bytes to items", 2026-11-16), which
#           reports itself as 0.23.0-Snapshot202611
#   tree    865b3ac461d5b734e5bc54683e914ff8dd82b7da (git tree id: a content
#           hash over every file and mode)
#
# Two ways in, both verified before anything is used:
#
#   1. the commit's zip from codeload.github.com, checked against its SHA-256
#      *and* against the git tree id recomputed from the archive's entries,
#      before anything is extracted; or, when that host is unreachable,
#   2. a depth-1 `git fetch` of the commit, checked against the commit id and
#      the tree id.
#
# An existing tree is re-verified file by file and refused -- never "fixed" --
# if anything differs: no file may be added, removed or edited. There is no
# overlay any more: master carries everything the 0.22.2 overlay backported
# (RAW-SUPPORT-20261117.md, "The LibRaw pin").
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

# The pin. engine/cmake/LibRaw.cmake and engine/setup-libraw.ps1 carry the
# same four values; engine/tests/raw_pin_guard.sh fails if they drift apart.
git_commit=42f89c165763272a5482a254c446337f8048e0df
git_tree=865b3ac461d5b734e5bc54683e914ff8dd82b7da
zip_sha256=95a5c092fd12c16359b8a13afac58bf1b4aaad50e27d2c9221f275c496b79ca2
name="LibRaw-$git_commit"
url="https://codeload.github.com/LibRaw/LibRaw/zip/$git_commit"
git_url="${SPEKTRALAB_LIBRAW_GIT_URL:-https://github.com/LibRaw/LibRaw.git}"
archive="$deps/$name.zip"
source="$deps/$name"

verify_git_tree() {   # $1 = a checkout: the pinned commit and tree, nothing else
  local dir="$1"
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$git_commit" ]] || return 1
  [[ "$(git -C "$dir" rev-parse 'HEAD^{tree}')" == "$git_tree" ]] || return 1
  [[ -z "$(git -C "$dir" status --porcelain=v1 --ignored --untracked-files=all)" ]] || return 1
}

# $1 = archive | extract | tree. "archive": the zip's own entries hash to the
# pinned git tree. "tree": every file on disk is the archive's, byte for byte,
# and nothing else is there. "extract": safe extraction into $deps.
zip_tool() {
  python3 -I - "$archive" "$deps" "$name" "$git_tree" "$1" <<'PY'
import hashlib, os, stat, sys, zipfile
archive, deps, name, want_tree, mode = sys.argv[1:]
z = zipfile.ZipFile(archive)
files = [i for i in z.infolist() if not i.is_dir()]
for info in z.infolist():
    parts = info.filename.rstrip('/').split('/')
    if parts[0] != name or '..' in parts or info.filename.startswith('/') or '\\' in info.filename:
        sys.exit(f"Unsafe LibRaw archive path: {info.filename}")

if mode == "archive":
    root = {}
    for info in files:
        parts = info.filename.split('/')[1:]
        kind = (info.external_attr >> 16) & 0o177777
        gmode = b'120000' if stat.S_ISLNK(kind) else b'100755' if kind & 0o111 else b'100644'
        data = z.read(info)
        node = root
        for p in parts[:-1]:
            node = node.setdefault(p, {})
        node[parts[-1]] = (gmode, hashlib.sha1(b'blob %d\0' % len(data) + data).digest())
    def tree(node):
        entries = []
        for key, value in node.items():
            if isinstance(value, dict):
                entries.append((key + '/', b'40000', key, tree(value)))
            else:
                entries.append((key, value[0], key, value[1]))
        entries.sort(key=lambda e: e[0].encode())
        body = b''.join(m + b' ' + n.encode() + b'\0' + h for _, m, n, h in entries)
        return hashlib.sha1(b'tree %d\0' % len(body) + body).digest()
    got = tree(root).hex()
    if got != want_tree:
        sys.exit(f"LibRaw archive is not the pinned tree {want_tree} (it hashes to {got})")
elif mode == "extract":
    if any(stat.S_ISLNK((i.external_attr >> 16) & 0o177777) for i in files):
        sys.exit("LibRaw archive contains a symbolic link; refusing to extract it")
    z.extractall(deps)
elif mode == "tree":
    expected = set()
    for info in files:
        path = os.path.normpath(os.path.join(deps, *info.filename.split('/')))
        expected.add(path)
        if not os.path.isfile(path) or os.path.islink(path):
            sys.exit(f"Incomplete LibRaw source tree: {path}")
        with open(path, 'rb') as f:
            if hashlib.sha256(f.read()).digest() != hashlib.sha256(z.read(info)).digest():
                sys.exit(f"Modified LibRaw source file: {path}. Existing files were not overwritten.")
    for top, _, names in os.walk(os.path.join(deps, name)):
        for n in names:
            path = os.path.normpath(os.path.join(top, n))
            if path not in expected:
                sys.exit(f"Unexpected file in pinned LibRaw source: {path}")
else:
    sys.exit(f"unknown mode {mode}")
PY
}

verify_archive() {
  local actual
  actual="$(sha256sum "$archive" | cut -d' ' -f1)"
  if [[ "$actual" != "$zip_sha256" ]]; then
    echo "LibRaw archive checksum mismatch ($actual); nothing was extracted or changed." >&2
    return 1
  fi
  zip_tool archive
}

if [[ -d "$source" ]]; then
  if [[ -d "$source/.git" ]]; then
    verify_git_tree "$source" || { echo "LibRaw at $source is not the pinned commit $git_commit / tree $git_tree, or has local changes; not touched." >&2; exit 1; }
    echo "LibRaw $git_commit: existing git checkout verified (commit and tree id)." >&2
  elif [[ -f "$archive" ]]; then
    verify_archive || exit 1
    zip_tool tree || exit 1
    echo "LibRaw $git_commit: existing source verified file by file against the pinned archive." >&2
  else
    echo "LibRaw at $source has no archive or git metadata to verify it against; remove it and re-run." >&2
    exit 1
  fi
  echo "$source"
  exit 0
fi

if [[ ! -f "$archive" ]] && curl -fsSL --retry 2 -o "$archive.partial" "$url" 2>/dev/null; then
  mv "$archive.partial" "$archive"
fi
rm -f "$archive.partial"

if [[ -f "$archive" ]]; then
  verify_archive || exit 1
  zip_tool extract
  zip_tool tree
  echo "LibRaw $git_commit: archive SHA-256 and tree id verified, extracted." >&2
else
  echo "codeload.github.com unreachable; falling back to a pinned git fetch." >&2
  tmp="$source.partial"
  rm -rf "$tmp"
  git -c init.defaultBranch=pin init -q "$tmp"
  git -C "$tmp" fetch -q --depth 1 "$git_url" "$git_commit"
  git -C "$tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
  if ! verify_git_tree "$tmp"; then
    rm -rf "$tmp"
    echo "LibRaw git fetch does not match the pinned commit $git_commit / tree $git_tree." >&2
    exit 1
  fi
  mv "$tmp" "$source"
  echo "LibRaw $git_commit: git commit and tree id verified." >&2
fi
echo "$source"
