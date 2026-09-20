"""RFC-020 §3.1's idle form: the pool goes back when nobody is editing.

§3.1 deliberately does not trim at `end_frame`, because between renders seconds
apart the same sizes come straight back. The case that leaves open is the
common one -- a 102 MP frame is opened, rendered, and the user goes to lunch --
and the process sits on ~11 GB of dead capacity with nothing to show for it.
§3.2's pressure source does not cover it: macOS memory pressure is *reactive*,
so on a machine with nothing else running it never fires, and by the time it
does the compressor is already involved.

Two things are asked of this probe, and the second is the interesting one:

1. Does the trim fire, and does the pool actually come back? With a control --
   `SPEKTRAFILM_IDLE_TRIM_SECONDS=0` disables the timer, and the same script
   with the same wait must find the pool still held. Without that, a green run
   would only prove that a pool which was never large is small.
2. **What does the first render after the trim cost?** §1.2's "page faults are
   the cheap half" was measured on a different trigger (the frame switch), so
   it is not evidence for this one. The probe measures the same tier before and
   after the wait, in both configurations, and the difference between the two
   configurations is the re-fault cost with the machine's own run-to-run
   variation subtracted.

Run it directly; it drives two child processes because the seam is latched at
engine creation.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402

MB = 1 << 20

CHILD = r'''
import hashlib, json, os, subprocess, sys, time
sys.path.insert(0, {tests!r})
from memory_report import frame
from spk_ctypes import Engine

h, w = {h}, {w}
wait_s = {wait_s}
CYCLES = {cycles}

def vm_counters():
    out = subprocess.run(["/usr/bin/vm_stat"], capture_output=True, text=True).stdout
    import re
    def field(name):
        m = re.search(name + r":\s+(\d+)", out)
        return int(m.group(1)) if m else 0
    return field("Compressions"), field("Pages occupied by compressor")

def footprint_mb():
    out = subprocess.run(["/usr/bin/footprint", "-p", str(os.getpid())],
                         capture_output=True, text=True).stdout
    import re
    m = re.search(r"Footprint:\s*([\d.]+)\s*([KMGT]?B)", out)
    units = {{"B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30}}
    return float(m.group(1)) * units[m.group(2)]

engine = Engine()
pixels = frame(h, w)
session = engine.open(pixels)

def median(values):
    values.sort()
    return values[len(values) // 2]

# CYCLE_COUNT cycles of [wait, then render], with the wait long enough that a
# trim (when one is enabled) has certainly happened. The first full render is
# a warm-up and is thrown away: the very first render of a session pays for
# pipeline states, the source's first touch and the meter, and it is 1.2 s
# slower than every later one at 102 MP -- which would otherwise land in
# whichever number happened to be measured first.
session.render("full")
pool_after_full = engine.memory_report()["pool"]["total_bytes"]

comp_before, comp_res_before = vm_counters()
live_ms, full_ms, digests = [], [], []
for _ in range(CYCLES):
    time.sleep(wait_s)
    report = engine.memory_report()
    pool_after_wait = report["pool"]["total_bytes"]
    pressure = report["pressure"]
    rgba, live = session.render("live")
    live_ms.append(live.elapsed_ms)
    digests.append(hashlib.sha1(rgba.tobytes()).hexdigest()[:16])
    rgba, full = session.render("full")
    full_ms.append(full.elapsed_ms)
    digests.append(hashlib.sha1(rgba.tobytes()).hexdigest()[:16])

comp_after, comp_res_after = vm_counters()

# The render right after the loop, with no wait, is the one that shows the
# penalty is *once*: the cycle before it rebuilt the pool, so this render
# should be back to the warm time whether or not a trim is enabled.
_, recovery = session.render("full")

# The footprint is read **after** every timed render, and that placement is
# load-bearing: `footprint(1)` walks the target's whole address space, which
# with a 10.9 GB pool in it is real work, and sampling it before the render
# charged that work to the render. It made a live tier measured at 45 ms in
# isolation read as 1,142 ms here -- in the child that kept its pool, and not
# in the one that gave it back -- which is a difference between the two
# configurations that has nothing to do with the engine.
time.sleep(wait_s)
pool_after_wait = engine.memory_report()["pool"]["total_bytes"]
footprint_after_wait = footprint_mb()

session.close()
engine.close()

print(json.dumps({{
    "pool_after_full": pool_after_full,
    "pool_after_wait": pool_after_wait,
    "t_full_median": median(full_ms),
    "t_live_median": median(live_ms),
    "t_full_recovery": recovery.elapsed_ms,
    "footprint_after_wait": footprint_after_wait,
    "cycles": CYCLES,
    "digests": digests,
    "idle_trims": pressure.get("idle_trims", 0),
    "idle_trim_seconds": pressure.get("idle_trim_seconds", 0),
    "compressions": comp_after - comp_before,
    "compressor_pages_after": comp_res_after,
}}))
'''


def run_child(h: int, w: int, idle_seconds: float, wait_s: float, cycles: int) -> dict:
    env = dict(os.environ)
    env["SPEKTRAFILM_IDLE_TRIM_SECONDS"] = str(idle_seconds)
    script = CHILD.format(tests=str(Path(__file__).resolve().parent), h=h, w=w,
                          wait_s=wait_s, cycles=cycles)
    proc = subprocess.run([sys.executable, "-c", script], env=env, capture_output=True, text=True)
    if proc.returncode != 0:
        print(proc.stderr[-2000:])
        raise SystemExit(f"child (idle={idle_seconds}) failed")
    return json.loads(proc.stdout.strip().splitlines()[-1])


def mb(n: float) -> str:
    return f"{n / MB:,.0f} MB"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--size", default="4000x6000", help="HxW; the RFC's 102 MP is 8742x11656")
    parser.add_argument("--idle", type=float, default=2.0,
                        help="the threshold the child runs with; the shipped one is 60 s")
    parser.add_argument("--cycles", type=int, default=3, help="measured cycles per child")
    args = parser.parse_args()

    h, w = (int(v) for v in args.size.split("x"))
    # Threshold + one tick (a quarter of it) + leeway, plus slack.
    wait_s = args.idle * 1.5 + 2.0
    print(f"frame {w}x{h}; threshold {args.idle:g} s, waiting {wait_s:g} s in both configurations")

    failures = 0

    def check(ok: bool, what: str, detail: str = "") -> None:
        nonlocal failures
        print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
        if not ok:
            failures += 1

    held = run_child(h, w, 0.0, wait_s, args.cycles)
    trimmed = run_child(h, w, args.idle, wait_s, args.cycles)

    print(f"    disabled: pool after the wait {mb(held['pool_after_wait'])}")
    print(f"    enabled:  pool after the wait {mb(trimmed['pool_after_wait'])}")
    check(held["pool_after_full"] > 0, "the full render left a pool to give back",
          mb(held["pool_after_full"]))
    check(held["pool_after_wait"] >= held["pool_after_full"] * 0.9,
          "with the trim disabled the pool is still held after the same wait",
          f"{mb(held['pool_after_wait'])} of {mb(held['pool_after_full'])}")
    check(trimmed["pool_after_wait"] <= trimmed["pool_after_full"] * 0.05,
          "with the trim enabled the pool comes back",
          f"{mb(trimmed['pool_after_wait'])} left of {mb(trimmed['pool_after_full'])}")
    print(f"    the engine reports the timer armed at {trimmed['idle_trim_seconds']:g} s "
          f"({held['idle_trim_seconds']:g} s in the control) and {trimmed['idle_trims']} real trims")
    check(held["idle_trims"] == 0 and held["idle_trim_seconds"] == 0,
          "the control never armed a timer and never trimmed",
          f"{held['idle_trims']} trims, {held['idle_trim_seconds']:g} s")
    check(trimmed["idle_trims"] > 0,
          "the enabled run at least once gave bytes back, and counted it",
          f"{trimmed['idle_trims']} trims")
    # The property this change puts at risk, and the reason it is checked here
    # rather than in a parity harness: a trim means the next render builds its
    # planes from *fresh* buffers instead of reusing ones a previous render
    # dirtied. If any node read a buffer before writing it, the picture would
    # change -- and only in the run where a trim happened in between, which no
    # existing harness does.
    same = held["digests"] == trimmed["digests"]
    check(same, "and the pixels are identical whether a trim happened between renders or not",
          f"{len(set(held['digests']) | set(trimmed['digests']))} distinct digests over "
          f"{len(held['digests'])} renders" if not same
          else f"{len(held['digests'])} renders hashed, all equal across the two runs")

    print(f"\n    what the next render costs, median of {args.cycles}, ms "
          f"(the pool the render found in brackets):")
    print(f"      {'':16s} {'trim disabled':>16s} {'trim enabled':>16s}")
    print(f"      {'live tier':16s} {held['t_live_median']:>16.0f} {trimmed['t_live_median']:>16.0f}")
    print(f"      {'full tier':16s} {held['t_full_median']:>16.0f} {trimmed['t_full_median']:>16.0f}")
    cost_live = trimmed["t_live_median"] - held["t_live_median"]
    cost_full = trimmed["t_full_median"] - held["t_full_median"]
    recovery = trimmed["t_full_recovery"]
    print(f"\n    the first interactive render after an idle trim costs {cost_live:+,.0f} ms "
          f"over the same render with the pool kept")
    print(f"    the first full render after an idle trim costs {cost_full:+,.0f} ms "
          f"({100.0 * cost_full / held['t_full_median']:+.1f}%)")
    print(f"    the full render straight after it costs {recovery:,.0f} ms "
          f"against {held['t_full_median']:,.0f} ms warm -- the penalty is paid once")
    print(f"    footprint while the pool was held: {mb(held['footprint_after_wait'])}, "
          f"after it was given back: {mb(trimmed['footprint_after_wait'])}")
    print(f"    system compressions during the cycles: pool held "
          f"{held['compressions']:,}, pool given back {trimmed['compressions']:,}; "
          f"pages in the compressor at the end {held['compressor_pages_after'] * 16384 / MB:,.0f} MB "
          f"against {trimmed['compressor_pages_after'] * 16384 / MB:,.0f} MB")
    print("    (the compressions counter is system-wide and the two children run "
          "minutes apart, so read it as a direction, not as a difference)")

    # A penalty bound on the interactive path, not an absolute difference: the
    # measured value is *negative* -- a re-created small pool renders the live
    # tier faster than a pool of full-frame planes does -- and an `abs()` here
    # failed the check for being better than expected.
    check(cost_live < 50.0,
          "the first interactive render after an idle trim is not a stall",
          f"{cost_live:+,.0f} ms on a {trimmed['t_live_median']:,.0f} ms render")
    check(cost_full < 0.5 * held["t_full_median"],
          "the first heavy render pays less than half a render for the re-fault",
          f"{cost_full:+,.0f} ms on a {held['t_full_median']:,.0f} ms render")
    check(recovery < 1.15 * held["t_full_median"],
          "and it is paid once: the render after it is back to the warm time",
          f"{recovery:,.0f} ms against {held['t_full_median']:,.0f} ms")
    print(f"\n{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
