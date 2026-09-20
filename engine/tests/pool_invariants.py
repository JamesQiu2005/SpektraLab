"""RFC-020 §3's pool invariants, checked from outside the engine.

Written for the three questions the orchestrator set, in the order that puts
the only silent-corruption risk first:

**1. Aliasing.** Does any pooled buffer ever have two live holders? That is
`refs` accounting, and it is exact rather than statistical. Two statements,
both checkable at every API boundary:

  a. **`pool.live_bytes == 0` after every call.** Every holder that outlives a
     call is *persistent* -- a session's source, its cached negatives, a
     result's texture buffer -- and persistent allocations are never pooled.
     So at a boundary the live set is empty by construction, and any pooled
     buffer still held is a handle that outlived its frame: a leak, or worse, a
     session holding a buffer the next render will hand to someone else.
  b. **Three counters that must stay zero**, each the mechanism by which two
     holders could exist (they are argued in comments in `metal_gpu.cpp`, and a
     comment cannot fail):

       `pending_held`            a buffer queued for reuse while a handle
                                 exists -- §3.4's defect two, the state that
                                 was established unreachable by argument. This
                                 is how that argument gets a runtime witness.
       `over_releases`           a release of a buffer nobody holds.
       `reclaim_while_encoding`  buffers made reusable while a command buffer
                                 that may name them is open and unrun.

**2. The size policy, pinned as it is** (a small request does take a
full-frame plane when that is what the pool holds, and there is no upper
bound). Asserted, not preferred: a future size bound is *expected* to break
this check, loudly and on purpose, and the commit that adds one should come
here first.

**3. That reuse happens at all**, with a negative case that must differ: a
render whose requests no free buffer fits allocates, and the same render again
-- with the pool now holding its sizes -- allocates nothing at all. Measured,
not assumed: the second full render of a frame leaves `allocations` and
`buffers` *unchanged*.

Nothing here is timed and nothing here is a claim about the policy being good.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402

MB = 1 << 20
MUST_STAY_ZERO = ("pending_held", "over_releases", "reclaim_while_encoding")


def frame(h: int, w: int) -> np.ndarray:
    row = np.linspace(0.05, 0.9, w, dtype=np.float32)[None, :]
    col = np.linspace(0.9, 0.05, h, dtype=np.float32)[:, None]
    return np.repeat((row * col).astype(np.float32)[:, :, None], 3, axis=2)


def two_sessions_one_engine(engine) -> None:
    """The pool's own high-water, across two sessions on one engine.

    **This is a check that exists because its absence hid a defect.** The
    pre-R build counted a *persistent* buffer's release against the pool's
    `live_bytes_`, which had never counted it; the `size_t` wrapped to
    `2^64 - 1` and `frame_high_water_bytes` followed it, so the *second*
    session in any engine read eighteen exabytes as a frame's peak -- which is
    also the number the memory-pressure handler trims to. Every probe that
    checked the accounting used one session per engine and saw nothing wrong.

    Two identical sessions must therefore report the *same* high-water, and it
    must be a size: not zero (nothing happened) and not the whole pool (the
    arithmetic came apart). `live_underflows` is the direct witness; the other
    two hold on builds that predate it.
    """
    from pool_invariants import frame as _frame

    img = _frame(300, 400)
    peaks = []
    for _ in range(3):
        session = engine.open(img, {"product_defaults": True})
        session.render("full")
        pool = engine.memory_report()["pool"]
        peaks.append(pool["frame_high_water_bytes"])
        underflows = pool.get("audit", {}).get("live_underflows", 0)
        session.close()
    same = len(set(peaks)) == 1
    sane = all(0 < p <= 1 << 40 for p in peaks)
    ok = same and sane and not underflows
    print(f"{'ok  ' if ok else 'FAIL'}  three sessions on one engine report one "
          f"high-water  -- {', '.join(f'{p / MB:,.2f} MB' for p in peaks)}"
          + (f", live_underflows {underflows}" if underflows else ""))
    return ok


def mb(n: float) -> str:
    return f"{n / MB:,.1f} MB"


class Probe:
    def __init__(self, engine) -> None:
        self.engine = engine
        self.failures = 0
        self.steps = 0

    def check(self, ok: bool, what: str, detail: str = "") -> None:
        print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
        if not ok:
            self.failures += 1

    def audit(self) -> dict:
        return self.engine.memory_report()["pool"]

    def boundary(self, what: str) -> dict:
        """Assert the aliasing statements after one API call."""
        self.steps += 1
        pool = self.audit()
        live = pool["live_bytes"]
        audit = pool["audit"]
        bad = {k: audit[k] for k in MUST_STAY_ZERO if audit[k]}
        self.check(live == 0 and not bad,
                   f"aliasing holds after {what}",
                   f"live {mb(live)}"
                   + (f", counters moved: {bad}" if bad else "")
                   + (f", live buffers: {pool['live_buffers']}" if live else ""))
        return pool

    def end(self) -> int:
        pool = self.audit()
        self.check(all(pool["audit"][k] == 0 for k in MUST_STAY_ZERO) and pool["live_bytes"] == 0,
                   f"and after {self.steps} boundaries, still nothing held",
                   f"live {mb(pool['live_bytes'])}, {pool['buffers']} buffers, "
                   f"{pool['audit']['reuses']} reuses, {pool['audit']['allocations']} allocations")
        return self.failures


def question_two(h: int, w: int, args) -> int:
    """The size policy, pinned as it is rather than as anyone might prefer."""
    print("\n--- 2. what the pool hands over when the sizes do not match ---")
    failures = 0
    plane = h * w * 3 * 4
    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        # Its own engine, so `reuse_max_taken` belongs to this scenario and
        # not to whatever ran before it.
        session = engine.open(frame(h, w), {"product_defaults": True})
        session.render("full")
        before = engine.memory_report()["pool"]
        session.render("live")
        after = engine.memory_report()["pool"]
        d = delta(before, after, ("reuses", "allocations"))
        taken = after["audit"]["reuse_max_taken"]
        asked = after["audit"]["reuse_max_taken_for_request"]

        def check(ok, what, detail=""):
            nonlocal failures
            print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
            if not ok:
                failures += 1

        check(d["reuses"] > 0, "a live-tier render is served out of a pool of full-frame planes",
              f"{d['reuses']:.0f} reuses, {d['allocations']:.0f} fresh allocations")
        check(taken >= 0.5 * plane,
              "and it takes a full-frame plane, not a size that fits it",
              f"{mb(taken)} taken for a request of {mb(asked)}")
        check(taken > asked,
              "the request was smaller than what it got, with no upper bound",
              f"{taken / max(asked, 1):.1f}x")
        check(after["audit"]["reuse_bytes_taken"] >= after["audit"]["reuse_bytes_requested"],
              "and in total the pool handed over at least what was asked of it",
              f"{mb(after['audit']['reuse_bytes_taken'])} taken for "
              f"{mb(after['audit']['reuse_bytes_requested'])} requested")
    return failures


def question_three(h: int, w: int, args) -> int:
    """Reuse happens -- with a case where it must not, so the two differ."""
    print("\n--- 3. reuse happens, and does not, in the two cases that differ ---")
    failures = 0
    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        session = engine.open(frame(h, w), {"product_defaults": True})
        # The pool is filled with *live-tier* planes, so the full tier's
        # requests cannot be served from it and must be allocated.
        session.render("live")
        a = engine.memory_report()["pool"]
        session.render("full")
        b = engine.memory_report()["pool"]
        must_allocate = delta(a, b, ("allocations", "reuses"))
        # Run the same render again: the pool now holds the sizes it wants.
        session.render("full")
        c = engine.memory_report()["pool"]
        must_reuse = delta(b, c, ("allocations", "reuses"))

        def check(ok, what, detail=""):
            nonlocal failures
            print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
            if not ok:
                failures += 1

        check(must_allocate["allocations"] > 0,
              "a render whose requests fit nothing free has to allocate",
              f"{must_allocate['allocations']:.0f} fresh, {must_allocate['reuses']:.0f} reused")
        check(must_reuse["allocations"] == 0,
              "and the same render again allocates nothing at all",
              f"{must_reuse['allocations']:.0f} fresh, {must_reuse['reuses']:.0f} reused")
        check(must_reuse["reuses"] > 0 and must_reuse != must_allocate,
              "so the two cases differ, which is what makes either of them evidence",
              # At a frame size whose live tier does not downscale, the pool is
              # already full of *full-tier* planes and this setup has no case to
              # make -- run the probe at its default `--size` before believing
              # this line.

              f"{must_allocate['allocations']:.0f}/{must_allocate['reuses']:.0f} against "
              f"{must_reuse['allocations']:.0f}/{must_reuse['reuses']:.0f} fresh/reused")
        # And the property that makes the pool safe for a session's own planes:
        # a persistent allocation is never a reuse.
        fresh = engine.memory_report()["pool"]["audit"]["persistent_allocations"]
        other = engine.open(frame(h, w), {"product_defaults": True})
        grown = engine.memory_report()["pool"]["audit"]["persistent_allocations"] - fresh
        check(grown > 0,
              "a session's source is a fresh persistent allocation, never out of the pool",
              f"{grown:.0f} persistent allocations for the open")
        other.close()
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--size", default="2000x2600", help="HxW; the RFC's 102 MP is 8742x11656")
    parser.add_argument("--dylib", type=Path, default=None)
    args = parser.parse_args()

    h, w = (int(v) for v in args.size.split("x"))
    print(f"engine: {args.dylib or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}")
    print(f"frame {w}x{h}, one plane {h * w * 3 * 4 / MB:,.1f} MB\n")

    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        probe = Probe(engine)
        if not two_sessions_one_engine(engine):
            probe.failures += 1
        small = frame(h // 3, w // 3)
        big = frame(h, w)

        session = engine.open(big, {"product_defaults": True})
        probe.boundary("open")

        for tier in ("live", "preview", "full"):
            session.render(tier)
            probe.boundary(f"render {tier}")
        for tier in ("live", "full"):
            session.render(tier, reprint=True)
            probe.boundary(f"reprint {tier}")

        # Every parameter layer, so buffer lifetimes that depend on a rebuild
        # are crossed too: a print-layer edit rebuilds the pipeline, a
        # shoot-layer one drops the cached negatives.
        session.set_params({"print_exposure": 0.1})
        probe.boundary("set_params (print layer)")
        session.set_params({"exposure_compensation_ev": 0.3})
        probe.boundary("set_params (shoot layer)")
        # Changing the film rebuilds everything the film side owns, which is
        # the largest set of handles any single call releases.
        session.set_params({"film_stock": "kodak_portra_800"})
        probe.boundary("set_params (a different film)")

        # A second frame on the same engine: the frame-switch trim runs, and
        # both sessions are alive at once for a moment.
        other = engine.open(small, {"product_defaults": True})
        probe.boundary("open a second frame")
        other.render("full")
        probe.boundary("render the second frame")
        session.render("live")
        probe.boundary("render the first frame again")

        other.close()
        probe.boundary("close the second frame")
        session.render("full")
        probe.boundary("render the first frame after the close")
        session.close()
        probe.boundary("close the first frame")

        # And a fresh session after everything has been torn down.
        third = engine.open(small, {"product_defaults": True})
        third.render("live")
        probe.boundary("a third session")
        third.close()
        probe.boundary("close it")

        failures = probe.end()
        failures += question_two(h, w, args)
        failures += question_three(h, w, args)
        return failures


def delta(before: dict, after: dict, keys) -> dict:
    """Counters are monotone, so a phase is a difference."""
    return {k: after["audit"][k] - before["audit"][k] for k in keys}


if __name__ == "__main__":
    sys.exit(main())
