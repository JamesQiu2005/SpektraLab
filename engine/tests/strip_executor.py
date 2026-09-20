"""RFC-020 §4 step 4's executor: what it plans, what it runs, and what it leaves.

Step 4 stripes no node, so with every node whole-frame the arithmetic cannot
notice a badly built plan -- "the hashes match" is satisfied by an executor
that reads the strip height, ignores it, and runs today's graph. Two things
make the step falsifiable instead:

1. **The plan partitions the plane.** Every segment reports `(y0, rows)` per
   strip; this asserts the list is a partition of `[0, plane_h)`: first `y0` is
   0, each `y0` is the previous `y0 + rows`, the rows sum to the plane, every
   row count is positive, and the count is what the height asked for. That
   geometry is what steps 5 and 6 are built on, and step 4 is the only step
   where it can be checked in isolation -- nothing reads it yet, so nothing
   goes visibly wrong if it is off by a row.
2. **The loop actually ran what it planned.** A strip pass happens once per
   strip per *band-able run*, so `passes == len(plan) x band_runs` exactly, and
   the band-able runs are where the chain says they are -- the classes are
   pinned, because a stage wrongly marked band-able is a picture bug (an F/R
   stage truncated at a band edge) and this is where the classification is
   visible.

Plus §6's hash gate, against the **un-striped** render as the reference rather
than against the axis's own `n = 1`: that the mode degenerates is one claim,
and that it agrees with what ships is the other.

Non-dividing heights are the interesting ones (7 rows into 300 leaves a 6-row
last strip) and one row per strip is the extreme. The frame is kept under the
live tier's 1600 px so no tier downscales: the plane the strips cut is then the
frame's own height, which is what makes the partition assertable against a
number this probe knows rather than one it reads back.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402
from pool_invariants import frame  # noqa: E402


# The table's classes, pinned. A stage whose class moves is a code change, and
# it has to move here with it -- this is the pin the resolved value cannot give.
WANT_CLASS = {
    "film": {"film_scale_and_expose": "pointwise", "film_boost": "whole",
             "film_blurs": "neighbourhood", "film_log_and_curves": "pointwise",
             "film_couplers": "neighbourhood", "film_grain": "whole"},
    "print": {"print_spectral": "pointwise", "print_glare": "whole",
              "print_linear": "pointwise", "print_scan_finish": "neighbourhood",
              "print_output": "pointwise"},
}
# And what those classes resolve to at the shipped settings on the default
# frame. `film_couplers` is the interesting one: its diffusion tail's widest
# surrogate sigma is 2.7684 x 200 um over the pitch, which crosses 3 px on any
# frame this size, so the stage asks for the escape hatch rather than a halo.
WANT_BAND = {
    "film": {"film_scale_and_expose", "film_blurs", "film_log_and_curves"},
    "print": {"print_spectral", "print_linear", "print_scan_finish", "print_output"},
}


def segments(engine, session) -> list[dict]:
    out = ctypes.c_char_p()
    if engine._lib.spk_progress(session._handle, None, ctypes.byref(out)) != spk_ctypes.SPK_OK:
        raise spk_ctypes.EngineError(engine._last_error())
    return engine._take_json(out).get("strip_segments", [])


def check_partition(plan: list[dict], plane_h: int, expected_count: int) -> str:
    """The empty string if the plan partitions `[0, plane_h)`, else why not."""
    if len(plan) != expected_count:
        return f"{len(plan)} strips for a height of {plane_h} at this size, expected {expected_count}"
    want_y = 0
    for i, span in enumerate(plan):
        if span["rows"] <= 0:
            return f"strip {i} has {span['rows']} rows"
        if span["y0"] != want_y:
            return f"strip {i} starts at {span['y0']}, expected {want_y}"
        want_y += span["rows"]
    if want_y != plane_h:
        return f"the strips cover {want_y} rows of {plane_h}"
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dylib", type=Path, default=None)
    parser.add_argument("--height", type=int, default=300, help="the frame's height")
    args = parser.parse_args()

    h, w = args.height, args.height + 100
    img = frame(h, w)
    print(f"engine: {args.dylib or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}")
    print(f"frame {w}x{h}: the live tier is 1600 px, so no tier downscales and the "
          f"strips cut the frame's own rows\n")

    failures = 0

    def check(ok: bool, what: str, detail: str = "") -> None:
        nonlocal failures
        print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
        if not ok:
            failures += 1

    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        print(f"build:  {engine.build_info}\n")
        for rows in (0, h, 150, 100, 40, 7, 1):
            expected = 1 if rows == 0 else (h + rows - 1) // rows
            with engine.open(img, {"product_defaults": True, "striped": True,
                                   "strip_rows": rows}) as session:
                rgba_full, _ = session.render("full")
                segs = segments(engine, session)
                full_digest = hashlib.sha1(rgba_full.tobytes()).hexdigest()[:16]
                rgba_re, _ = session.render("full", reprint=True)
                re_digest = hashlib.sha1(rgba_re.tobytes()).hexdigest()[:16]

            label = f"strip_rows={rows if rows else 'policy'}"
            problems = []
            if len(segs) != 2:
                problems.append(f"{len(segs)} segments, expected film and print")
            for seg in segs:
                why = check_partition(seg["plan"], h, expected)
                if why:
                    problems.append(f"{seg['stage']}: {why}")
                    continue
                # One pass per strip per band-able *run*: the runs are maximal
                # groups of adjacent band-able stages, and the expected class
                # sets are pinned below.
                runs = [st["band_able"] for st in seg["stages"]]
                band_runs = sum(1 for i, b in enumerate(runs) if b and not (i and runs[i - 1]))
                if seg["passes"] != band_runs * len(seg["plan"]):
                    problems.append(f"{seg['stage']}: {seg['passes']} passes for "
                                    f"{len(seg['plan'])} strips x {band_runs} band runs")
            check(not problems, f"{label}: the plan partitions [0, {h}) and ran",
                  "; ".join(problems) if problems else
                  f"{expected} strips, " + ", ".join(
                      f"{g['stage']} {g['passes']} passes" for g in segs))

            # **Two facts, two pins**, and step 6 is why. `class` is the
            # table's entry -- a property of the code, the same on every run --
            # and `band_able` is what this run resolved to. A stage wrongly
            # marked in the table would otherwise hide behind a run whose
            # parameters happened to agree with the mistake: at the shipped
            # settings `film_couplers` resolves `carried` (its diffusion tail
            # crosses the IIR sigma), which is indistinguishable in the report
            # from a stage the table forgot to mark band-able at all.
            got_class = {g["stage"]: {st["name"]: st["class"] for st in g["stages"]} for g in segs}
            check(got_class == WANT_CLASS, f"{label}: the static classes are pinned",
                  f"{got_class}" if got_class != WANT_CLASS else
                  "film and print as the table says")

            # The resolution, pinned for this probe's frame. It is a function of
            # the frame's pitch (the sigmas are micrometres over a pitch), so a
            # `--height` other than the default moves it and this pin has to be
            # re-derived rather than trusted.
            got_band = {g["stage"]: {st["name"] for st in g["stages"] if st["band_able"]} for g in segs}
            check(got_band == WANT_BAND, f"{label}: and resolve as the demand says",
                  f"{got_band}" if got_band != WANT_BAND else
                  "film_couplers carried, the rest band-able; halos "
                  + ", ".join(f"{st['name']}={st['halo']}" for st in segs[0]["stages"] if st["halo"]))

            # **The crossing count, pinned, because it has slipped three times
            # under a loose definition.** A crossing is one place a plane and a
            # band meet: one slice into a band run and one assembly out of it,
            # so `2 x runs`, and a run has both ends in a plane even when it
            # starts at the segment's input or ends at its output. At the
            # shipped settings film has two runs (`scale_and_expose`, then
            # `blurs -> log_and_curves`) and print has two (`spectral`, then
            # `linear -> scan_finish -> output`): 4 and 4, eight in total. In
            # step 5's table print had three runs, so the same arithmetic gave
            # 4 + 6 = 10 -- F becoming band-able merged two runs there and took
            # two crossings out, which is the saving this pin now protects.
            #
            # `passes` is the other axis and moves with the plan; `crossings`
            # does not, and confusing the two is how the number kept moving.
            want_runs = {"film": 2, "print": 2}
            got_runs = {g["stage"]: g["runs"] for g in segs}
            want_cross = {"film": 4, "print": 4}
            got_cross = {g["stage"]: g["crossings"] for g in segs}
            check(got_runs == want_runs and got_cross == want_cross,
                  f"{label}: the runs and crossings are pinned",
                  f"runs {got_runs}, crossings {got_cross} (2 x runs = "
                  f"{sum(got_cross.values())} in total)")

            # §6's gate in this probe's own terms: the striped picture is the
            # un-striped one -- **each against its own kind**. A render and a
            # reprint of the same frame are not the same picture and never
            # were: `spk_render` re-runs the film side and draws a new grain
            # realisation, while a reprint re-enters at `run_print` with the
            # cached negative. Comparing them to each other is a probe bug, and
            # it is the shape that would have made this line fail on a
            # perfectly good executor.
            with engine.open(img, {"product_defaults": True}) as plain:
                ref_full, _ = plain.render("full")
                ref_re, _ = plain.render("full", reprint=True)
            same_full = hashlib.sha1(ref_full.tobytes()).hexdigest()[:16] == full_digest
            same_re = hashlib.sha1(ref_re.tobytes()).hexdigest()[:16] == re_digest
            check(same_full and same_re,
                  f"{label}: and the picture is the un-striped one, render and reprint",
                  f"render {full_digest} against {hashlib.sha1(ref_full.tobytes()).hexdigest()[:16]}, "
                  f"reprint {re_digest} against {hashlib.sha1(ref_re.tobytes()).hexdigest()[:16]}")

    print(f"\n{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
