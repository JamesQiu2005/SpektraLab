"""Sheet MTF (F-4017 p7, vector path) + the engine's analytic MTF + fits. No engine needed."""
import re, json, numpy as np, os
from scipy.optimize import least_squares
HERE = os.path.dirname(os.path.abspath(__file__))
def sheet_mtf():
    s = open(HERE + "/p7.svg").read(); body = s[s.index("</defs>"):]
    for p in re.findall(r"<path ([^>]*)>", body):
        tr = re.search(r'transform="matrix\(([^)]*)\)"', p)
        if tr and "112.856" in tr.group(1) and "93.498" in tr.group(1):
            m = [float(x) for x in tr.group(1).split(",")]
            nums = [float(x) for x in re.findall(r"-?\d+\.?\d*(?:e-?\d+)?", re.search(r' d="([^"]*)"', " " + p).group(1))]
            pts = np.array([(m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]) for x, y in zip(nums[0::2], nums[1::2])])
            break
    # axes from the page's own gridlines (page pt): x 1,2,3,4,5,10,20,50,100,200,600 c/mm ; y 100,70,50,30,20,10,7,5 %
    gx = np.array([84.8, 106.5, 119.15, 128.5, 135.12, 156.52, 179.12, 208.04, 229.74, 251.13, 287.29]); fx = np.array([1, 2, 3, 4, 5, 10, 20, 50, 100, 200, 600.0])
    gy = np.array([95.2, 105.73, 115.36, 130.1, 141.83, 161.99, 172.22, 182.45]); fy = np.array([100, 70, 50, 30, 20, 10, 7, 5.0])
    f = 10 ** np.interp(pts[:, 0], gx, np.log10(fx))
    sl, ic = np.polyfit(gy, np.log10(fy), 1)           # one straight log axis through all 8 gridlines
    r = 10 ** (sl * pts[:, 1] + ic)
    return f, r / 100.0
EXP3 = [(0.1633, 0.5360), (0.6496, 1.5236), (0.1870, 2.7684)]   # engine/src/core/numeric.cpp exponential_gaussian_fit(3)
G = lambda f, sig_um: np.exp(-2 * np.pi ** 2 * (sig_um * 1e-3) ** 2 * f ** 2)      # f in c/mm
def expo(f, lam): return sum(a * G(f, r * lam) for a, r in EXP3)
def scatter(f, core, tail, w): return (1 - w) * G(f, core) + w * expo(f, tail)
def halation(f, s, sigma=65.0, n=3, decay=0.5):
    d = np.array([decay ** k for k in range(n)]); d /= d.sum()
    return 1 / (1 + s) + s / (1 + s) * sum(d[k] * G(f, sigma * np.sqrt(k + 1)) for k in range(n))
def dir_mtf(f, k, size=20.0, tail=200.0, tw=0.06):
    """small-signal: D = f0(logE - m*blur(D)), f0 pre-compensated so flat fields are unchanged; k = m*gamma_local"""
    B = (1 - tw) * G(f, size) + tw * expo(f, tail)
    return (1 - k * B) / (1 - k)
