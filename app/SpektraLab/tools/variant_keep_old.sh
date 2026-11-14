#!/bin/bash
# variant_keep_old.sh -- builds tools/variant_keep_old.swift with 2.3.2's own library coder, from the release commit
# 88685135 ("chore(release): 2.3.2"; there is no 2.3.2 tag): its `StoredFrame`, `StoredFolder` and `StoredLibrary`
# (Services/LibraryPersistence.swift, as written, less the two conversions to and from `LibraryFrame`/`LinkedFolder`,
# which are not part of the coding), and the model files their coding reads. Leaves build/tools/variant_keep_old.
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
rev=88685135
out="$here/build/tools/variant-keep-old"
rm -rf "$out"; mkdir -p "$out"
for f in Format Localization FeatureFlags FilmParams FrameEdit Adjustments CurveMath Geometry FilmEdge Stock HalfFramePair CameraCrop Sources; do
  git -C "$here" show "$rev:app/SpektraLab/Sources/Model/$f.swift" > "$out/$f.swift"
done
# FrameOrigin, OriginalState, PictureRef: the head of Model/LibraryFrame.swift (the frame type itself is not read).
git -C "$here" show "$rev:app/SpektraLab/Sources/Model/LibraryFrame.swift" | awk '/^enum DevelopState/{exit} {print}' > "$out/LibraryFrame.swift"
# DevelopedPicture's stored fields (Engine/DevelopedPicture.swift's struct, without its extensions).
git -C "$here" show "$rev:app/SpektraLab/Sources/Engine/DevelopedPicture.swift" | awk '/^struct DevelopedPicture/{f=1} f{print} f&&/^}/{exit}' > "$out/DevelopedPicture.swift"
git -C "$here" show "$rev:app/SpektraLab/tools/selftest_theme_shim.swift" > "$out/shim.swift"
{ echo "import Foundation"
  git -C "$here" show "$rev:app/SpektraLab/Sources/Services/LibraryPersistence.swift" \
    | awk '/^\/\/\/ A frame as it is written./{f=1} /^\/\/\/ Reads the library once/{f=0} f' \
    | python3 -I -c '
import sys
s = sys.stdin.read()
a = s.index("    static func picture(_ ref: PictureRef)"); b = s.index("/// A linked folder as it is written")
s = s[:a] + "}\n\n" + s[b:]
a = s.index("    init(_ f: LinkedFolder)"); b = s.index("struct StoredLibrary")
print(s[:a] + "}\n\n" + s[b:])'
} > "$out/LibraryCoder.swift"
swiftc -O -parse-as-library "$out"/*.swift "$here/tools/variant_keep_old.swift" -o "$here/build/tools/variant_keep_old" 2> "$out/build.log" \
  || { grep -E "error" "$out/build.log" | head -20; exit 1; }
echo "variant_keep_old: 2.3.2's coder ($rev) built"
