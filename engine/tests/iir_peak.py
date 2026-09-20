"""RFC-020 §4.4's estimate, replaced by a measurement — step 6-R's number.

§4.4 puts the striped render's peak at **"~6 GB, estimated"** against a measured
15.6 GB today, and §9 step 1 promised the estimate would be replaced by a
measurement rather than re-argued. Class R is where the planes actually collapse,
so this is the first point at which the measurement is worth taking. The two
omissions the sweep found (`boost` whole-frame, and the `log_e_film` crossing)
are inside the measured number, not caveats on an arithmetic one.

**Two instruments, because they answer different questions and the difference is
the whole subtlety of this step:**

  * **peak** — `phys_footprint` sampled from a thread while the render runs.
    This is the number a 24 GB Mac feels, and it is what "three planes live at
    once" has to show up in. Sampling after the render would report the previous
    frame: Metal hands pages back asynchronously (~0.5 s), which is the trap
    `frame_switch_footprint.py` documents.
  * **total** — `spk_memory_report`'s `pool.frame_high_water_bytes`, the pool's
    own high-water for the frame. It cannot be fooled by when it is read, and it
    is what a saving of *allocation* shows up in when the peak does not move:
    three planes allocated one after another and freed would move this and not
    the peak. If the two disagree about 3.7 GB, the number is traffic and not
    peak, and this file says which one it is reporting.

The comparison is **old engine against new, same frame, same parameters**, so
the answer is a difference rather than a claim about the machine. The old one
comes from a worktree:

    git worktree add /tmp/spk-head HEAD
    (cd /tmp/spk-head/engine && ./build.sh dylib)
    python3 engine/tests/iir_peak.py --old /tmp/spk-head/engine/build/libspektrafilm_engine.dylib

**A note on the machine.** The peak differential is 3.7 GB at 102 MP, which is
thirty times the size-independent ~128 MB of driver arena that made small-frame
differentials useless, so it is measurable under load — but a run that spends
its time in swap measures the machine as much as the engine. The swap state is
printed with the results so a reader can judge, and the numbers are reported as
a difference in the same conditions either way.
"""
from __future__ import annotations

import argparse
import gc
import subprocess
import sys
import threading
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes  # noqa: E402
from frame_switch_footprint import footprint_mb, frame  # noqa: E402

MB = 1 << 20
NEUTRAL = {"grain_active": False, "glare_active": False, "auto_exposure": False}


class Sampler:
    """`phys_footprint` every interval, from a thread, for the peak."""

    def __init__(self, interval: float = 0.05):
        self.interval = interval
        self.samples: list[float] = []
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while not self._stop.is_set():
            try:
                self.samples.append(footprint_mb())
            except Exception:
                pass
            time.sleep(self.interval)

    def __enter__(self) -> "Sampler":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._stop.set()
        self._thread.join(timeout=5.0)

    @property
    def peak(self) -> float:
        return max(self.samples) if self.samples else float("nan")


def swap() -> str:
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True)
    return out.stdout.strip()


def swap_used_mb() -> float:
    return float(swap().split("used =")[1].split("M")[0].replace(",", "").strip())


def load_raw(path: Path) -> np.ndarray:
    """A NEF, decoded on the host, as the float32 the engine takes.

    **This is the host path, not the app's.** The app decodes through Core Image
    (`intake-is-core-image-not-the-engine`), so a differential taken here is a
    differential of the *engine*, and it is not comparable to §1.1's baseline
    without saying so: that baseline is the app's whole path, decode included.

    `rawpy` without brightness or gamma, because the values do not matter to a
    memory measurement and the ones that arrive want to be the linear ones.
    """
    import rawpy  # only in the reference venv

    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(gamma=(1, 1), no_auto_bright=True, output_bps=16,
                              use_camera_wb=True, output_color=rawpy.ColorSpace.sRGB)
    return (rgb.astype(np.float32) / 65535.0)


