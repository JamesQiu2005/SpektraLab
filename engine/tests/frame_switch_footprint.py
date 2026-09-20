"""RFC-020 §3.1's negative control: does the pool actually come back?

`memory_report.py` measures the pool through `spk_memory_report`, which is
this RFC's own invention -- so a green `--large` run there proves the numbers
agree with themselves. This probe asks the same question with a measurement
that exists on *both* sides of the RFC: **`phys_footprint`**, for this
process, with the engine the only thing in it that holds gigabytes.

    python3 engine/tests/frame_switch_footprint.py                       # RFC-020 engine
    python3 engine/tests/frame_switch_footprint.py --dylib OLD.dylib     # and it fails

The second line is the point of the file. Run it against a build from before
the RFC and the sequence is identical but the answer is not, which is the only
evidence that the check can tell a released pool from a retained one
(AGENTS.md, guards-that-cannot-fire). `engine/build.sh dylib` skips the driver
binaries and `git worktree add` isolates the old tree, so an old engine costs
one build:

    git worktree add /tmp/spk-pre-rfc020 HEAD
    (cd /tmp/spk-pre-rfc020 && engine/build.sh dylib)

The host frame itself is freed before each measurement -- a 1.2 GB numpy array
is part of the process too, and it would otherwise be the second-largest thing
in the reading.
"""
from __future__ import annotations

import argparse
import gc
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402

MB = 1 << 20
UNITS = {"B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30, "TB": 1 << 40}


def footprint_mb() -> float:
    """This process's `phys_footprint`, in MB -- the number RFC-016's
    `MemorySampler` reads and the one people quote.

    `footprint(1)` rather than `ps`, and that is not a preference: RSS was
    tried first and **hides the pool entirely**. A 10.9 GB pool of Metal
    shared buffers measured 7.9 GB of RSS at its peak and 6.6 GB after the
    buffers were freed, on both engines -- pages the compressor has taken are
    not resident, and pages a freed allocation handed back to the driver's
    cache still are, so the two errors cancel into a number that moves by a
    gigabyte whatever the engine does. A probe whose instrument cannot see
    the thing it measures is a green light wired to nothing.
    """
    out = subprocess.run(["/usr/bin/footprint", "-p", str(os.getpid())],
                         capture_output=True, text=True, check=True).stdout
    match = re.search(r"Footprint:\s*([\d.]+)\s*([KMGT]?B)", out)
    if not match:
        raise SystemExit(f"could not read a footprint out of:\n{out[:400]}")
    return float(match.group(1)) * UNITS[match.group(2)] / MB


def settled_mb(timeout: float = 10.0) -> float:
    """The footprint once it has stopped moving.

    **Reading it immediately after freeing is reading it wrong.** Metal's
    buffers are charged under `IOAccelerator (graphics)`, and their pages are
    handed back to the VM asynchronously: measured at the frame switch, 14 GB
    at +0 s and 3.3 GB at +0.5 s, unchanged from there. A probe that measured
    once, immediately, would report that nothing came back -- which is what
    this file did until the teardown was watched, and is the reason the
    negative control below is a *second engine* rather than a second reading.
    """
    last = footprint_mb()
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.25)
        now = footprint_mb()
        if abs(now - last) <= 0.01 * max(now, 1.0):
            return now
        last = now
    return last


def frame(h: int, w: int) -> np.ndarray:
    row = np.linspace(0.05, 0.9, w, dtype=np.float32)[None, :]
    col = np.linspace(0.9, 0.05, h, dtype=np.float32)[:, None]
    return np.repeat((row * col).astype(np.float32)[:, :, None], 3, axis=2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dylib", type=Path, default=None)
    parser.add_argument("--big", default="8742x11656", help="HxW, default 102 MP")
    parser.add_argument("--small", default="4000x6000")
    args = parser.parse_args()

    big = tuple(int(v) for v in args.big.split("x"))
    small = tuple(int(v) for v in args.small.split("x"))
    print(f"engine: {args.dylib or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}")

    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        print(f"build:  {engine.build_info}")
        baseline = settled_mb()

        pixels = frame(*big)
        session = engine.open(pixels)
        _rgba, result = session.render("full")
        # After the render, not during it: what is being asked is whether what
        # the frame left behind goes away, not where the render's own peak was.
        after_full = settled_mb()
        pool = None
        if hasattr(engine._lib, "spk_memory_report"):
            pool = engine.memory_report()["pool"]["total_bytes"]
        print(f"    {big[1]}x{big[0]} full render: {result.elapsed_ms:,.0f} ms, "
              f"footprint after it {after_full:,.0f} MB"
              + (f", pool {pool / MB:,.0f} MB" if pool is not None else ""))
        session.close()
        del pixels, session
        gc.collect()

        # The switch. Nothing is rendered on the small frame: the question is
        # what opening it did to what the *previous* frame left behind.
        pixels = frame(*small)
        session = engine.open(pixels)
        after_switch = settled_mb()
        session.close()
        del pixels, session
        gc.collect()

    # `baseline` is the process with the engine loaded and nothing rendered --
    # the interpreter, numpy, the colour data and the metallib. Everything
    # above it is frame-sized, and what is being asked is whether it survives
    # the switch. A quarter is the bar rather than a byte count: a frame
    # switch legitimately leaves the *new* frame's own source behind, and that
    # is proportional to the new frame, not the old one.
    print(f"    after switching to {small[1]}x{small[0]}: footprint {after_switch:,.0f} MB "
          f"(baseline {baseline:,.0f} MB, after the big render {after_full:,.0f} MB)")
    ok = after_switch - baseline < 0.25 * (after_full - baseline)
    print(f"{'ok  ' if ok else 'FAIL'}  the big frame's memory did not survive the switch  -- "
          f"{after_full - after_switch:,.0f} MB came back")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
