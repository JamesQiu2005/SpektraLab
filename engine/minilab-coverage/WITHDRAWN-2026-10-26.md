# Withdrawn from 2.1.1: every minilab pair but Portra 400 → Portra Endura

2026-10-26. The owner inspected the 2.1.0 test build and judged the
calibrations bad except one — "only the portra 400 to portra endura minilab
fix will be shipped together in v2.1.1".

## What the release tree holds now

| | 2.1.0 | 2.1.1 |
|---|---:|---:|
| pairs in `engine/resources/minilab/index.json` | 97 | **1** |
| entries | 194 | **2** |
| table files | 182 | **2** |
| payload | 572 MiB | **6.29 MiB** |

The kept pair is `kodak_portra_400|kodak_portra_endura` in both calibration
spaces. Its `index.json` content is byte-identical to the one-pair catalog at
`unpublished-revision`, the commit that first promoted the pair; it was never rebaked, so
nothing was lost in the trim.

**It is the default path.** A new frame's pair comes from
`AppSettings.newFrameStocks`, which falls back to `lastFilm` / `lastPaper` —
`kodak_portra_400` / `kodak_portra_endura`. So a session opens on the
calibrated pair rather than on optical printing. Everything else — every other
film, and every other paper under Portra 400 — stays optical, because the
catalog names no table for it. (`FilmParams.init()`'s `kodak_supra_endura` is
only the seed a `FrameEdit` carries before the new-frame pair is applied; it is
not what the app develops a new frame with.)

The other 180 tables and the 97-pair `index.json` are stored outside the
repository at:

    ~/Documents/Dev/SpektraLab-minilab-archive-2026-10-26/

with a README, the full catalog and SHA-256 checksums. The same bytes remain in
this repository's history at `unpublished-revision`; nothing was rewritten.

## What the tree keeps

The baker (`engine/tools/minilab_bake/`), the qualification ledger
(`LEDGER.json`, `PROCEDURE.md`, `SOP.md`) and this coverage directory stay.
The method is not disowned — the *bakes* are not accepted.

**`COVERAGE.md` and `LEDGER.json` describe the 2026-10-25 campaign, not the
shipped catalog.** Their "staged" counts (194) are a record of that run.
`report.py` regenerates them from the ledger and the tree; do not read a stale
"staged" count as a statement about what a build carries. The build's own
truth is `engine/tests/minilab_catalog_check.py` run against the bundle.

## The lesson that outlives the tables

A pair was counted qualified when both calibration spaces passed the numeric
gates **and** a chart sheet was marked `visual_pass`. Ninety-six pairs cleared
that, and the owner rejected them on sight in the real app. The gate was
necessary and not sufficient: a chart sheet is not a photograph, and the
campaign's acceptance criterion was the wrong last check.

Before a withdrawn pair is re-staged, inspect it on real frames through a
built app — not on the sheet that qualified it. The restore steps are in the
archive's README.
