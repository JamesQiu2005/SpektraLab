#!/usr/bin/env python3
"""`scan_hdr` on the Linux/Vulkan engine (spk_scan_hdr_expand.comp), without the study's data.

    SPEKTRALAB_ENGINE_LIBRARY=build/linux/engine/spektralab_engine.so \
    SPEKTRALAB_ENGINE_RESOURCES=build/host-linux-x64/engine python3 -I engine/tests/scan_hdr_vulkan_checks.py

scan_hdr_checks.py holds the variant against the study (rfc/audits, outside this repository). These are its
checks that need none of it, on the same ramps, for the four slides:
  1. with the fields at their defaults the scan is today's, to the bit, and the engine reports no model;
  2. the stretch, couplers off, is byte-identical to today's on every ramp below its reach of the first knee
     less 1/4 stop, and differs above the last knee (the expansion ran);
  3. flat fields at -2 ... 0 EV with the couplers on: the stretch is today's, to the bit;
  4. the HDR rendition (H = 4, output scale 1/4) renders finite, with the clear base's highlights separated
     more than today's scan separates them (+1.5 ... +3.5 EV on the neutral).
Exit 1 on any failure.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import spk_ctypes as spk  # noqa: E402
import scan_hdr_checks as ref  # noqa: E402


def main() -> int:
    rs = ref.ramps()
    img = ref.frame(rs)
    e = spk.Engine()
    fails: list[str] = []

    def check(ok, what):
        print(("  ok    " if ok else "  FAIL  ") + what)
        if not ok:
            fails.append(what)

    def render(src, film, **extra):
        s = e.open(src, {**ref.WIRE, **ref.QUIET, "film_stock": film, **extra})
        try:
            rgba, _ = s.render("full")
            prog = s.progress()
        finally:
            s.close()
        return rgba, prog

    for film in ref.FILMS:
        print(film)
        today, p_today = render(img, film)
        bare, _ = render(img, film, scan_hdr_headroom=0.0, scan_hdr_stretch=False, scan_hdr_output_scale=1.0)
        check("scan_hdr" not in p_today and np.array_equal(today, bare), "defaults: today's scan, to the bit")
        nc = {"dir_couplers_active": False}
        t_nc, _ = render(img, film, **nc)
        s_nc, p_sdr = render(img, film, scan_hdr_stretch=True, **nc)
        knees = np.array(p_sdr["scan_hdr"]["knee_stops"])
        t, s = ref.steps(t_nc), ref.steps(s_nc)
        ahead = np.log2(np.array([v[np.argmin(np.abs(ref.EV))].max() for v in rs.values()]) / ref.MID)
        below = (ref.EV[None, :] + ahead[:, None]) <= knees.min() - 0.25
        same = all(np.array_equal(s[r, below[r]], t[r, below[r]]) for r in range(len(rs)))
        above = ref.EV > knees.max() + 0.5
        moved = not np.array_equal(s[0, above], t[0, above])
        check(same and moved, f"stretch, couplers off: identical below the first knee, moved above the last "
                              f"(knees {', '.join(f'{k:+.2f}' for k in knees)} stops)")
        flat_ok = True
        for ev in (-2.0, -1.0, -0.5, 0.0):
            flat = np.full((64, 96, 3), ref.MID * 2.0 ** ev, np.float32)
            a, _ = render(flat, film)
            b, _ = render(flat, film, scan_hdr_stretch=True)
            flat_ok &= np.array_equal(a, b)
        check(flat_ok, "stretch, couplers on: flat fields at -2, -1, -1/2 and 0 EV identical to today's")
        lin = dict(output_cctf_encoding=False)
        h4, _ = render(img, film, scan_hdr_headroom=4.0, scan_hdr_output_scale=0.25, **lin)
        h4s = ref.steps(h4).astype(float) / 65535.0
        ts = ref.steps(today).astype(float) / 65535.0
        check(bool(np.isfinite(h4s).all()) and ref.separation(h4s) > ref.separation(ts),
              f"HDR rendition: finite, highlights +1.5...+3.5 EV separated {ref.separation(h4s):.2f} stops "
              f"(today's scan {ref.separation(ts):.2f})")
    print(f"scan_hdr (Vulkan): {len(fails)} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
