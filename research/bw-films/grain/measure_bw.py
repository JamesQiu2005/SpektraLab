"""MEASURED RMS granularity (1000 x sigma_D, 48 um circular aperture) of the four black-and-white
product profiles as the engine renders them at grain_amount 1, sub-layers on (the product default) and
off, at 4 / 6 / 12 um pixel pitch, on the patch whose net density is 1.0 -- plus the density
dependence at 6 um. The analytic model (galib.model_channel) alongside.

    python measure_bw.py [stock ...]      -> engine_rms_bw.json, engine_rms_bw.csv

Two read-outs of the same thing, as a cross-check:
  * "bw"      the neutral probe (galib.make_bw_probe): one render is the negative's density field,
              mean of the three records. This is the number a densitometer would read.
  * "records" the three one-record probes of research/grain-all, combined with weights 1/3 each;
              also gives one record's RMS and the correlation between the records.
The aperture reading is flux-then-log (the microdensitometer averages transmittance).
Pitch: a flat n x n frame with film_format_mm = pitch * n / 1000; 6 um is 24 MP on a 135 frame.
"""
import csv, json, sys, time
import numpy as np
from galib import *

PITCHES = {6.0: 2048, 4.0: 2048, 12.0: 1024}
LEVELS = np.geomspace(1e-4, 1e4, 49)
DENSITIES = [0.3, 0.6, 1.0, 1.5, 2.0]              # net; 1.0 is the sheets' point
OUT = HERE / "engine_rms_bw.json"


def solve_level(f, target):
    vals = np.array([f(l) for l in LEVELS])
    i = int(np.argmax(vals >= target))
    if vals[i] < target:
        return None
    lo, hi = np.log(LEVELS[i - 1]), np.log(LEVELS[i])
    for _ in range(18):
        mid = 0.5 * (lo + hi)
        if f(np.exp(mid)) < target:
            lo = mid
        else:
            hi = mid
    return float(np.exp(0.5 * (lo + hi)))


def rms48(d, px):
    """flux-then-log through the 48 um disc; d is a net density field."""
    return 1000 * float((-np.log10(aperture_mean(10.0 ** -d, px))).std())


def model_bw(prof, d_net, px, sub, amount=1.0):
    """three independent records, 1/3 each"""
    mc = np.array([model_channel(prof, c, d_net, px, sub, amount)[0] for c in range(3)])
    return float(np.sqrt(((mc / 3) ** 2).sum())), mc.tolist()


def measure(e, stock):
    prof = load(stock)
    probes, bw = make_probes(stock), make_bw_probe(stock)
    cur = np.array(prof["data"]["density_curves"], float)[:, 0]
    le = np.array(prof["data"]["log_exposure"], float)
    row = dict(stock=stock, dmax_net=float(cur.max()), base_density=float(prof["data"]["base_density"][0]),
               d_net_at_midgrey=mean_density(e, bw, 0.184), by_density={})
    for dn in DENSITIES:
        lvl = solve_level(lambda l: mean_density(e, bw, l), dn)
        d0 = mean_density(e, bw, lvl)
        r = dict(level=lvl, stops_from_midgrey=float(np.log2(lvl / 0.184)), d_grain_off=d0)
        for px, n in (PITCHES.items() if dn == 1.0 else [(6.0, 2048)]):
            for sub in (True, False):
                d = density(e, bw, lvl, n, px, grain_sublayers_active=sub)
                m, mc = model_bw(prof, d0, px, sub)
                q = dict(rms48=rms48(d, px), rms48_log_then_mean=1000 * aperture_sigma(d, px), model=m,
                         model_one_record=mc[1], d_mean=float(d.mean()), sigma_px=1000 * float(d.std()))
                if dn == 1.0 and px == 6.0:
                    f = np.stack([density(e, p, lvl, n, px, grain_sublayers_active=sub) for p in probes], -1)
                    cc = np.corrcoef(f.reshape(-1, 3).T)
                    q.update(records_rms48=[1000 * aperture_sigma(f[..., c], px) for c in range(3)],
                             records_combined_rms48=rms48(f.mean(-1), px),
                             corr_rg_rb_gb=[float(cc[0, 1]), float(cc[0, 2]), float(cc[1, 2])])
                r[f"{'sub' if sub else 'single'}_{px:g}um"] = q
        row["by_density"][f"{dn:g}"] = r
    return row


def write_csv(res):
    with open(HERE / "engine_rms_bw.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["stock", "net_density", "pitch_um", "sublayers", "rms48_measured", "rms48_model",
                    "one_record_model", "sigma_per_pixel_x1000", "mean_density_with_grain", "density_grain_off"])
        for s, r in res.items():
            for dn, b in r["by_density"].items():
                for k, q in b.items():
                    if not isinstance(q, dict):
                        continue
                    mode, px = k.split("_")
                    w.writerow([s, dn, px[:-2], "on" if mode == "sub" else "off", f"{q['rms48']:.3f}",
                                f"{q['model']:.3f}", f"{q['model_one_record']:.3f}", f"{q['sigma_px']:.2f}",
                                f"{q['d_mean']:.4f}", f"{b['d_grain_off']:.4f}"])


if __name__ == "__main__":
    build_res()
    want = sys.argv[1:] or BW
    res = json.load(open(OUT)) if OUT.exists() and sys.argv[1:] else {}
    with Engine(dylib=DYLIB, resources=RES) as e:
        for s in want:
            t = time.time()
            res[s] = measure(e, s)
            res[s]["engine_build"] = e.build_info
            b = res[s]["by_density"]["1"]
            print(s, {k: (round(v["rms48"], 2), round(v["model"], 2)) for k, v in b.items() if isinstance(v, dict)},
                  f"{time.time() - t:.0f}s", flush=True)
            json.dump(res, open(OUT, "w"), indent=1)
    write_csv(res)
