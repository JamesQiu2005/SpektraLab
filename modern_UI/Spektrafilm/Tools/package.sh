#!/bin/bash
# package.sh -- build, sign, notarise and wrap SpektraLab in a DMG.
#
# HANDOFF-DISTRIBUTION §2.1 and §2.5: there was no archive step, no `.dmg`, no
# `exportOptions.plist` and no notarisation, and an ad-hoc signature is refused
# by Gatekeeper everywhere except the machine that made it. This is the whole
# path, in the order it has to happen:
#
#     archive -> export -> verify the signature -> DMG -> notarise the DMG
#     -> staple -> spctl
#
#   Tools/package.sh                 as far as this machine's credentials allow
#   Tools/package.sh --dry-run       say what would happen and stop
#
# WHAT YOU NEED, and what happens without it
# ------------------------------------------
#   SPEKTRAFILM_SIGN_IDENTITY   "Developer ID Application: NAME (TEAMID)"
#   SPEKTRAFILM_TEAM_ID         TEAMID
#   SPEKTRAFILM_NOTARY_PROFILE  a notarytool keychain profile (see below)
#
# Without the first two this still archives, exports and builds a DMG, and
# then says -- loudly, at the end, with the reason -- that the result is
# ad-hoc signed and will be refused on any other Mac. That is deliberate: a
# script that refuses to run at all teaches nothing, and a script that
# succeeds quietly on an unshippable artefact is worse.
#
# Create the notary profile once:
#
#   xcrun notarytool store-credentials SPEKTRAFILM_NOTARY \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific>
#   export SPEKTRAFILM_NOTARY_PROFILE=SPEKTRAFILM_NOTARY
#
# ARM ONLY. `ARCHS = arm64`, which is fine for an Apple-silicon release and
# must be *stated* rather than discovered: the DMG's name carries it and so
# should the release notes (HANDOFF-DISTRIBUTION §2.5).
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
proj=$(CDPATH= cd -- "$here/.." && pwd)
out="$proj/build/release"
dry=false
[[ "${1:-}" == "--dry-run" ]] && dry=true

identity=${SPEKTRAFILM_SIGN_IDENTITY:--}
team=${SPEKTRAFILM_TEAM_ID:-}
profile=${SPEKTRAFILM_NOTARY_PROFILE:-}
signed=false
[[ "$identity" != "-" && -n "$team" ]] && signed=true

# The version comes out of gen-project.py, which is the one place it lives.
# Read rather than passed in, so the DMG's name cannot disagree with the
# bundle's `CFBundleShortVersionString`.
version=$(sed -n 's/^MARKETING_VERSION = "\(.*\)"$/\1/p' "$here/gen-project.py")
if [[ -z "$version" ]]; then
  echo "error: could not read MARKETING_VERSION from $here/gen-project.py" >&2
  exit 1
fi
dmg="$out/SpektraLab-$version-arm64.dmg"

