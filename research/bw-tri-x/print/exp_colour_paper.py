"""(a) B&W stand-in negative printed on existing colour papers: cast and crossover on a grey ramp.
MEASURED through the shipping dylib, full tier, grain/halation/glare off, auto exposure off."""
import json, sys, numpy as np
from scipy.optimize import minimize
import common as c
eng = c.engine()
img = c.ramp()
MID = list(c.STOPS).index(0.0)

def run(film, paper, extra=None):
    d = dict(film_stock=film, print_stock=paper); d.update(extra or {})
    rgba, params = c.render(eng, img, d)
    L = c.lab(c.srgb_decode(c.patches(rgba)))
    return L, params, rgba

def solve(film, paper):
    """Hand-solve M/Y so the mid-grey patch has a*=b*=0 (the print's own definition of neutral here)."""
    def cost(x):
        L, _, _ = run(film, paper, dict(m_filter_neutral=float(np.clip(x[0], 0, 200)), y_filter_neutral=float(np.clip(x[1], 0, 200))))
        return L[MID, 1] ** 2 + L[MID, 2] ** 2
    r = minimize(cost, [65, 55], method="Nelder-Mead", options=dict(xatol=0.05, fatol=1e-4, maxiter=120))
    return float(r.x[0]), float(r.x[1]), r.fun

def show(tag, L):
    print(f"  {tag}")
    print("   stop  " + " ".join(f"{s:6.0f}" for s in c.STOPS))
    for n, k in (("L*", 0), ("a*", 1), ("b*", 2)):
        print(f"   {n:4s}  " + " ".join(f"{v:6.1f}" for v in L[:, k]))
    use = (L[:, 0] > 8) & (L[:, 0] < 92)
    cab = np.hypot(L[use, 1], L[use, 2])
    return dict(max_C=float(cab.max()), a_range=float(np.ptp(L[use, 1])), b_range=float(np.ptp(L[use, 2])),
                a_mid=float(L[MID, 1]), b_mid=float(L[MID, 2]), L=L.tolist())

res = {}
papers = ["kodak_portra_endura", "fujifilm_crystal_archive_typeii", "kodak_2393"]
print("== reference: Portra 400 on Portra Endura, database filters")
L, p, rgba = run("kodak_portra_400", "kodak_portra_endura")
res["ref_portra400"] = dict(show("ref", L), m=p["m_filter_neutral"], y=p["y_filter_neutral"])
for film in ("standin_bw_n00", "standin_bw_n03", "standin_bw_n06"):
    for paper in papers if film == "standin_bw_n03" else papers[:1]:
        print(f"== {film} on {paper}")
        L, p, rgba = run(film, paper)
        r = show(f"fallback filters C{p['c_filter_neutral']:.0f} M{p['m_filter_neutral']:.1f} Y{p['y_filter_neutral']:.1f}", L)
        res[f"{film}|{paper}|fallback"] = dict(r, m=p["m_filter_neutral"], y=p["y_filter_neutral"])
        if film == "standin_bw_n03" and paper == papers[0]: c.save_png(rgba, c.OUT / "ramp_bw_on_endura_fallback.png")
        m, y, f = solve(film, paper)
        L, p, rgba = run(film, paper, dict(m_filter_neutral=m, y_filter_neutral=y))
        r = show(f"hand-solved M{m:.1f} Y{y:.1f} (residual {f:.2g})", L)
        res[f"{film}|{paper}|solved"] = dict(r, m=m, y=y)
        if film == "standin_bw_n03" and paper == papers[0]: c.save_png(rgba, c.OUT / "ramp_bw_on_endura_solved.png")
json.dump(res, open(c.OUT / "colour_paper.json", "w"), indent=1)
print("\nsummary (patches with 8<L*<92): max C*ab, a* range, b* range")
for k, v in res.items(): print(f"  {k:60s} M{v['m']:6.1f} Y{v['y']:6.1f}  maxC {v['max_C']:5.2f}  da {v['a_range']:5.2f}  db {v['b_range']:5.2f}")
