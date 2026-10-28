#!/usr/bin/env python3
"""CineStill 800T: the alias profile, the back-reflection halo and its headroom.
Needs only `build.sh dylib`.

    python3 engine/tests/cinestill_checks.py [--dylib path]

The profile is the product's (`engine/resources_product/`), so this overlays it on
`engine/resources/` in a scratch directory, as `bw_checks.py` does. Every check is
on synthetic frames whose geometry is known, so each one can fail:

* the ring check fails on the Gaussian bounces (a monotonic halo, no gap);
* the gate check fails if the headroom is keyed to mid-grey alone (the bright
  patch, three stops under the lamp, would halate too);
* the headroom check fails if the field is not wired, or too weak to see.
"""
import argparse, os, sys, tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

ENGINE = Path(__file__).resolve().parents[1]
BASE = {"input_cctf_decoding": False, "input_color_space": "sRGB", "output_color_space": "sRGB",
        "output_cctf_encoding": True, "print_stock": "kodak_2383", "grain_active": False,
        "glare_active": False, "auto_exposure": False, "film_format_mm": 36.0}
W, H = 2048, 1366                    # 17.6 um a pixel on a 36 mm frame
D_PX = 120.0 / (36000.0 / W)         # the base, 6.8 px


def overlay(tmp):
    res = Path(tmp) / "resources"
    (res / "profiles").mkdir(parents=True)
    for f in (ENGINE / "resources").iterdir():
        if f.name != "profiles":
            os.symlink(f, res / f.name)
    for d in (ENGINE / "resources" / "profiles", ENGINE / "resources_product" / "profiles"):
        for f in d.glob("*.json"):
            if not (res / "profiles" / f.name).exists():
                os.symlink(f, res / "profiles" / f.name)
    return res


def render(e, img, extra):
    s = e.open(np.ascontiguousarray(img, np.float32), {**BASE, **extra})
    try:
        rgba, _ = s.render("full")
    finally:
        s.close()
    return rgba[..., :3].astype(np.float64) / 65535.0


def disc(img, cx, cy, r, value):
    y, x = np.mgrid[0:img.shape[0], 0:img.shape[1]]
    img[(x - cx) ** 2 + (y - cy) ** 2 <= r * r] = value
    return img


