"""RFC-020 §3's acceptance probe: the engine gives memory back, and says what
it holds.

Not a parity harness -- there is no Python oracle for any of this. It is the
measurement §9 step 2 asks for: the pool must actually come back when the
frame changes, and a §3.2 pressure event must be observable, with a control
that shows the observation is not an artifact of always seeing it.

    python3 engine/tests/memory_report.py            # fast: the default sizes
    python3 engine/tests/memory_report.py --large    # the RFC's 102 -> 24 MP

Three things it can check, in increasing order of what they cost:

  frame switch   open a big frame, render it, release it, open a small one --
                 and the pool is measured *between* the open and the render,
                 which is the only moment the trim is the last thing that ran.
  pressure       `SPEKTRAFILM_TEST_PRESSURE` delivers a real event through the
                 real queue and handler (metal_gpu.cpp); the probe asserts the
                 counters and the flag, and asserts that they are *absent*
                 without the variable.
  parity of use  the report's own arithmetic: `pool.total` partitions into
                 live + free + pending, and `total_bytes` is the two top-level
                 blocks summed. A report nobody checks is a number, not an
                 instrument.

Also `--dylib PATH`, which is how the frame-switch check is shown to be able
to fail: point it at a pre-RFC-020 build and the pool does not come back. The
same run against both engines is the evidence; a green run alone is not.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402

MB = 1 << 20
GB = 1 << 30

failures = 0


def check(ok: bool, what: str, detail: str = "") -> None:
    global failures
    print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
    if not ok:
        failures += 1


def mb(n: float) -> str:
    return f"{n / MB:,.0f} MB"


def frame(h: int, w: int) -> np.ndarray:
    """A frame with something in it: a gradient, so no kernel sees a constant
    and shortcuts. The values do not matter, the *size* does -- everything
    here is about planes of a given shape."""
    row = np.linspace(0.05, 0.9, w, dtype=np.float32)[None, :]
    col = np.linspace(0.9, 0.05, h, dtype=np.float32)[:, None]
    grey = (row * col).astype(np.float32)
    return np.repeat(grey[:, :, None], 3, axis=2)


def partitions(report: dict) -> None:
    """The report's own arithmetic, checked rather than assumed."""
    pool = report["pool"]
    parts = pool["live_bytes"] + pool["free_bytes"] + pool["pending_bytes"]
    check(parts == pool["total_bytes"],
          "pool partitions",
          f"live {mb(pool['live_bytes'])} + free {mb(pool['free_bytes'])} + "
          f"pending {mb(pool['pending_bytes'])} = {mb(parts)} "
          f"against total {mb(pool['total_bytes'])}")
    check(pool["live_buffers"] + pool["free_buffers"] + pool["pending_buffers"] == pool["buffers"],
          "and by count", f"{pool['buffers']} buffers")
    check(report["total_bytes"] == pool["total_bytes"] + report["persistent"]["bytes"],
          "total_bytes is the two blocks summed",
          f"{mb(report['total_bytes'])}")
    # The session rows are a breakdown *of* `persistent`, which is the one
    # relationship a consumer can get wrong by adding instead of nesting.
    rows = report["persistent"]["sessions"]
    check(sum(r["source_bytes"] for r in rows) == report["persistent"]["source_bytes"] and
          sum(r["cached_negative_bytes"] for r in rows) == report["persistent"]["cached_negative_bytes"],
          "persistent.sessions is the breakdown of persistent",
          f"{len(rows)} session(s)")


def frame_switch(engine, big: tuple[int, int], small: tuple[int, int]) -> dict:
    """The acceptance: a big frame's pool does not survive into a small one."""
    print(f"\n--- frame switch: {big[1]}x{big[0]} -> {small[1]}x{small[0]} ---")
    session = engine.open(frame(*big))
    _rgba, result = session.render("full")
    after_full = engine.memory_report()
    print(f"    full render {result.elapsed_ms:,.0f} ms; pool {mb(after_full['pool']['total_bytes'])}, "
          f"high-water {mb(after_full['pool']['frame_high_water_bytes'])}, "
          f"persistent {mb(after_full['persistent']['bytes'])}")
    check(after_full["pool"]["total_bytes"] > 0, "the big render left a pool",
          mb(after_full["pool"]["total_bytes"]))
    session.close()

    small_session = engine.open(frame(*small))
    # Measured here, between the open and the render: the trim on a frame
    # switch is the last thing that has run.
    after_switch = engine.memory_report()
    kept = after_switch["pool"]["total_bytes"]
    print(f"    after the switch, before rendering: pool {mb(kept)}")
    small_session.close()

    # Nothing in the shipped engine may leave the big pool behind. The bound
    # is generous on purpose -- what is being checked is that the *planes*
    # went, not the last few megabytes of constant uploads.
    check(kept <= after_full["pool"]["total_bytes"] // 10,
          "the pool came back on the frame switch",
          f"{mb(kept)} left of {mb(after_full['pool']['total_bytes'])}")
    return after_full, after_switch


