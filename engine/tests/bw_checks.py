#!/usr/bin/env python3
"""Black and white: the product's films (Tri-X 400, T-Max 100, Neopan 100 Acros II,
HP5 Plus) on Multigrade IV RC, and the lens's colour filter.
Needs only `build.sh dylib`.

    python3 engine/tests/bw_checks.py [--dylib path]

The profiles are the product's (`engine/resources_product/`) and nothing
installs them, so this overlays them on `engine/resources/` in a scratch
directory and points the engine there. Grain, glare and halation are off:
what is compared is the tone path. Against an engine from before
`camera_filter` the filter checks fail (`unknown parameter`).
"""
import argparse, json, os, sys, tempfile
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

ENGINE = Path(__file__).resolve().parents[1]
PAPER = "ilford_multigrade_iv_rc"
# stock -> the host's edge text
FILMS = {"kodak_tri_x_400": "KODAK 400TX", "kodak_tmax_100": "KODAK 100TMX",
         "fujifilm_neopan_acros_100_ii": "FUJI 100 ACROS II", "ilford_hp5_plus_400": "ILFORD HP5 PLUS"}
QUIET = {"grain_active": False, "glare_active": False, "halation_active": False, "dir_couplers_active": False,
         "auto_exposure": False, "input_cctf_decoding": False, "input_color_space": "sRGB",
         "output_color_space": "sRGB", "output_cctf_encoding": True}
# linear sRGB patches: 18 % grey, a red, a green, a sky blue, a deep blue
PATCHES = {"grey": (.184, .184, .184), "red": (.45, .04, .03), "green": (.08, .25, .06), "sky": (.15, .28, .55),
           "blue": (.03, .05, .35)}
P = 64


def overlay(tmp):
    """engine/resources with the product's profiles laid over it, by symlink."""
    res = Path(tmp) / "resources"
    (res / "profiles").mkdir(parents=True)
    for f in (ENGINE / "resources").iterdir():
        if f.name != "profiles":
            os.symlink(f, res / f.name)
    for d in (ENGINE / "resources" / "profiles", ENGINE / "resources_product" / "profiles"):
        for f in d.glob("*.json"):
            os.symlink(f, res / "profiles" / f.name)
    return res


def chart():
    img = np.zeros((P, P * len(PATCHES), 3), np.float32)
    for i, v in enumerate(PATCHES.values()):
        img[:, i * P:(i + 1) * P] = v
    return img


def ramp(stops):
    row = np.repeat(0.184 * 2.0 ** np.asarray(stops, float), P)
    return np.tile(row[None, :, None], (P, 1, 3)).astype(np.float32)


def render(e, img, extra):
    s = e.open(img, {**QUIET, "print_stock": PAPER, **extra})
    try:
        rgba, _ = s.render("full")
    finally:
        s.close()
    return rgba[..., :3].astype(np.float64) / 65535.0


def cells(v, n):
    return np.array([v[8:-8, i * P + 8:(i + 1) * P - 8].mean((0, 1)) for i in range(n)])


