"""RFC-020 §4.7's acceptance: the session's planes stop being charged to the
process.

Two of a session's holdings live as long as the session does and are planes of
the frame: `session->source`, and the cached negative every reprint reads. At
102 MP that is 2.44 GB. Backed by an ordinary shared MTLBuffer they are charged
to `phys_footprint` in full -- the number jetsam reads -- and backed by a file
mapping they are charged about a tenth (measured; `rfc/probes/`, and re-measured
here as the control).

    python3 engine/tests/file_backed_planes.py                    # this engine
    python3 engine/tests/file_backed_planes.py --dylib OLD.dylib  # and it fails

The second line is the point. The same sequence against a build from before the
change -- `git worktree add /tmp/x <commit> && (cd /tmp/x && engine/build.sh
dylib)` -- breaks the assertions, so "the planes are not charged" is a reading
rather than a constant.

**How the charge is measured.** Not by reading the footprint after an open: the
host frame is 1,166 MB of this process too, numpy hands it back to the OS on
its own schedule, and the first version of this probe measured that instead
(2.58 planes charged for one plane held, on the control). The charge is the
difference between two *settled* states that differ only by the holding -- the
session open, then the session closed -- with the host copy dropped before both
readings. Settlement is sampled rather than slept through, because a freed
allocation reaches the ledger asynchronously and half a second is the observed
lag, not a guarantee.
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


def footprint(out: str) -> float:
    match = re.search(r"Footprint:\s*([\d.]+)\s*([KMGT]?B)", out)
    if not match:
        raise SystemExit(f"could not read a footprint out of:\n{out[:400]}")
    return float(match.group(1)) * UNITS[match.group(2)] / MB


def graphics_bucket(out: str) -> float:
    """The `IOAccelerator (graphics)` line of `footprint(1)`, in MB: the bucket
    a Metal buffer's pages are charged to.

    **This, and not the total, is what the assertions read**, and the reason is
    measured. The total also carries `Owned physical footprint (unmapped)
    (graphics)`, a fixed ~128 MB of driver arena that appears in a reading or
    not depending on the process's history and had nothing to do with the open
    -- it put a size-independent 129 MB into a differential whose signal at
    24 MP is 0.08 of a plane, and it is why the earlier version of this probe
    failed at every size below 48 MP while passing at 102. The bucket is
    immune to it, to numpy's arenas (`Malloc Large`) and to the host frame
    (`Malloc Large` as well)."""
    for line in out.splitlines():
        if line.rstrip().endswith("IOAccelerator (graphics)"):
            fields = line.split()
            return float(fields[0]) * UNITS[fields[1]] / MB
    return 0.0


def read() -> tuple[float, float]:
    """(total phys_footprint, IOAccelerator bucket), in MB."""
    out = subprocess.run(["/usr/bin/footprint", "-p", str(os.getpid())],
                         capture_output=True, text=True, check=True).stdout
    return footprint(out), graphics_bucket(out)


def settled(timeout: float = 15.0) -> tuple[float, float]:
    """The two readings once they have stopped moving."""
    last = read()
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(0.3)
        now = read()
        if abs(now[0] - last[0]) <= 0.01 * max(now[0], 1.0) and abs(now[1] - last[1]) <= 16:
            return now
        last = now
    return last


def frame(h: int, w: int) -> np.ndarray:
    row = np.linspace(0.05, 0.9, w, dtype=np.float32)[None, :]
    col = np.linspace(0.9, 0.05, h, dtype=np.float32)[:, None]
    return np.repeat((row * col).astype(np.float32)[:, :, None], 3, axis=2)


def open_timed(engine, pixels) -> tuple[object, float]:
    """Open `pixels` and time the call itself -- not the array it is made of,
    which is the largest term in a naive timing of the same lines.

    **The frame is allocated once, outside the measured window, and kept
    alive.** The first version of this probe freed it inside the window, and
    at 24 MP that put 0.47 of a plane of numpy's own churn into a differential
    whose whole signal was 0.08 of one: two readings a quarter of a second
    apart can agree to 1 % while the ledger is still working through a freed
    megabyte-scale array. Held instead, the only thing that changes between
    the two readings is the engine's holding."""
    started = time.time()
    session = engine.open(pixels)
    return session, (time.time() - started) * 1000


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dylib", type=Path, default=None)
    parser.add_argument("--size", default="8742x11656", help="HxW; the RFC's 102 MP")
    args = parser.parse_args()

    h, w = (int(v) for v in args.size.split("x"))
    plane_mb = h * w * 3 * 4 / MB
    print(f"engine: {args.dylib or spk_ctypes.ENGINE / 'build' / 'libspektrafilm_engine.dylib'}")
    print(f"frame:  {w}x{h} = {w * h / 1e6:.1f} MP, one plane {plane_mb:,.0f} MB")

    failures = 0

    def check(ok: bool, what: str, detail: str = "") -> None:
        nonlocal failures
        print(f"{'ok  ' if ok else 'FAIL'}  {what}{('  -- ' + detail) if detail else ''}")
        if not ok:
            failures += 1

    with spk_ctypes.Engine(dylib=args.dylib) as engine:
        print(f"build:  {engine.build_info}")
        # One host frame for the whole run, allocated before any baseline.
        pixels = frame(h, w)

        # --- the source, and nothing else --------------------------------
        idle = settled()
        session, open_ms = open_timed(engine, pixels)
        with_source = settled()
        session.close()
        del session
        gc.collect()
        without = settled()
        source_charge = with_source[1] - without[1]
        print(f"    open {open_ms:,.0f} ms; with the session open {with_source[1]:,.0f} MB of "
              f"graphics (total {with_source[0]:,.0f} MB), closed {without[1]:,.0f} MB -> the "
              f"source is charged {source_charge / plane_mb:.2f} of a plane")
        check(source_charge < 0.40 * plane_mb,
              "the session's source is not charged to the footprint",
              f"{source_charge / plane_mb:.2f} of a plane")

        # --- the source and the cached negative ---------------------------
        session, _open_ms = open_timed(engine, pixels)
        _rgba, result = session.render("full")
        with_planes = settled()
        report = None
        if hasattr(engine._lib, "spk_memory_report"):
            report = engine.memory_report()
        session.close()
        del session
        gc.collect()
        without = settled()
        planes_charge = with_planes[1] - without[1]
        print(f"    full render {result.elapsed_ms:,.0f} ms; with source+negative "
              f"{with_planes[1]:,.0f} MB of graphics (total {with_planes[0]:,.0f} MB), closed "
              f"{without[1]:,.0f} MB -> two planes are charged {planes_charge / plane_mb:.2f} of one")
        check(planes_charge < 1.00 * plane_mb,
              "two planes held cost less than one plane charged",
              f"{planes_charge / plane_mb:.2f} planes for a source and a negative")

        # --- the branch with no plane file to be had ----------------------
        # `SPEKTRAFILM_PLANE_DIR` is a seam (metal_gpu.cpp) that points the
        # planes somewhere impossible. The engine must still open, render and
        # produce the same picture -- this is an optimisation, and an open
        # that fails for it would be the optimisation breaking the product --
        # and the report must say the planes are *not* file-backed, so a
        # silent fallback cannot pass for a win.
        os.environ["SPEKTRAFILM_PLANE_DIR"] = "/nonexistent/spektrafilm-planes"
        session, _ms = open_timed(engine, pixels)
        rendered, _res = session.render("live")
        fell_back = None
        if hasattr(engine._lib, "spk_memory_report"):
            fell_back = engine.memory_report()["persistent"]["file_backed_bytes"]
        session.close()
        del session
        gc.collect()
        check(rendered.shape[0] > 0,
              "with no usable scratch directory the engine still opens and renders",
              f"{rendered.shape[1]}x{rendered.shape[0]}")
        if fell_back is not None:
            check(fell_back == 0,
                  "and says so: nothing claims to be file-backed",
                  f"file_backed_bytes = {fell_back}")
        del os.environ["SPEKTRAFILM_PLANE_DIR"]

        # ... and the seam is not sticky: the next open is file-backed again.
        session, _ms = open_timed(engine, pixels)
        recovered = None
        if hasattr(engine._lib, "spk_memory_report"):
            recovered = engine.memory_report()["persistent"]["file_backed_bytes"]
        session.close()
        del session
        gc.collect()
        if recovered is not None:
            check(recovered >= plane_mb,
                  "and a usable directory is used again once there is one",
                  f"{recovered / MB:,.0f} MB")

        if report is not None:
            persistent = report["persistent"]
            backed = persistent.get("file_backed_bytes")
            if backed is None:
                check(False, "the engine reports which planes are file-backed",
                      "no `file_backed_bytes` in the report")
            else:
                print(f"    the engine reports {backed / MB:,.0f} MB file-backed of "
                      f"{persistent['bytes'] / MB:,.0f} MB persistent")
                check(backed >= 2 * plane_mb,
                      "the source and the cached negative are both file-backed",
                      f"{backed / MB:,.0f} MB against two planes of {2 * plane_mb:,.0f} MB")
        else:
            print("    (no memory report: this engine predates RFC-020 §3.3)")

    print(f"\n{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