def run_pressure_child(size: tuple[int, int], mode: str | None) -> dict:
    """One pressure run, in a child process: the seam is read where the `Gpu`
    is built, before any of this Python exists. `-c` rather than a fork, so
    the engine is created with the variable already in its environment.

    The shape of the run is what makes the two levels tell themselves apart.
    A **full** render is measured the moment it ends, when the event has just
    been delivered and nothing has grown the pool again; `warn` should be
    holding the frame's own high-water there and `critical` only what the
    render still has live, which at 102 MP is 11 GB against 1.2. Then a second
    render, so the flag has something to be reported by.
    """
    env = dict(os.environ)
    env.pop("SPEKTRAFILM_TEST_PRESSURE", None)
    if mode:
        env["SPEKTRAFILM_TEST_PRESSURE"] = mode
    script = f"""
import ctypes, json, sys
sys.path.insert(0, {str(Path(__file__).resolve().parent)!r})
from memory_report import frame
from spk_ctypes import Engine, SPK_OK

engine = Engine()
session = engine.open(frame({size[0]}, {size[1]}))
session.render("full")
after_full = engine.memory_report()
session.render("live")
out = ctypes.c_char_p()
engine._lib.spk_progress(session._handle, None, ctypes.byref(out))
progress = engine._take_json(out)
session.close()
engine.close()
print(json.dumps({{"progress": progress, "after_full": after_full}}))
"""
    proc = subprocess.run([sys.executable, "-c", script], env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-2000:])
        raise SystemExit(f"pressure child ({mode!r}) failed")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--large", action="store_true",
                        help="the RFC's own sizes: 11656x8742 (~102 MP) and 6000x4000")
    parser.add_argument("--dylib", type=Path, default=None,
                        help="an engine to probe instead of the freshly built one")
    parser.add_argument("--no-pressure", action="store_true")
    args = parser.parse_args()

    big, small = ((8742, 11656), (4000, 6000)) if args.large else ((1300, 1700), (700, 1000))
    print(f"engine: {args.dylib or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}")
    started = time.time()

    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        print(f"build:  {engine.build_info}")
        print("\n--- the report on an empty engine ---")
        idle = engine.memory_report()
        print(json.dumps(idle, indent=2))
        check(idle["pressure"]["monitor"], "a memory-pressure source is registered")

        if not args.large:
            # Small sizes for the default run: the point is the plumbing, and
            # 102 MP makes this a two-minute probe. The bit above -- and the
            # `--large` run -- are what the RFC's numbers come from.
            print("\n--- a small render, to give the report something to say ---")
            session = engine.open(frame(*small))
            session.render("live")
            session.render("full")
            session.close()
            partitions(engine.memory_report())

        if args.large:
            frame_switch(engine, big, small)

    if not args.no_pressure:
        print("\n--- RFC-020 §3.2: the two levels, and the control ---")
        size = small if not args.large else (4000, 6000)
        seen = {}
        for mode in (None, "warn", "critical"):
            seen[mode] = run_pressure_child(size, mode)
            pressure = seen[mode]["after_full"]["pressure"]
            pool = seen[mode]["after_full"]["pool"]
            print(f"    {str(mode):8s} warn={pressure['warn_events']:.0f} "
                  f"critical={pressure['critical_events']:.0f} "
                  f"render-reported={seen[mode]['progress']['memory_pressure_critical']} "
                  f"| after the full render: pool {mb(pool['total_bytes'])}, "
                  f"live {mb(pool['live_bytes'])}, "
                  f"high-water {mb(pool['frame_high_water_bytes'])}")

        control = seen[None]["after_full"]["pressure"]
        check(control["warn_events"] == 0 and control["critical_events"] == 0 and
              not control["critical_pending"],
              "with no event delivered, nothing is counted and nothing is flagged",
              "the control: without it, a green pressure check would only mean the "
              "counters are not wired to anything")
        warn = seen["warn"]["after_full"]["pressure"]
        check(warn["warn_events"] > 0 and warn["critical_events"] == 0,
              "a warn event counts as a warn and does not raise the critical flag",
              f"warn={warn['warn_events']:.0f}")
        critical = seen["critical"]["after_full"]["pressure"]
        check(critical["critical_events"] > 0,
              "a critical event is counted", f"{critical['critical_events']:.0f}")
        check(seen["critical"]["progress"]["memory_pressure_critical"] is True,
              "and the next render reports that it ran under critical pressure")
        check(seen["warn"]["progress"]["memory_pressure_critical"] is False,
              "warn alone does not make a render report critical pressure")

        # The bound, which is the only thing that separates the two levels.
        # `warn` keeps the frame's live high-water, so it must land between
        # what no event leaves (nothing freed) and what `critical` leaves
        # (nothing but what is live, which after a full render is one plane).
        # An invariant rather than a tolerance: it holds for any frame, and it
        # fails if either trim does not run.
        pools = {mode: seen[mode]["after_full"]["pool"]["total_bytes"] for mode in seen}
        check(pools["critical"] <= pools["warn"] <= pools[None],
              "critical <= warn <= no event, in what each left behind",
              f"{mb(pools['critical'])} <= {mb(pools['warn'])} <= {mb(pools[None])}")
        check(pools["critical"] < pools[None] or pools[None] == 0,
              "and the critical level actually gave something back",
              f"{mb(pools[None])} -> {mb(pools['critical'])}")

    print(f"\n{time.time() - started:,.1f} s, {failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
