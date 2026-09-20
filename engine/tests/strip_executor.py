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
2. **The loop actually ran what it planned** (`passes == len(plan)` per
   segment). A correct plan the loop does not execute is a different bug.

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
                elif seg["passes"] != len(seg["plan"]):
                    problems.append(f"{seg['stage']}: {seg['passes']} passes for "
                                    f"{len(seg['plan'])} strips")
            check(not problems, f"{label}: the plan partitions [0, {h}) and ran",
                  "; ".join(problems) if problems else
                  f"{expected} strips x 2 segments, {segs[0]['passes']} passes each")

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
