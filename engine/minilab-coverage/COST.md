# Runtime and payload cost of the minilab catalog

Measured 2026-10-25 on the promoted engine (Apple M3 Max, 36 GiB) against the
bundle-shaped staging tree (`run/staging/resources`: base + product overlay +
`minilab/index.json`), one fresh process per render, `performance_compare`
workers. Load average at the time: 2.07. These are small deltas, so they are
reported as medians of six interleaved runs rather than as a benchmark.

## Payload

| | bytes | MiB |
|---|---:|---:|
| one table (65³ float32 + 28-byte header) | 3,295,528 | 3.14 |
| 97 pairs / 194 entries / 182 table files (committed) | 599,786,096 | 572.0 |
| …plus `index.json` and the directory README | 69,826 | 0.07 |
| **the whole `minilab/` directory as bundled** | **599,855,922** | **572.07** |
| the branch's previous catalog (Portra pair only, at `unpublished-revision`) | 6,594,147 | 6.29 |
| **increase over the previous app** | **593,261,775** | **565.78** |
| all 136 pairs / 272 tables (projected, SOP) | 896,383,616 | 854.9 |

194 entries share 182 files: the six CineStill pairs that inherit Vision3
500T's calibration point at Vision3's tables, which saves 12 files (~39.5 MB).
A zip/DMG of the tables compresses to ~88 % (three samples: 88 %, 88 %, 89 %), so
the download delta is roughly **505–510 MiB** while the installed footprint is
572 MiB.

The catalog is data, not code: `engine/build.sh bundle` copies it, the app does
not embed it, and the engine loads **one table per open** on first use
(`MinilabCatalog::load` → `upload_persistent`), so an unopened pair costs its
file on disk and nothing at run time. The 3.3 MB read, FNV check and upload are
inside the measured open delta below.

## Cold open / first render, 2560 px, 18 % grey synthetic frame

The two arms are the same film (`kodak_gold_200`); the catalogued arm uses
`kodak_portra_endura` (minilab table), the optical arm `kodak_2383` (no entry).

| arm | open ms | first total ms | peak footprint MiB |
|---|---:|---:|---:|
| catalogued (minilab) | 34.9 | 211.6 | 640.1 |
| optical (no table) | 28.5 | 200.0 | 630.5 |
| delta | **+6.4** | **+11.6** | **+9.6** |

The open delta is the table's read + hash + persistent upload; the first-render
delta is the fused minilab kernel (two DI kernels + trilinear) against the three
optical print nodes it replaces. The peak-footprint delta is the table resident
host-side and on the GPU, matching the 3.14 MiB payload plus allocator slack.

## Bake cost (offline, not product run time)

Per pair and space: ~180–230 s wall, peak RSS 5.5–6.5 GB, one process at a time
(`FINDINGS.md` §2 on the batch-dependent solver). Evidence: every job's
`status.json` `duration_secs` / `peak_rss_bytes`, summarised in `LEDGER.json`.

## What is not measured here

- The full app launch and first canvas draw (the app was not built or installed
  by this run; the engine boundary is what is measured above).
- 45 MP render time with a minilab pair: the frame is a print-stage kernel, so
  the delta scales with pixels, not with the table.
- Any timing claim under load: this machine drifts (AGENTS trap 17); the load
  average is recorded with the numbers for that reason.
