"""Fit the three-emulsion model to the sheet's seven characteristic curves (csv/char_curves_grid.csv).
Global unknowns: emulsion amplitudes A_i, a 3-cdf shape per emulsion, green speeds g_2, g_3.
Per grade: one pack number t_k (yellow-only below 0, magenta-only above) and the exposure origin X0_k.
Writes out/fit.json (consumed by build_profile.py)."""
import json, sys, numpy as np
from scipy.optimize import least_squares
import mg
X, SH = mg.sheet_curves()
sel = (X >= 1.3) & (X <= 4.1)
Xs = X[sel]
NG = len(mg.GRADES)
SHARED_SHAPE = '--free-shapes' not in sys.argv
# optional emphasis on the hardest filter (its curve is the sum at near-zero stagger and sets every emulsion's width)
WEIGHT = {'5': 2.5, '4': 1.5} if '--weight-hard' in sys.argv else {}
TAG = ('' if SHARED_SHAPE else '_free') + ('_hard' if WEIGHT else '')

def unpack(p):
    i = 0
    a = np.exp(p[i:i + 3]); A = mg.DMAX * a / a.sum(); i += 3
    ns = 1 if SHARED_SHAPE else 3
    cen = []; sig = []; w = []
    for _ in range(ns):
        c0 = p[i]; d1, d2 = np.exp(p[i + 1:i + 3]); cen.append([c0, c0 + d1, c0 + d1 + d2]); i += 3
        sig.append(list(0.05 + np.exp(p[i:i + 3]))); i += 3
        ww = np.exp(np.r_[0.0, p[i:i + 2]]); w.append(list(ww / ww.sum())); i += 2
    if ns == 1: cen, sig, w = cen * 3, sig * 3, w * 3
    g = np.r_[1.0, 10 ** -np.exp(p[i]), 10 ** -(np.exp(p[i]) + np.exp(p[i + 1]))]; i += 2
    t = p[i:i + NG]; i += NG
    x0 = p[i:i + NG]; i += NG
    edge = 485 + 22 * np.tanh(p[i]); width = 13 + 7 * np.tanh(p[i + 1])
    return A, cen, sig, w, g, t, x0, (edge, width)

def model(p):
    A, cen, sig, w, g, t, x0, ew = unpack(p)
    S = mg.sensitivities(g, *ew); out = {}
    for k, gr in enumerate(mg.GRADES):
        dx, _ = mg.channel_logx(S, mg.pack(t[k]))
        out[gr] = mg.paper_density(Xs - x0[k], dx, A, cen, sig, w)
    return out

def resid(p):
    m = model(p); r = []
    for k, gr in enumerate(mg.GRADES):
        d = (m[gr] - SH[gr][sel]) * WEIGHT.get(gr, 1.0)
        r.append(d)
        # the sheet's TABLE value of ISO R is a harder number than the raster toe: a soft pull toward it
        r.append([0.004 * (mg.iso_range(Xs, np.maximum.accumulate(m[gr]), mg.DMAX) - mg.SHEET_R[gr])])
    t = unpack(p)[5]
    r.append(1e-3 * np.clip(np.abs(t) - 199, 0, None) * 100)       # the wire range is 0..200
    return np.concatenate([np.ravel(v) for v in r])

rng = np.random.default_rng(1)
best = None
for trial in range(int(sys.argv[-1]) if sys.argv[-1].isdigit() else 16):
    ns = 1 if SHARED_SHAPE else 3
    p0 = list(rng.normal(0, 0.3, 3))
    for _ in range(ns):
        p0 += [rng.normal(-0.15, 0.1), np.log(0.15), np.log(0.15)] + list(np.log([0.08, 0.1, 0.1]) + rng.normal(0, .3, 3)) + list(rng.normal(0, .3, 2))
    p0 += [np.log(rng.uniform(0.3, 0.9)), np.log(rng.uniform(0.3, 0.9))]
    p0 += list(np.array([-170, -90, -40, 0, 40, 110, 190.0]) + rng.normal(0, 10, NG))
    p0 += [2.45] * NG
    p0 += [rng.normal(0, .5), rng.normal(0, .5)]
    try: s = least_squares(resid, p0, x_scale='jac', max_nfev=600)
    except Exception as ex: print('trial', trial, 'failed', ex); continue
    if best is None or s.cost < best.cost: best = s
    print('trial %2d cost %.4f  best %.4f' % (trial, s.cost, best.cost), flush=True)
A, cen, sig, w, g, t, x0, ew = unpack(best.x)
print('blue edge %.1f nm width %.1f nm' % ew)
m = model(best.x)
print('A', np.round(A, 3), 'g', np.round(g, 4), 'log g', np.round(np.log10(g), 3))
for i in range(3): print(' emulsion', i, 'centres', np.round(cen[i], 3), 'sigmas', np.round(sig[i], 3), 'weights', np.round(w[i], 3))
S = mg.sensitivities(g, *ew); rows = []
for k, gr in enumerate(mg.GRADES):
    dx, _ = mg.channel_logx(S, mg.pack(t[k]))
    rms = float(np.sqrt(np.mean((m[gr] - SH[gr][sel]) ** 2)))
    R = float(mg.iso_range(Xs, np.maximum.accumulate(m[gr]), mg.DMAX)); Rd = float(mg.iso_range(X, np.maximum.accumulate(SH[gr]), mg.DMAX))
    print('grade %2s  t %+7.1f  x0 %.3f  stagger %s  rms D %.3f  R model %5.1f  (table %d, digitised %.0f)' % (gr, t[k], x0[k], np.round(dx, 3), rms, R, mg.SHEET_R[gr], Rd))
    rows.append(dict(grade=gr, t=float(t[k]), x0=float(x0[k]), dx=dx.tolist(), rms=rms, R_model=R))
json.dump(dict(A=A.tolist(), centers=[list(map(float, c)) for c in cen], sigmas=[list(map(float, s)) for s in sig],
               weights=[list(map(float, v)) for v in w], g=g.tolist(), edge=float(ew[0]), width=float(ew[1]), grades=rows, shared_shape=SHARED_SHAPE, cost=float(best.cost)),
          open(mg.H + '/out/fit%s.json' % TAG, 'w'), indent=1)
