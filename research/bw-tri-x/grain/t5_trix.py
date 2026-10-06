"""The other agent's kodak_tri_x_400.json (snapshot: trix_profile_snapshot.json; three identical channels,
neutral channel_density 1/3 each, net Dmax 2.52, sub-layer split 0.31/1.03/1.18).
Shipped engine: per-channel and 1/3-sum RMS on both grain paths, and RMS vs density.
Scratch engine: the constants that land the SUM (what the print sees) on 17."""
import os, json
import numpy as np
from glib import *
import model as M

STOCK = "kodak_tri_x_400"
prof = load(STOCK)
cur = np.array(prof["data"]["density_curves"], float)
DMAX = float(np.nanmax(cur[:, 1] - np.nanmin(cur[:, 1])))
pr = [make_probe(STOCK, c, name=f"trix_p{c}") for c in range(3)] + [make_probe(STOCK, "sum", name="trix_psum")]
W = white_of(); PX = 6.0
gp, ga = M.kernel_gain(PX)
out = {"dmax_net": DMAX}
ENVS = ["SPK_GRAIN_EQUAL_STREAMS", "SPK_GRAIN_AREA", "SPK_GRAIN_SCALE", "SPK_GRAIN_UNI", "SPK_GRAIN_BLUR", "SPK_GRAIN_DYE", "SPK_GRAIN_LAYERS"]
def env(**kw):
    for k in ENVS: os.environ.pop(k, None)
    for k, v in kw.items(): os.environ["SPK_GRAIN_" + k] = str(v)

def level_for(e, target):
    levels = np.geomspace(0.0005, 5000, 44)
    dd = np.array([-np.log10(render_lin(e, pr[1], l, 64, 100.0, grain_active=False)[..., 1].mean() / W) / PROBE_K for l in levels])
    return float(np.exp(np.interp(target, dd, np.log(levels))))

def model_sum(sub, t, area=M.AREA):
    v = [M.var_sublayers(prof, c, t, PX, area) if sub else M.var_simple(DMAX, c, t, PX, area) for c in range(3)]
    return 1000 * np.sqrt(sum(v)) / 3 * ga, float(M.rms_from_var(sum(v) / 9, PX))

env()
with Engine(resources=RES) as e:
    lvl = level_for(e, 1.0)
    for sub in (False, True):
        f = [density(e, pr[c], lvl, 1024, PX, W, grain_sublayers_active=sub) for c in range(3)]
        s = density(e, pr[3], lvl, 1024, PX, W, grain_sublayers_active=sub)
        cc = np.corrcoef(np.stack([a.ravel() for a in f]))
        m6, msel = model_sum(sub, 1.0)
        r = dict(mean=float(s.mean()), rms48_RGB=[1000 * aperture_sigma(a, PX) for a in f], corr=[float(cc[0, 1]), float(cc[0, 2]), float(cc[1, 2])],
                 rms48_sum=1000 * aperture_sigma(s, PX), rms48_sum_model_6um=float(m6), rms48_sum_selwyn=msel,
                 grain_amount_for_17_at_6um=17 / (1000 * aperture_sigma(s, PX)), grain_amount_for_17_selwyn=17 / msel)
        out["sublayers" if sub else "single"] = r
        print("sublayers" if sub else "single", json.dumps(r))
    rows = []
    for t in (0.1, 0.2, 0.4, 0.7, 1.0, 1.3, 1.6, 2.0, 2.3):
        l = level_for(e, t); row = dict(target=t)
        for sub in (False, True):
            s = density(e, pr[3], l, 1024, PX, W, grain_sublayers_active=sub)
            row["sub" if sub else "single"] = 1000 * aperture_sigma(s, PX); row["model_sub" if sub else "model_single"] = float(model_sum(sub, t)[0])
        rows.append(row); print("C", json.dumps(row))
    out["density"] = rows
    # wire-only fix: grain_amount
    for sub in (False, True):
        k = out["sublayers" if sub else "single"]["grain_amount_for_17_at_6um"]
        if k <= 2.0:
            s = density(e, pr[3], lvl, 1024, PX, W, grain_sublayers_active=sub, grain_amount=k)
            print("grain_amount %.3f (%s): rms48 %.2f" % (k, "sublayers" if sub else "single", 1000 * aperture_sigma(s, PX)))
            out[f"amount_check_{'sub' if sub else 'single'}"] = dict(amount=k, rms48=1000 * aperture_sigma(s, PX))

DY = HERE / "engine_scratch/build/libspektrafilm_engine.dylib"
with Engine(dylib=DY, resources=RES) as e:
    rows = []
    for label, sub, kw, corr in (("single, independent draws, default scales", False, {}, False),
                                 ("sublayers, independent draws, default scales/layers", True, {}, False),
                                 ("single, ONE emulsion (equal streams, scale 1, u .99)", False, dict(EQUAL_STREAMS=1, SCALE=1.0, UNI=0.99), True),
                                 ("sublayers, ONE emulsion (equal streams, scale 1, u .99)", True, dict(EQUAL_STREAMS=1, SCALE=1.0, UNI=0.99), True)):
        # area for 17: scale the model's prediction at area 1 (variance is linear in area)
        env(AREA=1.0, **kw)
        s = density(e, pr[3], lvl, 1024, 24.0, W, grain_sublayers_active=sub)   # coarse pitch keeps sigma small at area 1
        g24 = M.kernel_gain(24.0)[1]
        selwyn_at_area1 = 1000 * aperture_sigma(s, 24.0) / g24 * np.sqrt(24.0 ** 2 / A48)
        a_sel = (17 / selwyn_at_area1) ** 2
        a_6 = a_sel * (np.sqrt(36.0 / A48) / ga) ** 2
        env(AREA=a_6, **kw)
        s = density(e, pr[3], lvl, 1024, PX, W, grain_sublayers_active=sub)
        rows.append(dict(case=label, particle_area_um2_selwyn=float(a_sel), particle_area_um2_for_17_at_6um=float(a_6), measured_rms48_at_6um=1000 * aperture_sigma(s, PX)))
        print(json.dumps(rows[-1]))
    out["area_for_17"] = rows
env()
json.dump(out, open(HERE / "out_t5_trix.json", "w"), indent=1)