say() { printf '\n=== %s\n' "$*"; }
run() { if $dry; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

say "identity"
if $signed; then
  echo "  Developer ID: $identity"
  echo "  team:         $team"
  echo "  notary:       ${profile:-(none -- notarisation will be skipped)}"
else
  echo "  ad-hoc (\$SPEKTRAFILM_SIGN_IDENTITY is unset)"
  echo "  the result will run here and be REFUSED on every other Mac."
fi
echo "  version:      $version (arm64 only)"

# --- 0. the resources the bundle must carry --------------------------------
# Before anything is compiled: a release built without these is a release that
# has to be thrown away, and both are one command each.
say "resources and licences"
run "$here/check-bundle-resources.sh"
$dry || echo "  ok"

# --- 1. regenerate the project with the release identity -------------------
# `gen-project.py` reads the two environment variables, so the signing
# settings land in the generated pbxproj rather than being passed to
# xcodebuild and forgotten by the next generator run.
say "project"
run python3 "$here/gen-project.py"

# --- 2. archive ------------------------------------------------------------
say "archive"
mkdir -p "$out"
archive="$out/SpektraLab.xcarchive"
run rm -rf "$archive"
run xcodebuild -project "$proj/Spektrafilm.xcodeproj" -scheme Spektrafilm \
    -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" archive

# --- 3. export -------------------------------------------------------------
say "export"
plist="$out/exportOptions.plist"
if ! $dry; then
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$( $signed && echo developer-id || echo mac-application )</string>
    <key>signingStyle</key><string>$( $signed && echo manual || echo automatic )</string>
$( $signed && printf '    <key>teamID</key><string>%s</string>\n' "$team" )
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST
fi
run rm -rf "$out/export"
run xcodebuild -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$plist" -exportPath "$out/export"
app="$out/export/SpektraLab.app"

# --- 4. verify the signature ----------------------------------------------
# Checked, not assumed. `--options runtime` is what makes the hardened
# runtime real; `ENABLE_HARDENED_RUNTIME = YES` in gen-project.py is what puts
# it there, and this is where that is confirmed rather than believed.
say "signature"
if ! $dry; then
  codesign -dv --verbose=2 "$app" 2>&1 | sed 's/^/  /'
  codesign --verify --deep --strict --verbose=2 "$app" 2>&1 | sed 's/^/  /'
  if codesign -d --entitlements - "$app" 2>/dev/null | grep -q "allow-jit\|disable-library-validation"; then
    echo "error: the bundle still carries allow-jit or disable-library-validation." >&2
    echo "error: neither is needed by a self-contained Metal app and both weaken" >&2
    echo "error: the hardened runtime notarisation is about (§2.2)." >&2
    exit 1
  fi
  if codesign -dv "$app" 2>&1 | grep -q "Signature=adhoc"; then
    echo "  ad-hoc, as expected without a Developer ID."
  fi
fi

# --- 4b. the floor every Mac has to meet -----------------------------------
# "Every Apple-silicon Mac on macOS 15 or later" is checked on the artefact,
# not believed from the build settings: every Mach-O must be arm64 with a
# minos of at most 15, and every metallib must be stamped for macOS 15. The
# engine's metallib is built outside Xcode, and it once shipped stamped for
# the build machine's macOS 27 -- it would open and fail to render on anything older.
say "deployment floor"
if ! $dry; then
  floor=15
  bad=0
  plist_min=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$app/Contents/Info.plist")
  echo "  LSMinimumSystemVersion $plist_min"
  [[ "${plist_min%%.*}" == "$floor" ]] || { echo "error: LSMinimumSystemVersion is $plist_min" >&2; bad=1; }
  while IFS= read -r -d '' f; do
    file -b "$f" | grep -q "Mach-O" || continue
    archs=$(lipo -archs "$f")
    minos=$(vtool -show-build "$f" 2>/dev/null | awk '/minos/ {print $2; exit}')
    echo "  ${f#"$app/"}: $archs, minos $minos"
    [[ "$archs" == *arm64* ]] || { echo "error: $f has no arm64 slice" >&2; bad=1; }
    [[ "${minos%%.*}" -le "$floor" ]] || { echo "error: $f needs macOS $minos" >&2; bad=1; }
  done < <(find "$app" -type f -print0)
  while IFS= read -r -d '' f; do
    major=$(xcrun -sdk macosx metal-readobj --file-headers "$f" | awk '/PlatformMajor:/ {print $2; exit}')
    echo "  ${f#"$app/"}: metallib for macOS $major"
    [[ "$major" -le "$floor" ]] || { echo "error: $f is stamped for macOS $major" >&2; bad=1; }
  done < <(find "$app" -name '*.metallib' -print0)
  [[ $bad == 0 ]] || exit 1
fi

# --- 5. the DMG ------------------------------------------------------------
say "disk image"
run rm -f "$dmg"
staging="$out/dmg"
if ! $dry; then
  rm -rf "$staging"
  mkdir -p "$staging"
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  # The licence texts are inside the bundle, where the obligation is met; a
  # copy at the top of the DMG is so somebody can read them before installing.
  cp -R "$app/Contents/Resources/Resources/Licenses" "$staging/Licences"
  hdiutil create -volname "SpektraLab $version" -srcfolder "$staging" \
      -ov -format UDZO "$dmg" >/dev/null
  rm -rf "$staging"
  echo "  $dmg ($(du -h "$dmg" | cut -f1))"
fi

# --- 6. notarise and staple -----------------------------------------------
# The DMG is notarised rather than the app: it is what a user downloads, and
# stapling the ticket to it means the first launch works offline.
say "notarisation"
if ! $signed; then
  echo "  skipped: no Developer ID. Gatekeeper will refuse this on any other Mac."
elif [[ -z "$profile" ]]; then
  echo "  skipped: \$SPEKTRAFILM_NOTARY_PROFILE is unset. See the header."
else
  run xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
  run xcrun stapler staple "$dmg"
fi

# --- 7. the only check that matters ---------------------------------------
# `spctl` is Gatekeeper's own answer, and it is the last word rather than the
# first: everything above can succeed and this still say "rejected".
say "gatekeeper"
if $dry; then
  echo "  would run: spctl -a -vv -t install $dmg"
else
  # Captured and then printed, rather than piped straight into `grep -q`:
  # the whole point of this step is that a human reads Gatekeeper's answer,
  # and `grep -q` eats it.
  verdict=$(spctl -a -vv -t install "$dmg" 2>&1 || true)
  printf '%s\n' "$verdict" | sed 's/^/  /'
  if printf '%s' "$verdict" | grep -q accepted; then
    echo "  ACCEPTED -- this will open on a Mac that has never seen the source."
  else
    echo
    echo "  NOT ACCEPTED. This artefact is not distributable yet."
    $signed || echo "  Cause: no Developer ID Application certificate (§2.1)."
    [[ -n "$profile" ]] || echo "  Cause: not notarised (§2.1 steps 4-5)."
    echo "  Verify on a machine that has never seen this checkout; spctl on the"
    echo "  build machine can pass for reasons a stranger's Mac will not have."
    exit 1
  fi
fi
