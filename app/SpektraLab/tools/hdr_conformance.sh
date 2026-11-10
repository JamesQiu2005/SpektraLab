#!/bin/bash
# hdr_conformance.sh -- how an HDR photo carries its gain map, and whether its readers agree (RFC-046).
#
#   tools/hdr_conformance.sh FILE... [--expect iso|appleCamera] [--hdrgm]
#
# For the Mac's exports (HDR port, 2026-11-06, D8), with Adobe's hdrgm:
# a JPEG's map image's hdrgm fields read straight from its bytes and held to its ISO declaration, field for
# field; `--hdrgm` fails a JPEG without them.
#
# Standalone (tools/hdr_conformance.swift): the base, the ISO 21496-1 map, Apple's own map and its MakerApple
# headroom, how many map images are stored, the layout that makes, and how far apart the two kinds of reader
# read each pixel. Apple's own camera files and every 8-bit JPEG or HEIF SpektraLab writes of an HDR frame read as `appleCamera`: one map, declared
# both ways.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="$here/build/tools"
mkdir -p "$out"
swiftc -O -o "$out/hdr_conformance" "$here/tools/hdr_conformance.swift" 2> "$out/hdr-conformance-build.log" \
  || { grep -E "error" "$out/hdr-conformance-build.log" | head -20; exit 1; }
"$out/hdr_conformance" "$@"