def density(enc):
    """Reflection density of an sRGB-encoded grey."""
    lin = np.where(enc <= 0.04045, enc / 12.92, ((enc + 0.055) / 1.055) ** 2.4)
    return -np.log10(np.maximum(lin, 1e-6))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path, default=None)
    a = ap.parse_args()
    grades = json.loads((ENGINE / "resources_product" / "paper_grades.json").read_text())["grades"]
    pack = lambda g, film: {"film_stock": film, "c_filter_neutral": 0.0, **grades[g]}
    fails = 0

    def check(ok, what, detail=""):
        nonlocal fails
        print(("PASS " if ok else "FAIL ") + what + (" -- " + detail if detail else ""))
        fails += 0 if ok else 1

    with tempfile.TemporaryDirectory() as tmp, spk.Engine(dylib=a.dylib, resources=overlay(tmp)) as e:
        for film in FILMS:
            names = list(PATCHES)
            base = cells(render(e, chart(), pack("2", film)), len(names))
            g = dict(zip(names, base[:, 1]))

            # 1. the print is a silver print: no colour anywhere on the chart
            spread = np.abs(base - base[:, 1:2]).max()
            check(spread < 2e-3, f"{film}: a print on Multigrade is neutral", f"largest channel spread {spread:.5f}")

            # 2. filter 2 lands mid-grey without tuning. The output stage lifts the
            #    paper's white, so the displayed density of the sheet's mid-grey is
            #    a band, not a point.
            d_mid = density(g["grey"])
            check(0.55 < d_mid < 0.95, f"{film}: filter 2 prints 18 % grey as a mid-grey", f"displayed density {d_mid:.3f}")

            # 3. grade is contrast: the same seven-stop ramp spans more print
            #    density through a harder filter, and the grades come out in order.
            spans = {}
            for k in ("00", "2", "5"):
                r = cells(render(e, ramp(np.arange(-3, 3.01, 1.0)), pack(k, film)), 7)[:, 1]
                spans[k] = float(density(r[0]) - density(r[-1]))
            check(spans["00"] < spans["2"] < spans["5"] and spans["5"] > 1.3 * spans["00"],
                  f"{film}: a harder Multigrade filter prints more contrast", str({k: round(v, 3) for k, v in spans.items()}))

            # 4. the lens's filter: the factor is given, and colours move the way
            #    the glass says.
            red = dict(zip(names, cells(render(e, chart(), {**pack("2", film), "camera_filter": "w25"}), len(names))[:, 1]))
            blue = dict(zip(names, cells(render(e, chart(), {**pack("2", film), "camera_filter": "w47"}), len(names))[:, 1]))
            check(abs(red["grey"] - g["grey"]) < 0.01 and abs(blue["grey"] - g["grey"]) < 0.01,
                  f"{film}: a filter leaves 18 % grey where it was", f"none {g['grey']:.4f}, w25 {red['grey']:.4f}, w47 {blue['grey']:.4f}")
            check(red["red"] > g["red"] + 0.05 and red["sky"] < g["sky"] - 0.05 and red["blue"] < g["blue"] - 0.05,
                  f"{film}: a red filter lightens red and darkens sky and blue",
                  f"red {g['red']:.3f}->{red['red']:.3f}, sky {g['sky']:.3f}->{red['sky']:.3f}, blue {g['blue']:.3f}->{red['blue']:.3f}")
            check(blue["blue"] > g["blue"] + 0.05 and blue["red"] < g["red"] - 0.05,
                  f"{film}: a blue filter lightens blue and darkens red",
                  f"blue {g['blue']:.3f}->{blue['blue']:.3f}, red {g['red']:.3f}->{blue['red']:.3f}")
            # 5. the film's edge never passes the lens, carries no DX bars, and is
            #    grey: a 135 negative scan with and without the red filter.
            rng = np.random.default_rng(1)
            y, x = np.mgrid[0:400, 0:600]
            pic = (0.05 + 0.5 * (x / 600)[..., None] * np.array([1.0, 0.6, 0.2]) + 0.2 * (y / 400)[..., None]).astype(np.float32)
            edge = {"film_stock": film, "scan_film": True, "overscan_active": True, "overscan_format": "135", "overscan_edge_text": FILMS[film],
                    "overscan_frame_number": 15, "overscan_camera_seed": 3, "overscan_frame_seed": 5}
            a0 = render(e, pic, edge)
            a1 = render(e, pic, {**edge, "camera_filter": "w25"})
            d = np.abs(a0 - a1).max(2)
            h = d.shape[0]
            band = max(4, int(h * 0.045))               # the rebates run along the top and bottom of a landscape frame
            rebate = max(d[:band].max(), d[-band:].max())
            middle = d[h // 3:2 * h // 3, d.shape[1] // 3:2 * d.shape[1] // 3].mean()
            # the band must be rebate with the edge print in it, or the check proves nothing
            inked = float(min(a0[:band, :, 1].std(), a0[-band:, :, 1].std()))
            check(rebate < 0.01 and middle > 0.02 and inked > 0.02, f"{film}: the filter shapes the picture and not the film's edge",
                  f"rebate max {rebate:.4f}, picture mean {middle:.4f}, edge print std {inked:.3f}")
            check(np.abs(a0 - a0[..., 1:2]).max() < 0.01, f"{film}: the negative and its rebate are grey",
                  f"largest channel spread {np.abs(a0 - a0[..., 1:2]).max():.4f}")
        try:
            render(e, chart(), {**pack("2", "kodak_tri_x_400"), "camera_filter": "w99"})
            check(False, "an unknown filter is refused")
        except spk.EngineError as ex:
            check("camera_filter" in str(ex), "an unknown filter is refused", str(ex)[:60])


        # 6. HP5 Plus carries a DX code, turned half a turn against Kodak's: it
        #    reads back with the print turned, and not as it lies. Tri-X prints none.
        from overscan_checks import decode_dx, frame
        img, px = frame(1200, 800), 36.25 / 1200

        def edge_print(film):
            s = e.open(img, {"film_stock": film, "print_stock": PAPER, **pack("2", film), "grain_active": False,
                             "glare_active": False, "auto_exposure": False, "overscan_active": True,
                             "overscan_format": "135", "overscan_edge_text": FILMS[film], "overscan_frame_number": 12})
            try:
                return s.render("live")[0]
            finally:
                s.close()
        hp = edge_print("ilford_hp5_plus_400")
        dx = decode_dx(hp[::-1, ::-1], px)
        check(dx is not None and dx[0] == 1753 and dx[3] and dx[1] in (11, 12, 13),
              "HP5 Plus's DX code reads back turned (1753 = 109/9, this frame's number, good parity)", str(dx))
        check(decode_dx(hp, px) is None, "and not the way Kodak's lies")
        check(decode_dx(edge_print("kodak_tri_x_400"), px) is None and decode_dx(edge_print("kodak_tmax_100"), px) is None,
              "Tri-X and T-Max print no DX bars")

    print(f"{fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
