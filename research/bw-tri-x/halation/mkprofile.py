"""Stand-in neutral profiles (NOT Tri-X data). Copies kodak_portra_400 and makes the three channels identical.
 standin_bw_dyes   : identical sensitivity+curves, original C/M/Y dye spectra (worst case: channel differences show as colour)
 standin_bw_silver : same, but each channel's spectral density is flat 1/3 (three identical neutral 'dyes'), flat base 0.25
"""
import json, sys, numpy as np, copy
res = sys.argv[1]
src = json.load(open(f"{res}/profiles/kodak_portra_400.json"))
def mk(name, silver):
    p = copy.deepcopy(src); d = p["data"]
    p["info"]["stock"] = name; p["info"]["name"] = name + " (STAND-IN, not film data)"
    p["info"]["channel_model"] = "bw"
    ls = np.array(d["log_sensitivity"], float)
    pan = np.log10(np.nansum(10.0 ** ls, axis=1))
    d["log_sensitivity"] = np.repeat(pan[:, None], 3, 1).tolist()
    dc = np.array(d["density_curves"], float); d["density_curves"] = np.repeat(dc[:, 1:2], 3, 1).tolist()
    dl = np.array(d["density_curves_layers"], float)   # (K, layers, 3)?
    print(name, "layers shape", dl.shape)
    dl[:] = dl[..., 1:2] if dl.shape[-1] == 3 else dl[:, 1:2, :]
    d["density_curves_layers"] = dl.tolist()
    if silver:
        n = len(d["wavelengths"])
        d["channel_density"] = (np.ones((n, 3)) / 3.0).tolist()
        d["base_density"] = [0.25] * n
        if "midscale_neutral_density" in d: d["midscale_neutral_density"] = [1.0] * n
    json.dump(p, open(f"{res}/profiles/{name}.json", "w"))
mk("standin_bw_dyes", False); mk("standin_bw_silver", True)
print({k: (v if not isinstance(v, list) else '...') for k, v in src["data"]["density_curves_model"].items()} if isinstance(src["data"]["density_curves_model"], dict) else '')
