"""Build STAND-IN profiles into res/profiles (scratch copy of engine/resources). Nothing here is film data.

Film stand-ins  standin_bw_n00 / n03 / n06 : Portra 400 with
  - three identical channels (green curve x1.12 -> slope ~0.56; panchromatic sum sensitivity),
  - channel_density = silver(lambda)/3 per channel, silver = (550/lambda)^n  (n = 0, 0.3, 0.6; ASSUMED),
  - base_density = 0.25 flat grey + 0.05*silver (base+fog 0.30 for 135 is SHEET; the split is ASSUMED).
Paper stand-ins standin_vc_paper / standin_vc_paper_warm : a variable-contrast silver paper written
  as three emulsions in the three channels (equal blue speed, green speed 0 / -0.6 / -1.2 log),
  each forming neutral silver. Anchors: Ilford MG RC sheet (sensitivity ends ~550 nm, Dmax ~2.1,
  ISO R 180..40). Shapes are ASSUMED, not digitised.
"""
import json, copy, numpy as np
from scipy.special import erf
from common import RES
P = RES / "profiles"
wl = np.arange(380, 781, 5.0)
ncdf = lambda z: 0.5 * (1 + erf(z / np.sqrt(2)))

def silver(n): return (550.0 / wl) ** n

src = json.load(open(P / "kodak_portra_400.json"))
for tag, n in (("n00", 0.0), ("n03", 0.3), ("n06", 0.6)):
    p = copy.deepcopy(src); d = p["data"]; i = p["info"]
    i.update(stock=f"standin_bw_{tag}", name=f"STAND-IN B&W neg (silver slope {n})", channel_model="bw",
             target_print="kodak_portra_endura")
    p["metadata"]["datasource"] = "STAND-IN built by scratchpad/print/build_profiles.py; not measured data"
    ls = np.array(d["log_sensitivity"], float)
    pan = np.log10(np.nansum(10 ** ls, axis=1))
    d["log_sensitivity"] = [[v, v, v] for v in pan]
    s = silver(n)
    d["channel_density"] = [[v / 3] * 3 for v in s]
    d["base_density"] = list(0.25 + 0.05 * s)
    dc = np.array(d["density_curves"], float)[:, 1] * 1.12
    d["density_curves"] = [[v, v, v] for v in dc]
    L = np.array(d["density_curves_layers"], float)[:, :, 1] * 1.12
    d["density_curves_layers"] = [[[v, v, v] for v in row] for row in L]
    m = d["density_curves_model"]
    for k, f in (("centers", 1), ("amplitudes", 1.12), ("sigmas", 1)):
        row = [x * f for x in m[k][1]]; m[k] = [row, row, row]
    le = np.array(d["log_exposure"]); dmid = float(np.interp(0.0, le, dc))
    d["midscale_neutral_density"] = list(np.array(d["base_density"]) + dmid * s)
    json.dump(p, open(P / f"standin_bw_{tag}.json", "w"))
    print(tag, "net density at logE=0:", round(dmid, 3), "max", round(dc.max(), 3))

# ---- VC paper stand-in --------------------------------------------------
src = json.load(open(P / "kodak_portra_endura.json"))
edge = lambda c, w: 0.5 * (1 + erf((wl - c) / w))
blue = edge(370, 12) * (1 - edge(492, 14))
green = 1.4 * edge(496, 14) * (1 - edge(546, 5))
OFF = (0.0, -0.6, -1.2)
DMAX, SIG, CEN = 2.10, 0.135, 0.06
for name, slope, base_tint in (("standin_vc_paper", 0.0, 0.0), ("standin_vc_paper_warm", 0.5, 0.03)):
    p = copy.deepcopy(src); d = p["data"]; i = p["info"]
    i.update(stock=name, name="STAND-IN variable-contrast silver paper", channel_model="bw")
    p["metadata"]["datasource"] = "STAND-IN built by scratchpad/print/build_profiles.py; not measured data"
    sens = np.stack([blue + 10 ** o * green for o in OFF], 1)
    d["log_sensitivity"] = np.log10(np.maximum(sens, 1e-8)).tolist()
    sv = silver(slope)                      # image tone: warm = more blue density
    d["channel_density"] = [[v, v, v] for v in sv]
    d["base_density"] = list(0.06 + base_tint * (550.0 / wl) ** 2)   # base tint (warm = cream)
    le = np.array(d["log_exposure"])
    one = (DMAX / 3) * ncdf((le - CEN) / SIG)
    d["density_curves"] = [[v, v, v] for v in one]
    d["density_curves_layers"] = [[[v / 3] * 3] * 3 for v in one]
    d["density_curves_model"] = dict(model_type="cdfs", centers=[[CEN] * 3] * 3,
                                     amplitudes=[[DMAX / 9] * 3] * 3, sigmas=[[SIG] * 3] * 3)
    d.pop("edr_tone_map", None)
    d["midscale_neutral_density"] = list(np.array(d["base_density"]) + 0.7 * sv)
    json.dump(p, open(P / f"{name}.json", "w"))
    print(name, "written")