def measure(dylib: Path, img, delta: dict, label: str) -> dict:
    """One render, its peak and the pool's high-water for the frame.

    **A fresh engine per measurement, and that is not tidiness.** The pool's
    high-water is per engine and per frame, and the pre-R build counted a
    *persistent* buffer's release against it -- so on that build the second
    session in a process reads a wrapped `size_t` instead of a size. A fresh
    engine makes every reading a first one, which is the only shape in which
    the two builds' numbers mean the same thing.

    **Swap before and after, and the pressure counters**, because on a machine
    at 86 % swap a `warn`-level memory-pressure event is part of the
    measurement: the handler trims the pool, and the pool is what is being
    measured. A run whose counters moved is reported beside its number rather
    than averaged in.
    """
    params = {**NEUTRAL, **delta}
    gc.collect()
    swap_before = swap_used_mb()
    with spk_ctypes.Engine(dylib=dylib, resources=dylib.parent.parent / "resources") as engine:
        with Sampler() as sampler:
            session = engine.open(img, params)
            _rgba, result = session.render("full")
            session.close()
        pool = engine.memory_report()["pool"]
    audit = pool.get("audit", {})
    row = {
        "label": label,
        "peak_mb": sampler.peak,
        "high_water_mb": pool["frame_high_water_bytes"] / MB,
        "ms": result.elapsed_ms,
        "samples": len(sampler.samples),
        "swap_before": swap_before,
        "swap_after": swap_used_mb(),
        "pressure": {k: v for k, v in pool.items() if "pressure" in k and v},
        "audit": {k: v for k, v in audit.items()
                  if k in ("live_underflows", "pending_held", "over_releases",
                           "reclaim_while_encoding") and v},
    }
    flag = "" if not row["pressure"] and not row["audit"] else "   <-- counters moved"
    print(f"    {label:26s} peak {row['peak_mb']:9,.0f} MB   "
          f"pool high-water {row['high_water_mb']:9,.0f} MB   {row['ms']:8,.0f} ms"
          f"   swap {row['swap_before']:,.0f}->{row['swap_after']:,.0f} MB{flag}")
    if row["pressure"] or row["audit"]:
        print(f"        {row['pressure']} {row['audit']}")
    return row


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", type=Path, required=True,
                    help="a dylib built from the commit before the transpose was removed")
    ap.add_argument("--new", type=Path, default=None)
    ap.add_argument("--big", default="8742x11656", help="HxW, default 102 MP")
    ap.add_argument("--raw", type=Path, default=None,
                    help="a RAW file instead of a synthetic frame (the host decode path)")
    ap.add_argument("--striped", action="store_true",
                    help="also measure the striped mode (preliminary; Phase 2 replaces §4.4)")
    args = ap.parse_args()

    if args.raw:
        img = load_raw(args.raw)
        h, w = img.shape[0], img.shape[1]
        print(f"raw: {args.raw}")
    else:
        h, w = (int(v) for v in args.big.split("x"))
    mp = h * w / 1e6
    new_path = args.new or spk_ctypes.ENGINE / "build" / "libspektrafilm_engine.dylib"
    print(f"frame {w}x{h}  ({mp:.1f} MP, one plane {h * w * 3 * 4 / 1e9:.2f} GB)")
    print(f"swap:   {swap()}")
    print(f"old:    {args.old}")
    print(f"new:    {new_path}\n")

    if not args.raw:
        img = frame(h, w)
    rows: dict[str, dict[str, dict]] = {}
    for name, dylib in (("old", args.old), ("new", new_path)):
        with spk_ctypes.Engine(dylib=dylib,
                               resources=dylib.parent.parent / "resources") as engine:
            print(f"{name}: {engine.build_info}")
        rows[name] = {"whole, grain+glare": measure(dylib, img, {}, "whole, grain+glare")}
        if args.striped:
            rows[name]["striped 8"] = measure(
                dylib, img, {"striped": True, "strip_rows": h // 8}, "striped, 8 strips")
    gc.collect()

    print("\nthe difference, new against old:")
    for key in rows["old"]:
        a, b = rows["old"][key], rows["new"][key]
        print(f"  {key:26s} peak {a['peak_mb'] - b['peak_mb']:+9,.0f} MB   "
              f"high-water {a['high_water_mb'] - b['high_water_mb']:+9,.0f} MB")

    print("\nthe new engine's numbers (preliminary unless this is the 102 MP run on a "
          "clean machine -- §4.4 is replaced by that and by nothing else):")
    for key, r in rows["new"].items():
        print(f"  {key:26s} peak {r['peak_mb'] / 1024:6.2f} GB   "
              f"high-water {r['high_water_mb'] / 1024:6.2f} GB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
