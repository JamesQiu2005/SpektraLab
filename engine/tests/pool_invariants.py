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
this check, loudly and on purpose.

**3. That reuse happens at all**, with a negative case that must differ.

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

        return probe.end()


if __name__ == "__main__":
    sys.exit(main())
