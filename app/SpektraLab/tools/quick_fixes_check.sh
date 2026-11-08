#!/bin/bash
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/Sources"
mkdir -p "$here/build/tools"
swiftc -O -parse-as-library "$src/Model/Format.swift" "$src/Model/Localization.swift" \
  "$src/Features/Develop/CanvasZoom.swift" \
  "$src/Services/LibraryOrdering.swift" "$here/tools/quick_fixes_selftest.swift" \
  -o "$here/build/tools/quick_fixes_selftest"
"$here/build/tools/quick_fixes_selftest"
