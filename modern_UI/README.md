# modern_UI — the 1.x app's tree, shared assets only

SpektraLab 2's Mac app is **`app/SpektraLab`**, a Mac Catalyst app on the SpektraLab engine. The
1.x app (`modern_UI/Spektrafilm`, SwiftUI + AppKit) is history: its sources are no longer in the
tree, and the last 1.x release is tagged in the repository's history.

What stays here is read by other platforms and the engine's scripts, and nothing else:

| path | read by |
|---|---|
| `Spektrafilm/Spektrafilm/Resources/` (licences, film covers, DI LUTs, stock catalogue) | `desktop/scripts/copy-assets.mjs`, `engine/stage-host.sh` |
| `Spektrafilm/Spektrafilm/Localization/Strings.swift` | `desktop/scripts/extract-strings.mjs` |
| `Spektrafilm/Spektrafilm/SpektraLab.icon/` | `desktop/scripts/gen-icons.mjs` |

`engine/build.sh bundle` still syncs the engine's resources into `Resources/engine/` (git-ignored) for
those scripts; the Mac app builds its own with `app/SpektraLab/tools/build_engine_mac.sh`.
