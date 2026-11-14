#!/bin/bash
# check_app.sh -- sourced (never run) by every script that launches the built app for a check: the app it launches
# is a COPY with a bundle identifier of the run's own, so the check can never read or write the preferences of
# the build it was copied from.
#
# Why (found 2026-11-13, twice): `CFFIXED_USER_HOME` moves the library, the caches and Application Support into a
# scratch home, and `--defaults-suite` gives the model's settings a suite of their own, but some two dozen
# singletons (`DevelopPanelPrefs.shared`, `AdjustLayout.shared`, every `@AppStorage`) read and write
# `UserDefaults.standard`, and that goes through cfprefsd to `~/Library/Preferences/<bundle id>.plist` -- for a
# Debug build `com.spektralab.mac.local`, the domain the owner's own Debug app reads. A copy named
# `com.spektralab.mac.check.<run>` has a domain nobody else reads, removed at the end.
#
#   source "$here/tools/check_app.sh"
#   check_app_isolate "$app"     # sets app, bin and check_bundle_id to the copy's; prints nothing
#   ...launch "$bin"...
#   check_app_cleanup            # also run on EXIT: the copy, its domain's plist, its caches, its saved state
#
# What else keys off the bundle identifier, and why a check's own is harmless: Application Support's folder
# (`ImportService.root`: under the scratch home either way, so only its name changes -- `history_check.sh` reads
# it from the copy's Info.plist); the agents' socket (`AgentWire.socketPath`: a name of its own, which only keeps a
# check's agent from answering a Debug app's); the Storage page's cache folders (`LibraryPersistence.cacheFolders`:
# `~/Library/Caches/<id>` and `DARWIN_USER_CACHE_DIR/<id>`, the latter Metal's and Core Image's compiled shaders,
# so a check's first render compiles them afresh -- a one-off cost, not one the checks' bars measure; removed
# here). No keychain item is used by the app.
check_app_isolate() {
  local source_app=$1
  [[ -d "$source_app" ]] || { echo "check_app: no app at $source_app"; return 2; }
  check_app_dir=$(mktemp -d "${TMPDIR:-/tmp}/spk-check-app.XXXXXX")
  local tag; tag=$(basename "$check_app_dir" | tr -cd 'A-Za-z0-9' | tr 'A-Z' 'a-z')
  check_bundle_id="com.spektralab.mac.check.$tag"
  ditto "$source_app" "$check_app_dir/SpektraLab.app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $check_bundle_id" "$check_app_dir/SpektraLab.app/Contents/Info.plist"
  # The Info.plist is sealed by the outer signature only; the dylibs inside keep their own.
  codesign --force --sign - --preserve-metadata=entitlements,flags "$check_app_dir/SpektraLab.app" > /dev/null 2>&1 \
    || { echo "check_app: could not re-sign the copy"; return 2; }
  app="$check_app_dir/SpektraLab.app"
  bin="$app/Contents/MacOS/SpektraLab"
  # Refuse rather than run in a shared domain.
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "$check_bundle_id" ]] \
    || { echo "check_app: the copy kept its identifier"; return 2; }
  trap check_app_cleanup EXIT
}

check_app_cleanup() {
  [[ -n "${check_bundle_id:-}" ]] || return 0
  local id=$check_bundle_id
  defaults delete "$id" > /dev/null 2>&1 || true
  rm -f "$HOME/Library/Preferences/$id.plist"
  rm -rf "$HOME/Library/Caches/$id" "$HOME/Library/Saved Application State/$id.savedState" "$HOME/Library/HTTPStorages/$id"
  local buffer; buffer=$(getconf DARWIN_USER_CACHE_DIR 2> /dev/null || true)
  [[ -n "$buffer" ]] && rm -rf "${buffer%/}/$id"
  buffer=$(getconf DARWIN_USER_TEMP_DIR 2> /dev/null || true)
  [[ -n "$buffer" ]] && rm -rf "${buffer%/}/$id"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$check_app_dir/SpektraLab.app" > /dev/null 2>&1 || true
  rm -rf "$check_app_dir"
  check_bundle_id=""
}