if __name__ == "__main__":
    f, r = sheet_mtf()
    print("SHEET MTF (digitised from the p7 vector path, 13 vertices):")
    for a, b in zip(f, r): print(f"  {a:7.2f} c/mm  {100*b:6.1f} %")
    np.savetxt(HERE + "/sheet_mtf.csv", np.c_[f, r], header="cycles_per_mm,response", delimiter=",")
    ff = np.array([5, 10, 20, 30, 50, 80, 100.0])
    print("\nengine default scatter MTF per channel (analytic), halation preset 'strong' included:")
    for c, (core, tail, w, s) in enumerate(zip([2.2, 2.0, 1.6], [9.3, 9.7, 9.1], [0.78, 0.65, 0.67], [0.015, 0.005, 0.0])):
        print("  " + "RGB"[c], " ".join(f"{x:5.0f}:{100*y:5.1f}%" for x, y in zip(ff, scatter(ff, core, tail, w) * halation(ff, s))))
    print("  sheet", " ".join(f"{x:5.0f}:{100*np.interp(np.log(x), np.log(f), r):5.1f}%" for x in ff if x <= f.max()))
    def rms(model): return float(np.sqrt(np.mean((model - r) ** 2)))
    def rmslog(model): return float(np.sqrt(np.mean((np.log10(model) - np.log10(r)) ** 2)))
    out = {"sheet": {"f": f.tolist(), "r": r.tolist()}}
    dflt = scatter(f, 2.0, 9.7, 0.65)
    print(f"\ndefault G scatter vs sheet: rms {100*rms(dflt):.1f} % pts")
    out["default_G_rms"] = rms(dflt)
    # (a) scatter only (cannot exceed 100 %)
    ra = least_squares(lambda p: scatter(f, *p) - r, [2.0, 5.0, 0.3], bounds=([0, 0.1, 0], [10, 50, 1]))
    print("fit A scatter only  core %.2f um  tail %.2f um  w %.3f   rms %.1f %%pts  max|err| %.1f" % (*ra.x, 100 * rms(scatter(f, *ra.x)), 100 * np.abs(scatter(f, *ra.x) - r).max()))
    out["A"] = dict(core=ra.x[0], tail=ra.x[1], w=ra.x[2], rms=rms(scatter(f, *ra.x)))
    # (a2) single Gaussian (w = 0)
    r2 = least_squares(lambda p: G(f, p[0]) - r, [3.0])
    print("fit A2 one Gaussian core %.2f um  rms %.1f %%pts" % (r2.x[0], 100 * rms(G(f, r2.x[0]))))
    out["A2"] = dict(core=r2.x[0], rms=rms(G(f, r2.x[0])))
    # (b) scatter x DIR edge term with the engine's fixed 20 um / 200 um diffusion, free k
    mb = lambda p: scatter(f, p[0], p[1], p[2]) * dir_mtf(f, p[3])
    rb = least_squares(lambda p: mb(p) - r, [3.0, 5.0, 0.2, 0.15], bounds=([0, 0.1, 0, 0], [10, 50, 1, 0.9]))
    print("fit B scatter x DIR(20um fixed)  core %.2f  tail %.2f  w %.3f  k %.3f   rms %.1f %%pts max|err| %.1f" % (*rb.x, 100 * rms(mb(rb.x)), 100 * np.abs(mb(rb.x) - r).max()))
    out["B"] = dict(core=rb.x[0], tail=rb.x[1], w=rb.x[2], k=rb.x[3], rms=rms(mb(rb.x)))
    # (b2) one Gaussian x DIR(20 um)
    mb2 = lambda p: G(f, p[0]) * dir_mtf(f, p[1])
    rb2 = least_squares(lambda p: mb2(p) - r, [3.0, 0.15], bounds=([0, 0], [10, 0.9]))
    print("fit B2 one Gaussian x DIR(20um)  core %.2f  k %.3f  rms %.1f %%pts max|err| %.1f" % (*rb2.x, 100 * rms(mb2(rb2.x)), 100 * np.abs(mb2(rb2.x) - r).max()))
    out["B2"] = dict(core=rb2.x[0], k=rb2.x[1], rms=rms(mb2(rb2.x)))
    # (c) free diffusion size too (would need an engine field)
    mc = lambda p: G(f, p[0]) * dir_mtf(f, p[1], size=p[2], tw=0.0)
    rc = least_squares(lambda p: mc(p) - r, [3.0, 0.15, 30.0], bounds=([0, 0, 2], [10, 0.9, 300]))
    print("fit C one Gaussian x DIR(free size, no tail)  core %.2f  k %.3f  size %.1f um  rms %.1f %%pts max|err| %.1f" % (*rc.x, 100 * rms(mc(rc.x)), 100 * np.abs(mc(rc.x) - r).max()))
    out["C"] = dict(core=rc.x[0], k=rc.x[1], size=rc.x[2], rms=rms(mc(rc.x)))
    json.dump(out, open(HERE + "/mtf_fit.json", "w"), indent=1)
    try:
        import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
        x = np.logspace(0, 2.3, 300); plt.figure(figsize=(7, 4.5))
        plt.loglog(f, 100 * r, "ko-", label="F-4017 p7 (SHEET, vector)")
        for c, (core, tail, w) in enumerate(zip([2.2, 2.0, 1.6], [9.3, 9.7, 9.1], [0.78, 0.65, 0.67])): plt.loglog(x, 100 * scatter(x, core, tail, w), color="rgb"[c], ls=":", label=f"engine default scatter {'RGB'[c]}")
        plt.loglog(x, 100 * scatter(x, *ra.x), "C1", label="fit A scatter only")
        plt.loglog(x, 100 * G(x, rb2.x[0]) * dir_mtf(x, rb2.x[1]), "C2", label="fit B2 Gaussian x DIR(20 um)")
        plt.loglog(x, 100 * G(x, rc.x[0]) * dir_mtf(x, rc.x[1], size=rc.x[2], tw=0), "C4--", label="fit C (free diffusion size)")
        plt.ylim(3, 200); plt.xlim(1, 200); plt.grid(True, which="both", alpha=.3); plt.xlabel("cycles/mm"); plt.ylabel("response %"); plt.legend(fontsize=7); plt.tight_layout(); plt.savefig(HERE + "/mtf_fit.png", dpi=130)
    except Exception as ex: print("no plot:", ex)
