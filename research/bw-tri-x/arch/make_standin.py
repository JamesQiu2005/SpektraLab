"""Stand-in B&W profiles for ARCHITECTURE tests only (not film data: ASSUMED shapes derived from
kodak_portra_400 so the engine's code paths can be exercised). Writes into res/profiles/."""
import json, math, sys, copy
from pathlib import Path
S = Path(__file__).parent
src = json.load(open(S/"res/profiles/kodak_portra_400.json"))
wl = src["data"]["wavelengths"]
def nan(v): return v is None or (isinstance(v,float) and math.isnan(v))
def make(stock, variant="split", cut=None, legacy_window=False):
    p = copy.deepcopy(src)
    p["info"].update(stock=stock, name=stock, channel_model="bw")
    d = p["data"]
    # panchromatic stand-in: mean of the three linear sensitivities, same in all 3 columns
    pan = []
    for row in d["log_sensitivity"]:
        v = [10**x for x in row if not nan(x)]
        pan.append(sum(v)/3 if v else 0.0)
    if cut:  # design (a): a filter baked in. cut=(lo_nm or None, hi_nm or None, width)
        lo, hi, w = cut
        T = []
        for l in wl:
            t = 1.0
            if lo: t *= 0.5*(1+math.erf((l-lo)/(w*math.sqrt(2))))
            if hi: t *= 0.5*(1-math.erf((l-hi)/(w*math.sqrt(2))))
            T.append(t)
        # renormalise on an equal-energy white so grey keeps its exposure (the filter factor given)
        k = sum(pan)/sum(a*t for a,t in zip(pan,T))
        pan = [a*t*k for a,t in zip(pan,T)]
    d["log_sensitivity"] = [[math.log10(max(a,1e-12))]*3 for a in pan]
    if not legacy_window:
        d.pop("hanatos2025_adaptation_window_params", None)
        d.pop("hanatos2025_adaptation_surface_params", None)
    g = [row[1] for row in d["density_curves"]]
    d["density_curves"] = [[x,x,x] for x in g]
    d["density_curves_layers"] = [[[lay[1]]*3 for lay in k] for k in d["density_curves_layers"]]
    if variant == "split":      # neutral silver, a third in each column
        d["channel_density"] = [[1/3,1/3,1/3] for _ in wl]
    elif variant == "onecol":   # all the silver in column 1; 0 and 2 carry nothing
        d["channel_density"] = [[0.0,1.0,0.0] for _ in wl]
    d["base_density"] = [0.25 for _ in wl]
    d["midscale_neutral_density"] = [1.0 for _ in wl]
    json.dump(p, open(S/f"res/profiles/{stock}.json","w"))
make("bwx_split"); make("bwx_onecol", "onecol")
make("bwx_split_y", cut=(495,None,8)); make("bwx_split_r", cut=(600,None,8))
make("bwx_split_g", cut=(500,590,12)); make("bwx_split_b", cut=(None,490,12))
print("ok")
