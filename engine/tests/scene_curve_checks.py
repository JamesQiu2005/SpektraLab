#!/usr/bin/env python3
"""The Decode curve (`scene_curve`, API-SPEC §17). Needs only `build.sh dylib`.

    python3 engine/tests/scene_curve_checks.py [--dylib path]

The curve is a gain on the linear scene after the meter and before Exp.
Comp., on Scene Latitude's stop axis (±8 stops about the metered mid-grey).
So a row that lifts every value by one stop -- y = x + 1/16 -- must render a
ramp as the same ramp with its input doubled, and only that row's channels;
"" must be the render without the field, to the bit. Grain, glare, halation
and the meter are off: what is compared is the tone path.

RFC-035 §5.3: the table is read at E + c, c = `exposure_compensation_ev`, so
the curve is drawn on the scene *as exposed onto the film*. Film Exposure +1
is then the input doubled with the curve included: a bump at film stop 0 under
c = 1 must render as the same bump under c = 0 on the doubled ramp. That is
the RFC's "a lift at E = 0 with c = 1 is the lift at E = -1 with c = 0",
written on the input so the two renders expose the film alike; the product's
print (`product_defaults`, no enlarger re-timing, trap 30) so the print does
not tell c from an input gain either. A uniform lift commutes with any shift
and could not fail this, so the bump is local.
"""
import argparse, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

QUIET = {"grain_active": False, "glare_active": False, "halation_active": False, "dir_couplers_active": False,
         "auto_exposure": False, "input_cctf_decoding": False, "input_color_space": "sRGB",
         "output_color_space": "sRGB", "output_cctf_encoding": True}
N = 129           # samples a row, as the app sends them
STOPS = 8.0       # kSceneCurveStops
ROWS = ("rgb", "luma", "r", "g", "b")
P = 32


def ramp(stops, tint=(1.0, 1.0, 1.0)):
    row = np.repeat(0.184 * 2.0 ** np.asarray(stops, float), P)
    img = np.tile(row[None, :, None], (P, 1, 3)) * np.asarray(tint)[None, None, :]
    return img.astype(np.float32)


def table(**lifted):
    """Five rows; each named row lifted by that many stops, the others the identity."""
    x = np.linspace(0.0, 1.0, N)
    rows = [np.clip(x + lifted.get(name, 0.0) / (2 * STOPS), 0.0, 1.0) for name in ROWS]
    return ",".join(f"{v:.5f}" for v in np.concatenate(rows))


def bump(at, stops=1.0, width=1.0):
    """The rgb row lifted by `stops` at film stop `at`, a Gaussian `width` stops wide; the others the identity."""
    x = np.linspace(0.0, 1.0, N)
    E = -STOPS + 2 * STOPS * x
    rows = [x] * len(ROWS)
    rows[0] = np.clip(x + stops * np.exp(-0.5 * ((E - at) / width) ** 2) / (2 * STOPS), 0.0, 1.0)
    return ",".join(f"{v:.5f}" for v in np.concatenate(rows))


