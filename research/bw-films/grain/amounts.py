"""Per-film default grain_amount for the four B&W profiles, checked on renders, and what it costs.

  A. amount = published / engine RMS at grain_amount 1 (engine_rms_bw.json), per grain path and pitch.
  B. VERIFY: render the net-D-1.0 patch at that amount (clamped to the wire's 0..2) at 6 um and read
     the RMS back -- the number the film would actually show.
  C. COST: node_grain is out = in + k (grained - in) and `grained` carries the node's 0.65 px blur of
     the picture, so k scales that blur. Contrast of vertical stripes (period 2, 3, 4, 8 px, +-1 stop
     around the D 1.0 exposure) in density, relative to grain_amount 0, at k = 1 and at the film's k.
     Predicted: 1 - k (1 - exp(-2 pi^2 0.65^2 / period^2)).

    python amounts.py      -> bw_grain_amount.json, bw_grain_amount.csv   (needs measure_bw.py's output)
"""
import csv, json
import numpy as np
from galib import *
from measure_bw import rms48

PUBLISHED = {   # stock: (rms, tag, basis)
    "kodak_tri_x_400": (17, "SHEET", "Kodak F-4017 (Feb 2016) p6: net diffuse density 1.0, 48 um, 12X, HC-110 B"),
    "kodak_tmax_100": (8, "SHEET", "Kodak F-4016 (June 2018) p8: net diffuse density 1.00, 48 um, 12X, D-76 68F"),
    "fujifilm_neopan_acros_100_ii": (7, "SHEET", "Fujifilm AF3-0258E p3: 48 um, 1.0 above minimum density, MICROFINE (profile curve is D-76)"),
    "ilford_hp5_plus_400": (16, "SHEET (other product)", "Ilford HP5 Plus negative MOTION PICTURE fact sheet (1997): D-96 6 min 75F, "
                            "gamma 0.65-0.70; aperture and density NOT stated; the still-film sheet publishes none"),
}
PX, N, LO, HI = 6.0, 2048, 0.0, 2.0
ref = json.load(open(HERE / "engine_rms_bw.json"))


def stripes(e, probe, level, amount, sub, n=1536):
    out = {}
    for period in (2, 3, 4, 8):
        carrier = np.cos(2 * np.pi * np.arange(n) / period)
        frame = np.empty((n, n, 3), np.float32)
        frame[:] = (level * 2.0 ** carrier)[None, :, None]
        d = to_density(render_lin(e, probe, frame, PX, grain_amount=amount, grain_sublayers_active=sub), crop=0)
        m = slice(48, n - 48)
        c = carrier[None, m] * np.ones((n - 96, 1))
        out[period] = float((d[m, m] * c).mean() / (c ** 2).mean())
    return out


if __name__ == "__main__":
    build_res()
    res, rows = {}, []
    with Engine(dylib=DYLIB, resources=RES) as e:
        for s in BW:
            pub, tag, basis = PUBLISHED[s]
            b = ref[s]["by_density"]["1"]
            bw = make_bw_probe(s)
            r = dict(published=pub, published_tag=tag, basis=basis, paths={})
            for sub, mode in ((True, "sub"), (False, "single")):
                p = dict(engine_rms_at_1={f"{px:g}um": b[f"{mode}_{px:g}um"]["rms48"] for px in (4.0, 6.0, 12.0)})
                p["amount"] = {k: pub / v for k, v in p["engine_rms_at_1"].items()}
                k6 = p["amount"]["6um"]
                p["in_wire_range_6um"] = bool(LO <= k6 <= HI)
                sent = float(np.clip(round(k6, 2), LO, HI))
                d = density(e, bw, b["level"], N, PX, grain_sublayers_active=sub, grain_amount=sent)
                p["sent"] = sent
                p["rms48_rendered_at_sent"] = rms48(d, PX)
                p["mean_density_at_sent"] = float(d.mean())
                a0 = stripes(e, bw, b["level"], 0.0, sub)
                a1 = stripes(e, bw, b["level"], 1.0, sub)
                ak = stripes(e, bw, b["level"], sent, sub)
                G = {per: float(np.exp(-2 * np.pi ** 2 * BLUR ** 2 / per ** 2)) for per in a0}
                p["stripe_contrast_vs_grain_off"] = {
                    f"{per}px": dict(at_1=a1[per] / a0[per], at_sent=ak[per] / a0[per],
                                     predicted_at_1=G[per], predicted_at_sent=1 - sent * (1 - G[per])) for per in a0}
                r["paths"][mode] = p
                sc = p["stripe_contrast_vs_grain_off"]
                rows.append([s, pub, tag, "on" if sub else "off", f"{p['engine_rms_at_1']['6um']:.2f}", f"{k6:.2f}",
                             "yes" if p["in_wire_range_6um"] else "NO", f"{sent:.2f}", f"{p['rms48_rendered_at_sent']:.2f}",
                             f"{p['amount']['4um']:.2f}", f"{p['amount']['12um']:.2f}"] +
                            [f"{sc[f'{per}px'][q]:.3f}" for per in (2, 3, 4, 8) for q in ("at_1", "at_sent")])
                print(rows[-1], flush=True)
            res[s] = r
    json.dump(dict(pitch_um=PX, wire_range=[LO, HI], engine_build=ref[BW[0]]["engine_build"], stocks=res),
              open(HERE / "bw_grain_amount.json", "w"), indent=1)
    with open(HERE / "bw_grain_amount.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["stock", "published_rms", "published_tag", "sublayers", "engine_rms_at_1_6um", "amount_6um", "in_wire_range",
                    "amount_sent", "rms_rendered_at_sent", "amount_4um", "amount_12um"] +
                   [f"stripe{per}px_contrast_{q}" for per in (2, 3, 4, 8) for q in ("at_1", "at_sent")])
        w.writerows(rows)
