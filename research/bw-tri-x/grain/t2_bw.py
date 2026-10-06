"""MEASURED grain of a B&W stand-in (three identical channels) through the built engine.
A  single-layer path (grain_sublayers_active=false, a wire field) per channel + the 1/3-sum, Dmax 2.5/3.0/3.5
B  sub-layer path, equal three-way split
C  RMS vs net density (single layer, Dmax 3.0, G)
D  grain_amount scaling
E  pixel pitch (Selwyn) check
"""
import json
import numpy as np
from glib import *
import model as M
import standin

N = 1024
out = {}


def level_for(e, name, W, target, **extra):
    levels = np.geomspace(0.002, 3000, 40)
    dd = np.array([-np.log10(render_lin(e, name, l, 64, 100.0, grain_active=False, **extra)[..., 1].mean() / W) / PROBE_K
                   for l in levels])
    return float(np.exp(np.interp(target, dd, np.log(levels))))


def meas(e, name, W, lvl, px, **extra):
    d = density(e, name, lvl, N, px, W, **extra)
    return d, float(d.mean()), float(d.std()), 1000 * aperture_sigma(d, px)


with Engine(resources=RES) as e:
    for dmax in (2.5, 3.0, 3.5):
        base, prof = standin.build(dmax)
        pr = [make_probe(base, c, name=f"{base}_p{c}") for c in range(3)] + [make_probe(base, "sum", name=f"{base}_psum")]
        W = white_of(e, pr[0])
        for path, sub in (("single", False), ("sublayers", True)):
            lvl = level_for(e, pr[1], W, 1.0)
            fields = []
            row = {}
            for c in range(3):
                d, m, sp, ra = meas(e, pr[c], W, lvl, 6.0, grain_sublayers_active=sub)
                v = M.var_sublayers(prof, c, 1.0, 6.0) if sub else M.var_simple(dmax, c, 1.0, 6.0)
                gp, ga = M.kernel_gain(6.0)
                row["RGB"[c]] = dict(mean=m, sigma_px=sp, sigma_px_model=float(np.sqrt(v) * gp), rms48=ra,
                                     rms48_model=1000 * float(np.sqrt(v) * ga), rms48_selwyn=float(M.rms_from_var(v, 6.0)))
                fields.append(d.ravel() - d.mean())
            cc = np.corrcoef(np.stack(fields))
            row["corr_RG_RB_GB"] = [float(cc[0, 1]), float(cc[0, 2]), float(cc[1, 2])]
            d, m, sp, ra = meas(e, pr[3], W, lvl, 6.0, grain_sublayers_active=sub)
            row["sum3"] = dict(mean=m, sigma_px=sp, rms48=ra,
                               rms48_pred_independent=float(np.sqrt(sum(row[k]["rms48"] ** 2 for k in "RGB")) / 3),
                               rms48_pred_if_correlated=float(sum(row[k]["rms48"] for k in "RGB") / 3))
            out[f"A_{path}_dmax{dmax}"] = row
            print(path, dmax, json.dumps(row))
        if dmax == 3.0:
            # C: density dependence, single layer, G
            rows = []
            for t in (0.1, 0.2, 0.4, 0.7, 1.0, 1.3, 1.6, 2.0, 2.4, 2.8):
                lvl = level_for(e, pr[1], W, t)
                d, m, sp, ra = meas(e, pr[1], W, lvl, 6.0, grain_sublayers_active=False)
                d2, m2, sp2, ra2 = meas(e, pr[1], W, lvl, 6.0, grain_sublayers_active=True)
                gp, ga = M.kernel_gain(6.0)
                rows.append(dict(target=t, mean=m, rms48_single=ra, model_single=1000 * float(np.sqrt(M.var_simple(3.0, 1, t, 6.0)) * ga),
                                 skew_single=float((((d - m) / sp) ** 3).mean()),
                                 rms48_sub=ra2, model_sub=1000 * float(np.sqrt(M.var_sublayers(prof, 1, t, 6.0)) * ga)))
                print("C", json.dumps(rows[-1]))
            out["C_density"] = rows
            # D: grain_amount
            lvl = level_for(e, pr[1], W, 1.0)
            rows = []
            for k in (0.5, 0.8, 1.0, 1.5, 2.0):
                d, m, sp, ra = meas(e, pr[1], W, lvl, 6.0, grain_sublayers_active=False, grain_amount=k)
                rows.append(dict(amount=k, mean=m, sigma_px=sp, rms48=ra))
                print("D", json.dumps(rows[-1]))
            out["D_amount"] = rows
            # E: pixel pitch
            rows = []
            for px in (4.0, 6.0, 9.0, 12.0, 24.0):
                d, m, sp, ra = meas(e, pr[1], W, lvl, px, grain_sublayers_active=False)
                gp, ga = M.kernel_gain(px)
                v = M.var_simple(3.0, 1, 1.0, px)
                rows.append(dict(px_um=px, sigma_px=sp, rms48=ra, rms48_model=1000 * float(np.sqrt(v) * ga), rms48_selwyn=float(M.rms_from_var(v, px))))
                print("E", json.dumps(rows[-1]))
            out["E_pitch"] = rows
json.dump(out, open(HERE / "out_t2_bw.json", "w"), indent=1)
