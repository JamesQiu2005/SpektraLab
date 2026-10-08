"""How much of each film's rendered RMS rests on the ASSUMED ceiling of its curve?

The grain node takes Dmax from the profile curve's maximum, and every B&W profile's curve above the
sheet's last point is an ASSUMED straight line bent into an ASSUMED ceiling (gross D 3.2 T-Max, 3.0
the others) by  sh = -soft * logaddexp(-line/soft, -dmax/soft),  soft 0.25  (build_profiles.py).
This rebuilds each profile with the ceiling moved by -0.4 / 0 / +0.4 D and re-measures on the engine.

  * the line is recovered from the shipped curve itself (inverting sh where it is well conditioned),
    so nothing here needs the digitised sheet CSVs; the "0" variant must reproduce the shipped curve
    and layers (errors are printed and stored) -- that is the check that the rebuild is the builder's.
  * the three-CDF layer split is refitted exactly as the builder does it (the split is ASSUMED too,
    and it moves with the ceiling: the sub-layer result carries both).
  * the patch is net D 1.0, inside every sheet's own range, so the picture's density does not move.

    python dmax_sensitivity.py     -> dmax_sensitivity.json, dmax_sensitivity.csv
Variant profiles are written to the scratch resources folder only.
"""
import csv, json, re
import numpy as np
from scipy.special import ndtr
from scipy.optimize import least_squares
from galib import *
from measure_bw import solve_level, rms48, model_bw

SOFT, PX, N = 0.25, 6.0, 2048
SHIFTS = [-0.4, 0.0, 0.4]


def rebuild(prof, shift):
    D = prof["data"]
    LE = np.array(D["log_exposure"], float)
    dc = np.array(D["density_curves"], float)[:, 0]
    tag = prof["metadata"]["tags"]["density_curves"]
    le_last = float(re.search(r"log_exposure (-?[\d.]+)\.\.(-?[\d.]+)", tag).group(2))
    gross = float(re.search(r"ceiling of gross D ([\d.]+)", tag).group(1))
    dmin = float(D["base_density"][0])
    dmax = gross - dmin
    sh = lambda lin, dm: -SOFT * np.logaddexp(-lin / SOFT, -dm / SOFT)
    k = (LE > le_last + 0.02) & (dc < dmax - 0.2)
    lin_k = -SOFT * np.log(np.exp(-dc[k] / SOFT) - np.exp(-dmax / SOFT))
    g, c = np.polyfit(LE[k], lin_k, 1)
    line_resid = float(np.abs(g * LE[k] + c - lin_k).max())
    lin = g * LE + c
    blend = np.clip((LE - (le_last - 0.3)) / 0.3, 0, 1)
    # inside the blend zone the builder has (1-blend)*sheet + blend*sh: swap the sh term only
    new = np.where(LE <= le_last, dc + blend * (sh(lin, dmax + shift) - sh(lin, dmax)), sh(lin, dmax + shift))
    new = np.maximum(new, 0.0)
    model = lambda p, le: np.stack([p[3 + i] * ndtr((le - p[i]) / p[6 + i]) for i in range(3)], 1)
    fit = least_squares(lambda p: model(p, LE).sum(1) - new, [-0.8, 0.6, 2.2, 0.7, 0.9, 1.0, 0.5, 0.6, 0.6],
                        bounds=([-3, -3, -3, 0, 0, 0, .15, .15, .15], [5, 5, 5, 4, 4, 4, 2, 2, 2]))
    p = fit.x; o = np.argsort(p[:3]); p = np.r_[p[:3][o], p[3:6][o], p[6:][o]]
    lay = model(p, LE); lay = lay * (new / np.maximum(lay.sum(1), 1e-12))[:, None]
    old_lay = np.array(D["density_curves_layers"], float)[:, :, 0]
    info = dict(le_last=le_last, gross_ceiling=gross + shift, end_slope=float(g), line_resid=line_resid,
                curve_err_vs_shipped=float(np.abs(new - dc).max()), layers_err_vs_shipped=float(np.abs(lay - old_lay).max()),
                curve_max_net=float(new.max()), layer_max=lay.max(0).tolist())
    q = json.loads(json.dumps(prof))
    q["data"]["density_curves"] = np.repeat(new[:, None], 3, 1).tolist()
    q["data"]["density_curves_layers"] = np.repeat(lay[:, :, None], 3, 2).tolist()
    return q, info


if __name__ == "__main__":
    build_res()
    out, rows = {}, []
    with Engine(dylib=DYLIB, resources=RES) as e:
        for s in BW:
            out[s] = {}
            base = json.load(open(PRODUCT / f"{s}.json"))
            for sh_ in SHIFTS:
                q, info = rebuild(base, sh_)
                name = f"var_{s}_{'m' if sh_ < 0 else 'p'}{abs(sh_):g}".replace(".", "")
                q["info"]["stock"] = name
                json.dump(q, open(RES / "profiles" / f"{name}.json", "w"))
                bw = make_bw_probe(name)
                lvl = solve_level(lambda l: mean_density(e, bw, l), 1.0)
                d0 = mean_density(e, bw, lvl)
                for sub in (True, False):
                    d = density(e, bw, lvl, N, PX, grain_sublayers_active=sub)
                    info[f"rms48_{'sub' if sub else 'single'}"] = rms48(d, PX)
                    info[f"model_{'sub' if sub else 'single'}"] = model_bw(q, d0, PX, sub)[0]
                out[s][f"{sh_:+g}"] = info
                print(s, f"{sh_:+g}", {k: (round(v, 4) if isinstance(v, float) else v) for k, v in info.items()}, flush=True)
            for sh_ in SHIFTS:
                i, z = out[s][f"{sh_:+g}"], out[s]["+0"]
                rows.append([s, f"{i['gross_ceiling']:.1f}", f"{i['curve_max_net']:.3f}",
                             f"{i['rms48_sub']:.3f}", f"{i['rms48_sub'] / z['rms48_sub'] - 1:+.3f}",
                             f"{i['rms48_single']:.3f}", f"{i['rms48_single'] / z['rms48_single'] - 1:+.3f}",
                             f"{i['curve_err_vs_shipped']:.5f}", f"{i['layers_err_vs_shipped']:.5f}"])
    json.dump(out, open(HERE / "dmax_sensitivity.json", "w"), indent=1)
    with open(HERE / "dmax_sensitivity.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["stock", "gross_ceiling_ASSUMED", "curve_max_net", "rms48_sublayers_on", "rel_change_on",
                    "rms48_sublayers_off", "rel_change_off", "curve_err_vs_shipped", "layers_err_vs_shipped"])
        w.writerows(rows)
