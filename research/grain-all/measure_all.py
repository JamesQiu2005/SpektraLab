"""MEASURED RMS granularity (x1000 sigma_D, 48 um circular aperture) of every film stock, as the
built engine renders it at grain_amount 1, sub-layers on (product default) and off, at 4 / 6 / 12 um
pixel pitch -- per dye record at net density 1.0 in that record, and as VISUAL density on the neutral
patch whose net visual density is 1.0 (plus gross 1.0 for the positives). Analytic model alongside.

    python measure_all.py [stock ...]     -> engine_rms.json, engine_rms.csv, engine_rms_pitch.csv

Pitch: a flat n x n frame with film_format_mm = pitch * n / 1000 (the engine's pixel_size_um is
film_format_mm * 1000 / long edge). 6 um is 36 mm / 6000 px = 24 MP on a 135 frame.
"""
import csv, json, sys, time
import numpy as np
from galib import *

PITCHES = {6.0: 2048, 4.0: 2048, 12.0: 1024}        # pitch um -> frame edge px
LEVELS = np.geomspace(1e-4, 1e4, 49)
OUT = HERE / "engine_rms.json"


def crossing(levels, vals, target):
    """log-level bracket of the first place vals crosses target (None if it never does)."""
    s = np.sign(vals - target)
    for i in range(len(levels) - 1):
        if s[i] == 0:
            return levels[i], levels[i]
        if s[i] * s[i + 1] < 0:
            return levels[i], levels[i + 1]
    return None


def solve(f, bracket, target, iters=14):
    lo, hi = np.log(bracket[0]), np.log(bracket[1])
    flo = f(np.exp(lo)) - target
    for _ in range(iters):
        mid = 0.5 * (lo + hi)
        fm = f(np.exp(mid)) - target
        if fm * flo > 0:
            lo, flo = mid, fm
        else:
            hi = mid
    return float(np.exp(0.5 * (lo + hi)))


def measure(e, stock):
    prof = load(stock)
    probes = make_probes(stock)
    vis = Visual(prof)
    positive = prof["info"]["type"] == "positive"
    curves = np.array([[mean_density(e, p, l) for l in LEVELS] for p in probes])      # (3, L)
    row = dict(stock=stock, type=prof["info"]["type"], channel_model=prof["info"].get("channel_model", "color"),
               dmax_net=[float(c.max()) for c in curves], visual_dmin=vis.dv_min,
               visual_weight_lost_to_nan=vis.lost_weight, channels={}, visual={})

    def triple(level):
        return np.array([mean_density(e, p, level) for p in probes])

    # ---- per dye record, net density 1.0 in that record
    for c in range(3):
        br = crossing(LEVELS, curves[c], 1.0)
        if br is None:
            row["channels"]["RGB"[c]] = dict(error="net density 1.0 not reached")
            continue
        lvl = solve(lambda l: mean_density(e, probes[c], l), br, 1.0)
        d0 = mean_density(e, probes[c], lvl)
        r = dict(level=lvl, d_grain_off=d0)
        for px, n in PITCHES.items():
            for sub in (True, False):
                d = density(e, probes[c], lvl, n, px, grain_sublayers_active=sub)
                m, sel = model_channel(prof, c, d0, px, sub)
                r[f"{'sub' if sub else 'single'}_{px:g}um"] = dict(
                    rms48=1000 * aperture_sigma(d, px), model=float(m), d_mean=float(d.mean()),
                    sigma_px=float(d.std()))
                r[f"{'sub' if sub else 'single'}_selwyn_noblur"] = float(sel)
        row["channels"]["RGB"[c]] = r

    # ---- visual density on the engine's neutral (R=G=B input) patch
    dv_curve = np.array([vis.dv(curves[:, i]) for i in range(len(LEVELS))])
    targets = [("net_1.0", 1.0 + vis.dv_min)] + ([("gross_1.0", 1.0)] if positive else [])
    for name, tgt in targets:
        br = crossing(LEVELS, dv_curve, tgt)
        if br is None:
            row["visual"][name] = dict(error="visual density not reached", dv_max=float(dv_curve.max()))
            continue
        lvl = solve(lambda l: float(vis.dv(triple(l))), br, tgt)
        d3 = triple(lvl)
        g = vis.gradient(d3)
        r = dict(level=lvl, d_rgb=d3.tolist(), dv_gross=float(vis.dv(d3)), dv_net=float(vis.dv(d3) - vis.dv_min),
                 weights_dDv_dd=g.tolist())
        for px, n in PITCHES.items():
            for sub in (True, False):
                f = np.stack([density(e, p, lvl, n, px, grain_sublayers_active=sub) for p in probes], axis=-1)
                T = vis.transmittance(f)
                dv_ap = -np.log10(aperture_mean(T, px))          # the microdensitometer: flux, then log
                mc = np.array([model_channel(prof, c, d3[c], px, sub)[0] for c in range(3)])
                cc = np.corrcoef(f.reshape(-1, 3).T)
                r[f"{'sub' if sub else 'single'}_{px:g}um"] = dict(
                    rms48=1000 * float(dv_ap.std()), model=float(np.sqrt(((g * mc) ** 2).sum())),
                    dv_mean_net=float(dv_ap.mean() - vis.dv_min),
                    rms48_rgb_at_this_patch=[1000 * aperture_sigma(f[..., c], px) for c in range(3)],
                    corr_rg_rb_gb=[float(cc[0, 1]), float(cc[0, 2]), float(cc[1, 2])])
        row["visual"][name] = r
    return row


def write_csv(res):
    def cell(r, *keys):
        for k in keys:
            if not isinstance(r, dict) or k not in r:
                return ""
            r = r[k]
        return f"{r:.3f}" if isinstance(r, float) else r
    for path, pitches in ((HERE / "engine_rms.csv", [6.0]), (HERE / "engine_rms_pitch.csv", [4.0, 6.0, 12.0])):
        with open(path, "w", newline="") as fh:
            w = csv.writer(fh)
            head = ["stock", "type", "pitch_um"]
            for mode in ("sub", "single"):
                for q in ("R", "G", "B", "visual_net1", "visual_gross1"):
                    head += [f"{q}_{mode}", f"{q}_{mode}_model"]
            w.writerow(head)
            for s, r in res.items():
                for px in pitches:
                    line = [s, r["type"], f"{px:g}"]
                    for mode in ("sub", "single"):
                        k = f"{mode}_{px:g}um"
                        for c in "RGB":
                            line += [cell(r, "channels", c, k, "rms48"), cell(r, "channels", c, k, "model")]
                        for v in ("net_1.0", "gross_1.0"):
                            line += [cell(r, "visual", v, k, "rms48"), cell(r, "visual", v, k, "model")]
                    w.writerow(line)


if __name__ == "__main__":
    stocks = build_res()
    want = sys.argv[1:] or stocks
    res = json.load(open(OUT)) if OUT.exists() and sys.argv[1:] else {}
    with Engine(dylib=DYLIB, resources=RES) as e:
        build = e.build_info
        for s in want:
            t = time.time()
            res[s] = measure(e, s)
            res[s]["engine_build"] = build
            ch = res[s]["channels"]
            print(s, "sub6", [round(ch[c].get("sub_6um", {}).get("rms48", float("nan")), 2) for c in "RGB"],
                  "vis", {k: round(v.get("sub_6um", {}).get("rms48", float("nan")), 2) for k, v in res[s]["visual"].items()},
                  f"{time.time() - t:.0f}s", flush=True)
            json.dump(res, open(OUT, "w"), indent=1)
    write_csv(res)
