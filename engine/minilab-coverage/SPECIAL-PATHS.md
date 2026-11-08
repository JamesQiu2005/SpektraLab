# Special routes: silver, reversal bypass, incompatible pairs

These are the 89 rows of the 225 that are **not** colour-negative minilab jobs
(4 silver + 36 reversal + 49 incompatible). They are accounted for here with a
command and a measured result; none of them received a colour minilab table, and
none is counted in the colour coverage.

All commands run against the promoted engine (`engine/build.sh dylib`) with the
qualified `engine/resources/minilab/` catalog present, so a passing result also
says the catalog does not disturb these paths.

## Silver path — 4 pairs (Tri-X 400, T-Max 100, Neopan 100 Acros II, HP5 Plus 400 on Multigrade IV RC)

`engine/tests/bw_checks.py` exercises the shipped monochrome path: neutral
prints, Multigrade filter 2 as the wire's neutral pack, harder filters printing
more contrast, a filter leaving 18 % grey where it was, red/blue filters shaping
the picture and not the film's edge, the negative and its rebate grey, an
unknown filter refused, and the DX code reading back the way Kodak's does not.

```
python3 engine/tests/bw_checks.py
...
0 failure(s)
```

Measured 2026-10-25 on the branch carrying the minilab catalog: **0 failures**.
`pipeline.cpp` also refuses the minilab for `channel_model == "monochrome"`, and
the catalog has no silver film/paper entry, so there is no colour-hue LUT on
this route and no way to add one by accident.

## Reversal bypass — 36 pairs (4 positive films x 9 papers)

The app sends `scan_film = true` for a positive stock
(`app/SpektraLab/tools/film_edge_parity.py`: `"scan_film": c["stock"] in
POSITIVE`). With that switch the paper is not part of the render, so the paper
choice must be *bit-identical*. Verified for all four stocks on two papers
either side of the range (`kodak_portra_endura`, `kodak_2383`), auto exposure on,
grain/glare off, 600 px:

| film | paper A vs paper B | max diff (16-bit RGBA) |
|---|---|---:|
| fujifilm_provia_100f | portra_endura / 2383 | **0** |
| fujifilm_velvia_100 | portra_endura / 2383 | **0** |
| kodak_ektachrome_100 | portra_endura / 2383 | **0** |
| kodak_kodachrome_64 | portra_endura / 2383 | **0** |

The negative-film paper path is *not* bypassed for a positive when
`scan_film` is false — that is the app's choice and not this catalog's to make.
The catalog only adds a transform for colour-negative films with a colour paper,
and `pipeline.cpp` excludes positives from it (`!film.info.is_positive()`).

## Incompatible pairs — 49 rows

A colour film on the silver paper, or a monochrome film on a colour paper. The
product's pairing rule (`StockCatalog.canPrint`, mirrored by
`engine/tools/minilab_inventory.py`) keeps them out of the catalog, so they
never reach the minilab loader. The inventory snapshot records each row with its
reason; `COVERAGE.md` reports them as `incompatible_channel_models`, not as
missing colour coverage.

## Why these are not "colour minilab" rows

A colour minilab on a silver paper or a reversal frame is a different
model-development task, not a missing table: the hue-recovery target has no
meaning without a colour negative and a colour paper. The SOP requires these
routes to keep their own runtime paths, and they do.
