# Qualified v2 minilab print transforms

These are the unmodified, owner-approved `r = 1` (full look retention) research
bakes for **Kodak Portra 400 → Kodak Portra Endura**, at 65³ samples. The source
artifacts were `research/Metamerism/v2/minilab/`
`kodak_portra_400__kodak_portra_endura_f10.lut3d` and its `_pp` counterpart.
They were promoted on 2026-10-24; `f10` is the research filename, not the retained
look parameter. `index.json` pins payload and measured profile identities with
FNV-1a 64-bit digests. These tables do not modify those profiles.

Input is the film's recovered log-positive RGB, output is **paper CMY density**.
The existing paper scan and output transform follow it. The sRGB destination
uses its separately calibrated table; other supported destinations use the
ProPhoto calibration before their own output transform. Both routes reproduce
the corresponding original research rendering exactly. They are not general
RGB output LUTs and must not be passed to `spk_print_lut_table`.

The catalog explicitly identifies each film/paper pair. Unlisted pairs retain
their optical print path. Missing/corrupt listed tables or changed underlying
profile files fail with an error; they never silently substitute an optical
render or another pair's calibration. B&W, positive film, scan-film and DI keep
their own paths. More pairs require independently qualified r=1 bakes.

## The catalog entry

`index.json` is `{"version": 1, "pairs": {"<film>|<paper>": {"sRGB": {…},
"ProPhoto RGB": {…}}}}`. Each entry carries:

| key | meaning |
|---|---|
| `file` | table file name in this directory (never a path) |
| `side` | 65 |
| `hash` | FNV-1a 64-bit of the raw table bytes |
| `film_hash` / `paper_hash` | FNV-1a 64-bit of the named profile JSON's bytes |
| `film_base_hash` / `paper_base_hash` | for a `derived_from` alias only: FNV-1a 64-bit of the inherited base profile's bytes |
| `look_retention` | 1 (`r = 1`) |
| `calibration_space` | the space the table was fitted in |

A hash is FNV-1a 64-bit, offset `14695981039346656037`, prime
`1099511628211`, modulo 2⁶⁴, 16 lowercase hex digits — the engine's own
(`engine/src/core/minilab.cpp`). The named-profile hash alone cannot pin an
alias: an alias file is a name change and an anti-halation switch and carries no
measured data, so `*_base_hash` pins the material it inherits. Entries without
those keys keep the older, narrower check; an entry that declares one on a
profile that is not an alias is an error rather than an ignored field.

## Bundling and the catalog gate

The engine loads this directory from its resources root at setup
(`engine/src/core/setup_cache.hpp` → `MinilabCatalog::init`). A missing or
invalid `minilab/index.json` makes **engine creation fail** with an error — it
does not silently fall back to the optical path. Both bundle steps copy the
whole `engine/resources/` tree, so the catalog ships with it:

- `engine/build.sh bundle` — `rsync -a --delete engine/resources/ <app>/Resources/engine/`
- `app/SpektraLab/tools/build_engine_mac.sh` — `rsync -a --exclude '*.metallib' --exclude '*.metalar' engine/resources/ $res/` (`$res` is `build/engine-macosx/EngineResources`)

The app's engine identity also hashes `engine/resources`, so a catalog change
changes the engine identity and cannot reuse a stale cache.

Check what actually shipped, from the files themselves (stdlib only, no venv):

```sh
python3 engine/tests/minilab_catalog_check.py <app>/Contents/Resources/Resources/engine
# or, for the Mac app's build tree (tools/build_engine_mac.sh):
python3 engine/tests/minilab_catalog_check.py app/SpektraLab/build/engine-macosx/EngineResources
```

It re-derives the table length and FNV-1a 64-bit payload hash, the named
profile bytes and any inherited base profile — the same identity the loader
checks — and exits non-zero on the first missing or mismatched entry.

## Offline provenance / rebaking

The research handoff is `research/HANDOFF-v2-engine-2026-10-24.md`; the offline
baker and calibration study remain in `research/Metamerism/v2/`. Those ignored
research inputs are prerequisites for a new calibration, not product build
inputs. The parameterized baker and the complete procedure are
[`engine/tools/minilab_bake/`](../../tools/minilab_bake/README.md) and
[`engine/minilab-coverage/PROCEDURE.md`](../../minilab-coverage/PROCEDURE.md):
it re-bakes the committed pair byte-for-byte before it is trusted with a new
one. Do not relabel an r=0 table as r=1. Ordinary app builds only copy these
tracked files and do not need Python or research files.

Material provenance and licensing remain those of the source film/paper data
in `engine/resources/profiles` and `LICENSE-PROFILES.txt`; this directory adds
print-transform calibration, not new measured material claims.

For the complete all-pair procedure and a single-agent assignment, see
[`engine/minilab-coverage/SOP.md`](../../minilab-coverage/SOP.md) and
[`DEEPSEEK-HANDOFF.md`](../../minilab-coverage/DEEPSEEK-HANDOFF.md).
