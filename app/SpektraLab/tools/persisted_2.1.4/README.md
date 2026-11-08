# persisted_2.1.4 — what a 2.1.4 library keeps, for `tools/persisted_check.swift`

Eight files written by the 2.1.4 release's own types, through the writer that is now
`tools/persisted_fixture_writer.swift` (the recipes' destinations set afterwards, below): the formats a
person's work lives in under `Application Support/<bundle id>/`.

| file | stands for |
|---|---|
| `frame-edit.json` | a frame's `edit` in `library.json`, every optional field set |
| `frame-edit-default.json` | a new frame's edit (`FrameEdit()`) |
| `pair.spektrapair` | a half-frame pair: `Pairs/<name>.spektrapair`, and `library.json`'s `frames[].pair` |
| `settings-clip.json` | the clipboard, and a saved look's `clip` |
| `look-presets.json` | `look-presets.json`, written by `PresetStore.save` itself |
| `export-recipes.json` | `export-recipes.json`: the built-ins and one recipe per size |
| `lighttable.json` | `lighttable.json` |
| `enums.json` | every raw value of every String enum that reaches one of them |

- **Synthetic.** Paths are under `/Volumes/Fixture`, ids are fixed, nothing comes from anyone's library.
- **Every Bool and number was moved off its default** where the types still read it back, so a key a
  later build reads as its default shows in the round trip, not only a key that throws.
- **The recipes' destinations** are the Mac's: Files for the built-ins, Share for one, and the retired
  word "Photos" for one (`ExportRecipe.Destination.retired`), which a 2.1 file may hold and which this
  build reads as Files. `enums.json` lists "Photos" among the destinations for the same reason.
- On 2026-11-08, before any rename, the writer compiled against this tree wrote the same bytes, apart
  from the clipboard's groups (a `Set`, in per-process order) and the saved look's new id.

**Do not regenerate these to make the check pass.** A difference is a 2.1.4 file this build reads
differently: fix the build. A format the check should also cover gets a new file here, written once.