def render(e, img, extra):
    s = e.open(img, {**QUIET, **extra})
    try:
        rgba, _ = s.render("full")
    finally:
        s.close()
    return rgba[..., :3].astype(np.float64) / 65535.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib")
    args = ap.parse_args()
    e = spk.Engine(dylib=args.dylib)
    failures = 0

    def check(ok, what, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'ok  ' if ok else 'FAIL'} {what}{'  ' + detail if detail else ''}")

    stops = np.linspace(-4, 4, 9)
    base = ramp(stops)
    plain = render(e, base, {})
    check(np.array_equal(plain, render(e, base, {"scene_curve": ""})), '"" is the render without the field, to the bit')

    ident = render(e, base, {"scene_curve": table()})
    d = np.abs(ident - plain).max()
    check(d < 2e-3, "the identity table is no change", f"max |d| {d:.2e}")

    doubled = render(e, ramp(stops + 1), {})
    for row in ("rgb", "luma"):
        got = render(e, base, {"scene_curve": table(**{row: 1.0})})
        d = np.abs(got - doubled).max()
        check(d < 2e-3, f"{row} +1 stop is the input doubled", f"max |d| {d:.2e}")
    moved = np.abs(render(e, base, {"scene_curve": table(rgb=1.0)}) - plain).max()
    check(moved > 0.05, "+1 stop moves the picture (the check can fail)", f"max |d| {moved:.3f}")

    red = render(e, base, {"scene_curve": table(r=1.0)})
    red_in = render(e, ramp(stops, (2.0, 1.0, 1.0)), {})
    d = np.abs(red - red_in).max()
    check(d < 2e-3, "r +1 stop is the red input doubled, and no other", f"max |d| {d:.2e}")

    # Past the table's ends the end's gain holds: a +1 stop row on a ramp to +10 stops.
    far = np.linspace(6, 10, 5)
    got = render(e, ramp(far), {"scene_curve": table(rgb=-1.0)})
    want = render(e, ramp(far - 1), {})
    d = np.abs(got - want).max()
    check(d < 2e-3, "beyond +8 stops the end's gain holds", f"max |d| {d:.2e}")

    # RFC-035 §5.3: the curve reads Film Exposure.
    fine = np.linspace(-4, 4, 33)
    prod = {"product_defaults": True}
    exposed = render(e, ramp(fine), {**prod, "exposure_compensation_ev": 1.0, "scene_curve": bump(0.0)})
    doubled = render(e, ramp(fine + 1), {**prod, "scene_curve": bump(0.0)})
    d = np.abs(exposed - doubled).max()
    check(d < 2e-3, "c = +1 with a bump at film 0 is the bump on the doubled input", f"max |d| {d:.2e}")
    plain_c = render(e, ramp(fine), {**prod, "exposure_compensation_ev": 1.0})
    moved = np.abs(exposed - plain_c).max()
    check(moved > 0.05, "the bump moves the picture under c = +1 (the check can fail)", f"max |d| {moved:.3f}")

    # RFC-035 §5.3: the window is the film and paper's own -- probed with no
    # curve and, on the product's print, no Film Exposure -- so on the film's
    # axis (reply stops + `exposure_ev`) it moves with neither.
    def latitude(img, extra):
        s = e.open(img, {**prod, **extra})
        try:
            return s.scene_latitude({})
        finally:
            s.close()
    windows = []
    for c in (0.0, 1.0):
        for curve in ("", table(rgb=1.0)):
            r = latitude(base, {"exposure_compensation_ev": c, "scene_curve": curve})
            x = r["scene"]["histogram"]["exposure_ev"]
            windows.append((r["medium"]["shadow_ev"] + x, r["medium"]["highlight_ev"] + x))
    spread = np.ptp(np.asarray(windows), axis=0).max()
    check(spread < 1e-3, "the window on the film's axis moves with neither c nor the curve",
          f"{windows[0][0]:+.3f}/{windows[0][1]:+.3f}, spread {spread:.1e}")

    # RFC-035 §5.2: R, G, B histograms on the luminance's bins. A neutral
    # frame has all three equal to `fractions`; doubling red moves only red's,
    # by four quarter-stop bins.
    h = latitude(base, {})["scene"]["histogram"]
    f = np.asarray(h["fractions"])
    rgb = [np.asarray(h[k]) for k in ("fractions_r", "fractions_g", "fractions_b")]
    d = max(np.abs(c - f).max() for c in rgb)
    check(all(len(c) == len(f) for c in rgb) and d < 1e-9, "a neutral frame's R, G, B histograms are its luminance's",
          f"max |d| {d:.1e}")
    t = latitude(ramp(stops, (2.0, 1.0, 1.0)), {"auto_exposure": False})["scene"]["histogram"]
    g = latitude(base, {"auto_exposure": False})["scene"]["histogram"]
    r_ok = np.array_equal(np.asarray(t["fractions_r"]), np.roll(np.asarray(g["fractions_r"]), 4))
    gb_ok = all(np.array_equal(np.asarray(t[k]), np.asarray(g[k])) for k in ("fractions_g", "fractions_b"))
    check(r_ok and gb_ok, "red doubled moves red's histogram one stop, and no other")

    for bad, why in (("0.5,2", "a value outside 0..1"), ("0.1,0.2,0.3", "not five rows"), ("a,b", "not numbers")):
        try:
            render(e, base, {"scene_curve": bad})
            check(False, f"refuses {why}")
        except spk.EngineError as err:
            check("scene_curve" in str(err), f"refuses {why}", str(err)[:80])

    print("all passed" if failures == 0 else f"{failures} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