def radial(chan, cx, cy, r_max):
    y, x = np.mgrid[0:chan.shape[0], 0:chan.shape[1]]
    rr = np.hypot(x - cx, y - cy)
    edges = np.arange(0, r_max + 1, 1.0)
    return edges[:-1] + 0.5, np.array([chan[(rr >= a) & (rr < b)].mean() for a, b in zip(edges[:-1], edges[1:])])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path, default=None)
    a = ap.parse_args()
    fails = 0

    def check(ok, what, detail=""):
        nonlocal fails
        print(("PASS " if ok else "FAIL ") + what + (" -- " + detail if detail else ""))
        fails += 0 if ok else 1

    bg = 0.184 / 16                    # a night: four stops under mid-grey
    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=a.dylib, resources=overlay(tmp)) as e:
        # 1. the alias renders, and is not its base: same film, different halo
        lamp = disc(np.full((H, W, 3), bg, np.float32), W // 2, H // 2, 1.5, 0.184 * 2 ** 3.5)
        cs = render(e, lamp, {"film_stock": "cinestill_800t"})
        v3 = render(e, lamp, {"film_stock": "kodak_vision3_500t"})
        far = (slice(0, 200), slice(0, 200))
        check(np.abs(cs[far] - v3[far]).max() < 2 / 255, "cinestill_800t is Vision3 500T's emulsion away from the light",
              f"max diff far from the lamp {np.abs(cs[far] - v3[far]).max() * 255:.2f}/255")

        # 2. a film with a layer ignores the field, byte for byte
        v3_8 = render(e, lamp, {"film_stock": "kodak_vision3_500t", "halation_headroom_ev": 8.0})
        check(np.array_equal(v3, v3_8), "a film with an anti-halation layer ignores halation_headroom_ev")

        # 3. the rim: a point light on a film with no layer shows a disc whose rim, at the
        #    critical angle's ~2 d, is brighter than its inside (a Gaussian halo falls
        #    monotonically). The halo alone is the render less the same render with a
        #    vanishing halo (amount 1e-6: the headroom still applies, and the scan's
        #    sharpening and the couplers' adjacency dip -- both darken the film beside
        #    a bright source -- cancel). Read raw, either would hand this check a
        #    negative "inside" it passes against for nothing; `halation_active: false`
        #    would also drop the headroom and change the source.
        bare = render(e, lamp, {"film_stock": "cinestill_800t", "halation_amount": 1e-6})
        r, prof = radial(cs[..., 0] - bare[..., 0], W // 2, H // 2, int(8 * D_PX))
        gap = (r > 0.7 * D_PX) & (r < 1.3 * D_PX)
        ring = (r > 1.6 * D_PX) & (r < 2.8 * D_PX)
        g, k = prof[gap].min(), prof[ring].max()
        r_peak = r[ring][np.argmax(prof[ring])] / D_PX
        check(g > -0.25 / 255 and k > 2 * g + 1 / 255, "a point light's halo has a brighter rim at ~2 d, not a monotonic blob",
              f"inside {g * 255:.2f}, rim {k * 255:.2f} /255 at r = {r_peak:.2f} d")

        # 3b. the red reaches further than the green at any brightness (GPT Astra's
        #     measurement of five lights in the CineStill scans: half-height radius
        #     red/green 1.49-2.65). A disc at +9 and +12 EV, headroom off so the
        #     exposure is what is given.
        hW, hH = 1100, 420
        yy, xx = np.mgrid[:hH, :hW]
        rr = np.hypot(xx - hW // 2, yy - hH // 2)
        for ev in (9, 12):
            dot = np.full((hH, hW, 3), 0.0005, np.float32)
            dot[rr < 5] = 0.18 * 2 ** ev
            o = render(e, dot, {"film_stock": "cinestill_800t", "halation_headroom_ev": 0.0})
            pr = np.array([np.median(o[(rr >= a) & (rr < a + 1)], axis=0) for a in range(60)])
            ex = pr - np.median(pr[-5:], axis=0)
            half = []
            for c in range(2):
                lvl = ex[:2, c].max() / 2
                i = next((i for i in range(1, 60) if ex[i, c] <= lvl < ex[i - 1, c]), None)
                half.append(np.interp(lvl, [ex[i, c], ex[i - 1, c]], [i + .5, i - .5]) if i else np.nan)
            ratio = half[0] / half[1]
            check(1.49 <= ratio <= 2.65, f"at +{ev} EV the red halo reaches 1.49-2.65x as far as the green, as the scans do",
                  f"{half[0]:.1f} / {half[1]:.1f} px = {ratio:.2f}")
        # 1.3.4 (the owner's decision): the model is CineStill's own. A film whose layer
        # is switched off keeps 1.3.3's Gaussian halo -- it is not CineStill, and the
        # headroom (back-reflection only) leaves it alone.
        off_0 = render(e, lamp, {"film_stock": "kodak_vision3_500t", "antihalation_removed": True,
                                 "halation_headroom_ev": 0.0})
        off_8 = render(e, lamp, {"film_stock": "kodak_vision3_500t", "antihalation_removed": True,
                                 "halation_headroom_ev": 8.0})
        check(np.array_equal(off_0, off_8) and np.abs(off_0 - cs).max() > 10 / 255,
              "a film with its layer switched off keeps 1.3.3's halo, not CineStill's",
              f"headroom 0 vs 8 identical: {np.array_equal(off_0, off_8)}, against CineStill {np.abs(off_0 - cs).max() * 255:.1f}/255")

        # 4. the gate: a lamp at the frame's maximum, and a bright patch three stops under it
        #    that a night's auto-exposure could have put at +2.5 EV
        scene = np.full((H, W, 3), bg, np.float32)
        scene = disc(scene, 500, H // 2, 3, 0.184 * 2 ** 5.5)
        scene[H // 2 - 80:H // 2 + 80, 1300:1460] = 0.184 * 2 ** 2.5
        h0 = render(e, scene, {"film_stock": "cinestill_800t", "halation_headroom_ev": 0.0})
        h4 = render(e, scene, {"film_stock": "cinestill_800t", "halation_headroom_ev": 4.0})
        patch_halo = (slice(H // 2 - 80, H // 2 + 80), slice(1460 + 4, 1460 + 30))   # just right of the patch
        lamp_halo = (slice(H // 2 - 30, H // 2 + 30), slice(500 + 8, 500 + 30))
        dp = np.abs(h4[patch_halo] - h0[patch_halo]).mean() * 255
        dl = (h4[lamp_halo] - h0[lamp_halo])[..., 0].mean() * 255
        check(dp < 0.5 and dl > 10, "headroom lifts the clipped lamp's halo and leaves a bright unclipped patch alone",
              f"beside the patch {dp:.2f}/255, beside the lamp +{dl:.1f}/255 red")

        # 5. the top of the range against the default, where the user drags it
        h8 = render(e, scene, {"film_stock": "cinestill_800t", "halation_headroom_ev": 8.0})
        d84 = (h8[lamp_halo] - h4[lamp_halo])[..., 0].mean() * 255
        moved = (np.abs(h8 - h4).max(2) > 2 / 255).mean() * 100
        check(d84 > 5 and moved > 0.5, "halation_headroom_ev 8 is visibly more than 4",
              f"+{d84:.1f}/255 red beside the lamp, {moved:.2f} % of pixels moved > 2/255")

    print(f"{fails} failed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
