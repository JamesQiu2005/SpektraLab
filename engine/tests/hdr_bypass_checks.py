#!/usr/bin/env python3
"""The HDR port's bypasses (PRD/HDR-PORT-PLAN-2026-11-06 D3/D4): at their defaults the new wire fields and
the new curve entry point change no picture, to the bit.

    engine/build.sh dylib
    python3 -I engine/tests/hdr_bypass_checks.py [--baseline-library <old dylib> --baseline-resources <dir>]

On a synthetic frame (a smooth base, noise and blown highlights, so toe, shoulder and clip are all
exercised), grain, glare and halation off, for prints (the minilab pair, an optical pair, a cinema
paper, a back-reflection film, a silver film) and slides scanned:

  1. **the fields' defaults are a bypass**: `scan_hdr_headroom 0`, `scan_hdr_stretch false`,
     `scan_hdr_output_scale 1`, `grain_seed 0` sent explicitly render what a session without them
     renders, to the bit;
  2. **a print ignores the slide variant**: a negative on paper with `scan_hdr_stretch`, a headroom 4
     and an output scale 1/4 renders today's print, to the bit (the variant is a positive film's scan);
  3. **the curve is not the picture (D3)**: `spk_session_hdr_curve` asked before a render, plain and
     eased, leaves the render byte-identical (it shares the medium probe with Scene Latitude and
     touches no tier);
  4. **one grain under one seed**: with grain on, two sessions at `grain_seed` 7 render one picture,
     and a grain-only edit and back on one session renders it again (the pre-grain checkpoint's
     restore draws the seed the same way `film_prefix` does); at 0 two renders differ, as today. The
     restore is made to happen (`SPK_CHECKPOINT_TEST_FORCE_ADMISSION`: this frame's prefix is far
     under the 20 ms a save needs) and the check requires the trace's `saved` and `hit`, so it cannot
     pass on `film_prefix` alone;
  5. with `--baseline-library`, **today's picture**: every fields-absent render of 1 equals the same
     render from the engine before this change (a separate process loads it), to the bit.

Exit 1 on any failure.
"""
from __future__ import annotations

import argparse
import contextlib
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import spk_ctypes as spk  # noqa: E402
import bw_checks  # noqa: E402

QUIET = {"grain_active": False, "grain_sublayers_active": False, "halation_active": False,
         "glare_active": False, "auto_exposure": False, "product_defaults": True,
         "input_cctf_decoding": False}
DEFAULTS = {"scan_hdr_headroom": 0.0, "scan_hdr_stretch": False, "scan_hdr_output_scale": 1.0, "grain_seed": 0}
CASES = {
    "portra400_endura_minilab": {"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura"},
    "portra400_supra_optical": {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura"},
    "vision3_500t_2383": {"film_stock": "kodak_vision3_500t", "print_stock": "kodak_2383"},
    "cinestill_800t_endura": {"film_stock": "cinestill_800t", "print_stock": "kodak_portra_endura",
                              "halation_active": True},
    "tri_x_multigrade": {"film_stock": "kodak_tri_x_400", "print_stock": bw_checks.PAPER,
                         "c_filter_neutral": 0.0, "m_filter_neutral": 0.0, "y_filter_neutral": 68.0},
    "velvia_scan": {"film_stock": "fujifilm_velvia_100", "scan_film": True},
    "provia_scan": {"film_stock": "fujifilm_provia_100f", "scan_film": True},
    "kodachrome_scan_couplers": {"film_stock": "kodak_kodachrome_64", "scan_film": True},
}
PRINTS = [k for k, v in CASES.items() if not v.get("scan_film")]


def frame(h=180, w=240) -> np.ndarray:
    rng = np.random.default_rng(7)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = 0.184 * 2.0 ** (8.0 * (xx / w) - 4.0)                      # -4 ... +4 EV across
    tint = np.stack([1.0 + 0.3 * np.sin(yy / 17), np.ones_like(yy), 1.0 + 0.3 * np.cos(yy / 23)], -1)
    img = base[..., None] * tint * (1.0 + 0.05 * rng.standard_normal((h, w, 3)))
    img[20:40, 200:230] = 0.184 * 2.0 ** 7.0                          # a blown highlight, +7 EV
    return np.ascontiguousarray(np.maximum(img, 0.0).astype(np.float32))


@contextlib.contextmanager
def checkpoint_traced(log: Path):
    """The pre-grain checkpoint admitted whatever its prefix costs, its trace (C stderr) into `log`."""
    keys = ("SPK_CHECKPOINT_TEST_FORCE_ADMISSION", "SPK_CHECKPOINT_TRACE")
    saved_env = {k: os.environ.get(k) for k in keys}
    os.environ.update({k: "1" for k in keys})
    sys.stderr.flush()
    saved_fd = os.dup(2)
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC)
    os.dup2(fd, 2)
    os.close(fd)
    try:
        yield
    finally:
        os.dup2(saved_fd, 2)
        os.close(saved_fd)
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def render(e, img, wire, before=None):
    s = e.open(img, wire)
    try:
        if before:
            before(s)
        rgba, _ = s.render("full")
        return rgba.copy()
    finally:
        s.close()


def dump(out: Path) -> int:
    e = spk.Engine(resources=os.environ["SPK_BYPASS_RESOURCES"])
    img = frame()
    for name, w in CASES.items():
        np.save(out / f"{name}.npy", render(e, img, {**QUIET, **w}))
    e.close()
    return 0


