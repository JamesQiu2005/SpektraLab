"""What the engine renders as diffuse RMS granularity at grain_amount 1, per film.

    python3 engine/tools/fujifilm_data_guide/grain_probe.py RESOURCES film[:pos] [...]

A uniform grey on a 36 mm frame 6000 px wide (6 um pixels), scanned (no print), grain on with
its sub-layers (the app's default), glare/halation/blur off. The exposure is set so the film's net
green density is 1.0 over D-min (the makers' sample density), then the density is averaged in a
48 um circle-equivalent aperture (8 x 8 px, 2304 um^2 against the circle's 1810) and
RMS granularity = 1000 x its standard deviation, per channel (R, G, B) and visual (0.2/0.7/0.1).
"""
import sys
import numpy as np
import scipy.optimize
sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__import__("os").path.abspath(__file__)), "../../tests"))
import spk_ctypes as spk  # noqa: E402

from pathlib import Path
W = str(Path(__file__).resolve().parents[3])
BASE = {"grain_active": False, "glare_active": False, "halation_active": False, "auto_exposure": False,
        "input_cctf_decoding": False, "input_color_space": "sRGB", "output_color_space": "sRGB",
        "output_cctf_encoding": False, "scan_film": True, "scanner_white_correction": False,
        "scanner_black_correction": False, "scanner_lens_blur": 0.0, "lens_blur_um": 0.0,
        "film_format_mm": 36.0, "grain_sublayers_active": True}


def density(rgba):
    t = rgba[..., :3].astype(np.float64) / 65535.0
    return -np.log10(np.clip(t, 1e-6, None))


def probe(e, film, positive, n=6000, h=480):
    small = np.full((32, 32, 3), 0.184, np.float32)

    def mean_d(ev, grain=False):
        s = e.open(small, dict(BASE, film_stock=film, print_stock="kodak_portra_endura"))
        try:
            s.set_params({"exposure_compensation_ev": float(ev)})
            r, _ = s.render("full")
        finally:
            s.close()
        return density(r)[4:-4, 4:-4].mean((0, 1))

    dmin = mean_d(-8 if not positive else 8)
    target = 1.0
    f = lambda ev: (mean_d(ev) - dmin)[1] - target
    lo, hi = -6.0, 6.0
    ev = scipy.optimize.brentq(f, lo, hi, xtol=1e-3)
    img = np.full((h, n, 3), 0.184, np.float32)
    s = e.open(img, dict(BASE, film_stock=film, print_stock="kodak_portra_endura", grain_active=True,
                         grain_amount=1.0, exposure_compensation_ev=float(ev), grain_seed=7))
    try:
        r, _ = s.render("full")
    finally:
        s.close()
    d = density(r)[16:-16, 16:-16]
    hh, ww = (d.shape[0] // 8) * 8, (d.shape[1] // 8) * 8
    a = d[:hh, :ww].reshape(hh // 8, 8, ww // 8, 8, 3).mean((1, 3))
    rms = 1000 * a.reshape(-1, 3).std(0)
    vis = 1000 * (a.reshape(-1, 3) @ np.array([0.2, 0.7, 0.1])).std()
    return ev, (d.mean((0, 1)) - dmin), rms, vis


if __name__ == "__main__":
    e = spk.Engine(library=W + "/build/linux/engine/spektralab_engine.so", resources=sys.argv[1])
    for film in sys.argv[2:]:
        name, _, kind = film.partition(":")
        ev, net, rms, vis = probe(e, name, kind == "pos")
        print(f"{name}: ev {ev:+.2f} net D {np.round(net, 3).tolist()} RMS@1 R/G/B {np.round(rms, 2).tolist()} visual {vis:.2f}", flush=True)
