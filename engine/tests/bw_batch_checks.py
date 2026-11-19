#!/usr/bin/env python3
"""The black-and-white films added from makers' data sheets (2026-11-19), on Multigrade IV RC: the tone
checks of bw_checks.py (neutral print, filter 2 lands mid-grey, harder grade = more contrast, the lens's
colour filters), plus a mid-grey and contrast table against Tri-X and HP5 Plus.

    python3 engine/tests/bw_batch_checks.py [--dylib path] [film ...]
"""
import argparse, json, sys, tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402
from bw_checks import ENGINE, overlay, chart, ramp, render, cells, density, PATCHES  # noqa: E402

REFS = ["kodak_tri_x_400", "ilford_hp5_plus_400"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path, default=None)
    ap.add_argument("--resources", type=Path, default=None,
                    help="a staged engine directory (engine/stage-host.sh) to use as it is, instead of the overlay")
    ap.add_argument("films", nargs="*")
    a = ap.parse_args()
    films = a.films or sorted(p.stem for p in (ENGINE / "resources_product" / "profiles").glob("*.json")
                              if json.loads(p.read_text()).get("info", {}).get("channel_model") == "bw"
                              and json.loads(p.read_text())["info"].get("support") == "film")
    grades = json.loads((ENGINE / "resources_product" / "paper_grades.json").read_text())["grades"]
    pack = lambda g, film: {"film_stock": film, "c_filter_neutral": 0.0, **grades[g]}
    fails = 0

    def check(ok, what, detail=""):
        nonlocal fails
        print(("PASS " if ok else "FAIL ") + what + (" -- " + detail if detail else ""))
        fails += 0 if ok else 1

    names = list(PATCHES)
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=a.dylib, resources=a.resources or overlay(tmp)) as e:
        rows = []
        for film in REFS + [f for f in films if f not in REFS]:
            base = cells(render(e, chart(), pack("2", film)), len(names))
            g = dict(zip(names, base[:, 1]))
            spread = np.abs(base - base[:, 1:2]).max()
            d_mid = density(g["grey"])
            r = cells(render(e, ramp(np.arange(-3, 3.01, 1.0)), pack("2", film)), 7)[:, 1]
            span2 = float(density(r[0]) - density(r[-1]))
            rows.append((film, d_mid, span2))
            if film in REFS:
                continue
            check(spread < 2e-3, f"{film}: a print on Multigrade is neutral", f"largest channel spread {spread:.5f}")
            check(0.55 < d_mid < 0.95, f"{film}: filter 2 prints 18 % grey as a mid-grey", f"displayed density {d_mid:.3f}")
            spans = {}
            for k in ("00", "5"):
                rr = cells(render(e, ramp(np.arange(-3, 3.01, 1.0)), pack(k, film)), 7)[:, 1]
                spans[k] = float(density(rr[0]) - density(rr[-1]))
            spans["2"] = span2
            check(spans["00"] < spans["2"] < spans["5"], f"{film}: a harder Multigrade filter prints more contrast",
                  str({k: round(v, 3) for k, v in spans.items()}))
            red = dict(zip(names, cells(render(e, chart(), {**pack("2", film), "camera_filter": "w25"}), len(names))[:, 1]))
            check(abs(red["grey"] - g["grey"]) < 0.01, f"{film}: a red filter leaves 18 % grey where it was",
                  f"{g['grey']:.4f} -> {red['grey']:.4f}")
            check(red["sky"] < g["sky"] - 0.02, f"{film}: a red filter darkens the sky", f"{g['sky']:.3f} -> {red['sky']:.3f}")
        print("\nfilm                             mid-grey D   7-stop span (filter 2)")
        for film, d, sp in rows:
            print(f"{film:32s} {d:8.3f}   {sp:8.3f}")
    print(f"{fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