def overlay_resources(res: Path, tmp: str) -> Path:
    """`res` with the product's profiles laid over it (bw_checks.overlay, for any resources dir)."""
    out = Path(tmp) / "resources"
    (out / "profiles").mkdir(parents=True)
    for f in res.iterdir():
        if f.name != "profiles":
            os.symlink(f, out / f.name)
    for d in (res / "profiles", HERE.parent / "resources_product" / "profiles"):
        for f in d.glob("*.json"):
            dst = out / "profiles" / f.name
            if not dst.exists():
                os.symlink(f, dst)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline-library", type=Path)
    ap.add_argument("--baseline-resources", type=Path)
    ap.add_argument("--dump", type=Path, help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.dump:
        return dump(args.dump)

    fails: list[str] = []

    def check(ok, what):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            fails.append(what)

    tmp = tempfile.TemporaryDirectory()
    res = bw_checks.overlay(tmp.name)
    e = spk.Engine(resources=res)
    img = frame()
    absent = {}
    print("1-3. the bypasses")
    for name, w in CASES.items():
        a = render(e, img, {**QUIET, **w})
        absent[name] = a
        b = render(e, img, {**QUIET, **w, **DEFAULTS})
        check(np.array_equal(a, b), f"{name}: the four fields at their defaults = absent, to the bit")
        if name in PRINTS:
            v = render(e, img, {**QUIET, **w, "scan_hdr_stretch": True, "scan_hdr_headroom": 4.0,
                                "scan_hdr_output_scale": 0.25})
            check(np.array_equal(a, v), f"{name}: a print ignores the slide variant (stretch, H 4, x1/4)")
            c = render(e, img, {**QUIET, **w},
                       before=lambda s: (s.hdr_curve(), s.hdr_curve({"clip_ev": 3.5}), s.scene_latitude()))
            check(np.array_equal(a, c), f"{name}: the HDR curve asked first leaves the render as it was")
        else:
            v = render(e, img, {**QUIET, **w, "scan_hdr_stretch": True})
            check(not np.array_equal(a, v), f"{name}: the stretch does change a slide (the variant is live)")

    print("4. grain under one seed")
    grain = {**QUIET, **CASES["portra400_supra_optical"], "grain_active": True, "grain_sublayers_active": True}
    g1 = render(e, img, {**grain, "grain_seed": 7})
    g2 = render(e, img, {**grain, "grain_seed": 7})
    check(np.array_equal(g1, g2), "grain_seed 7: two sessions, one picture")
    # `fresh_seed` is a splitmix64 stream per pipeline, so "fresh" is per render of one session (a new
    # session starts the stream again): two renders of one session differ at 0, and not at 7.
    def twice(wire):
        s = e.open(img, wire)
        try:
            a, _ = s.render("full")
            a = a.copy()
            b, _ = s.render("full")
            return a, b.copy()
        finally:
            s.close()
    f1, f2 = twice({**grain})
    check(not np.array_equal(f1, f2), "grain_seed 0 (absent): two renders of a session, two realisations, as today")
    h1, h2 = twice({**grain, "grain_seed": 7})
    check(np.array_equal(h1, h2) and np.array_equal(h1, g1) and not np.array_equal(h1, f1),
          "grain_seed 7: two renders of a session, one realisation (and not seed 0's)")
    default_amount = [f for f in e.params_schema()["fields"] if f["name"] == "grain_amount"][0]["default"]
    trace = Path(tmp.name) / "checkpoint_trace.log"
    with checkpoint_traced(trace):
        s = e.open(img, {**grain, "grain_seed": 7})
        try:
            r1, _ = s.render("full")
            r1 = r1.copy()
            s.set_params({"grain_amount": 0.9})
            s.render("full")
            s.set_params({"grain_amount": default_amount})
            r3, _ = s.render("full")
            r3 = r3.copy()
        finally:
            s.close()
    events = [ln.split()[1] for ln in trace.read_text().splitlines() if ln.startswith("[checkpoint] ")]
    check("saved" in events and "hit" in events,
          f"the grain-only edits went through the pre-grain checkpoint's restore (trace: {events})")
    check(np.array_equal(r1, r3) and np.array_equal(r1, g1),
          "grain_seed 7: a grain-only edit and back on one session renders the seeded picture again")
    e.close()

    if args.baseline_library:
        print("5. today's picture, against the engine before the change")
        with tempfile.TemporaryDirectory() as out:
            base_res = args.baseline_resources or args.baseline_library.parent.parent / "resources"
            env = {**os.environ, "SPEKTRAFILM_ENGINE_LIBRARY": str(args.baseline_library),
                   "SPK_BYPASS_RESOURCES": str(overlay_resources(base_res, out))}
            dump_dir = Path(out) / "dump"
            dump_dir.mkdir()
            subprocess.run([sys.executable, "-I", __file__, "--dump", str(dump_dir)], env=env, check=True)
            for name, a in absent.items():
                b = np.load(dump_dir / f"{name}.npy")
                d = int(np.abs(a.astype(np.int64) - b.astype(np.int64)).max()) if a.shape == b.shape else -1
                check(a.shape == b.shape and d == 0, f"{name}: byte-identical to the engine before the change "
                                                     f"(max |delta| {d} codes)")
    print(f"\nhdr bypass checks: {len(fails)} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
