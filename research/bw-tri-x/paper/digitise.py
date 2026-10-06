"""Digitise the Ilford MULTIGRADE RC sheet (Jun 2019). The three charts are embedded JPEGs
(pdfimages: 483x303, 483x296, 423x247 px), NOT vector paths, so this is a raster trace:
row-wise dark runs with sub-pixel edges, grid lines removed by width, curves followed by continuity.
Where curves overlap (the common toe / crossover of the speed-matched family) only the envelope
is recoverable: the softest and hardest curve take the two edges, the others are spread evenly
between them. That region is flagged in the CSV (column `merged`).

Writes csv/char_curves_raw.csv, csv/char_curves_grid.csv, csv/spectral_sensitivity.csv,
csv/axis_residuals.csv, csv/sheet_metrics.csv, out/digitise_check.png
"""
import os, numpy as np
from PIL import Image
H = os.path.dirname(os.path.abspath(__file__))
os.makedirs(H + '/csv', exist_ok=True); os.makedirs(H + '/out', exist_ok=True)

def dark(path):
    return (255.0 - np.asarray(Image.open(path).convert('L')).astype(float)) / 255.0

def line_pos(d, axis, lo, hi, minlen):
    """sub-pixel centroid of full-length grid lines along an axis"""
    prof = (d > 0.5).sum(axis)
    idx = [i for i in range(lo, hi) if prof[i] > minlen]
    groups = []
    for i in idx:
        if groups and i - groups[-1][-1] <= 1: groups[-1].append(i)
        else: groups.append([i])
    w = d.sum(axis)
    out = []
    for g in groups:
        g = np.arange(g[0] - 1, g[-1] + 2)
        ww = w[g] - np.median(w)
        ww = np.clip(ww, 0, None)
        out.append(float((g * ww).sum() / ww.sum()))
    return out

resid = []
def axis_fit(name, pos, val):
    pos = np.array(pos); val = np.array(val, float)
    A = np.c_[pos, np.ones_like(pos)]
    (m, c), *_ = np.linalg.lstsq(A, val, rcond=None)
    r = A @ [m, c] - val
    resid.append((name, len(pos), m, np.abs(r).max(), np.sqrt((r ** 2).mean())))
    return lambda p: m * np.asarray(p, float) + c

def runs(row, thr=0.5, minw=2.3):
    """dark runs in a row: (left, right) sub-pixel edges at the threshold; narrow runs (grid, leaders) dropped"""
    out = []; n = len(row); i = 0
    while i < n:
        if row[i] > thr:
            j = i
            while j + 1 < n and row[j + 1] > thr: j += 1
            l = i - (row[i] - thr) / (row[i] - row[i - 1]) if i > 0 and row[i] != row[i - 1] else i - 0.5
            r = j + (row[j] - thr) / (row[j] - row[j + 1]) if j + 1 < n and row[j] != row[j + 1] else j + 0.5
            if r - l >= minw: out.append((l, r))
            i = j + 1
        else: i += 1
    return out

def trace(d, names_hi, rows, gridrows, xlim, lw=2.6, maxw=14, skip=(), gridcols=(), gridpos=0.0):
    """names_hi: curve names left->right ABOVE the crossover. Returns dict name -> (rows, x, merged)."""
    k = len(names_hi)
    R = {}
    for r in rows:
        if any(abs(r - g) <= 1 for g in gridrows) or r in skip: continue
        rr = [q for q in runs(d[r]) if xlim[0] < q[0] and q[1] < xlim[1]]
        if rr: R[r] = rr
    # start: the highest row (largest density) with k separate runs, track down then up
    start = [r for r in sorted(R) if len(R[r]) == k and all(q[1] - q[0] < 6 for q in R[r])]
    r0 = start[len(start) // 2]
    # crossover = the row below r0 where the total extent is smallest
    below = [r for r in sorted(R) if r > r0]
    ext = {r: R[r][-1][1] - R[r][0][0] for r in below if len(R[r]) == 1}
    rc = min(ext, key=ext.get); rc_all = [r for r in ext if ext[r] <= ext[rc] + 0.3]
    rc = int(np.median(rc_all))
    res = {n: {} for n in names_hi}; mer = {n: {} for n in names_hi}
    def place(r, pred):
        rr = R[r]; order = names_hi if r <= rc else names_hi[::-1]
        asg = {}
        for n in order:
            p = pred[n]
            j = int(np.argmin([0 if q[0] - 1 <= p <= q[1] + 1 else min(abs(p - q[0]), abs(p - q[1])) for q in rr]))
            asg.setdefault(j, []).append(n)
        # enforce order: run index must be non-decreasing along `order`
        last = 0
        js = {}
        for n in order:
            j = [jj for jj, v in asg.items() if n in v][0]; j = max(j, last); js[n] = j; last = j
        for j in set(js.values()):
            ns = [n for n in order if js[n] == j]; l, rg = rr[j]
            if len(ns) == 1: xs = [(l + rg) / 2]
            else:
                a, b = l + lw / 2, rg - lw / 2
                if b < a: a = b = (l + rg) / 2
                xs = np.linspace(a, b, len(ns))
            for n, x in zip(ns, xs):
                res[n][r] = float(x); mer[n][r] = len(ns) > 1
    pred = {n: (q[0] + q[1]) / 2 for n, q in zip(names_hi, R[r0])}
    for seq in ([r for r in sorted(R) if r >= r0], [r for r in sorted(R, reverse=True) if r < r0]):
        p = dict(pred); prev = {}
        for r in seq:
            if max(q[1] - q[0] for q in R[r]) > maxw: break   # the Dmax plateau (going up) / the flat toe (going down)
            place(r, p)
            for n in names_hi:
                p[n] = res[n][r]
    # the flat toe: rows no longer separate it. Column scan: top edge of the dark band + half a line width
    # is the centre of the uppermost (softest) curve; the same shape is joined to every curve (flag 2).
    soft = names_hi[-1]; rlast = max(res[soft]); xlast = res[soft][rlast]
    toe = []
    for c in range(int(xlim[0]) + 1, int(xlast)):
        if any(abs(c - g) <= 1 for g in gridcols): continue
        col = d[rlast - 12:gridrows[-1] + 1, c]
        if col.max() < 0.5: continue
        i = int(np.argmax(col > 0.5)); top = i - (col[i] - 0.5) / (col[i] - col[i - 1]) if i > 0 else i
        toe.append((c + 0.0, min(top + rlast - 12 + lw / 2, gridpos)))
    toe = np.array(toe)
    out = {}
    for n in names_hi:
        rs = np.array(sorted(res[n])); xs = np.array([res[n][r] for r in rs]); ms = np.array([mer[n][r] for r in rs]).astype(int)
        if len(toe):
            # join: shift the toe horizontally so it meets this curve's last tracked point
            o = np.argsort(toe[:, 1]); xj = np.interp(rs[-1], toe[o, 1], toe[o, 0])
            keep = toe[:, 1] > rs[-1] + 0.3
            t = toe[keep]
            rs = np.r_[rs, t[:, 1]]; xs = np.r_[xs, t[:, 0] + (xs[-1] - xj)]; ms = np.r_[ms, np.full(len(t), 2)]
        out[n] = (rs, xs, ms)
    return out, rc

def plateau(d, xlim, gridrows, rows):
    """row centroid of the horizontal Dmax line: densest non-grid row in the range"""
    best = None
    for r in rows:
        if any(abs(r - g) <= 2 for g in gridrows): continue
        s = d[r, xlim[0]:xlim[1]].sum()
        if best is None or s > best[1]: best = (r, s)
    r = best[0]; rr = np.arange(r - 3, r + 4)
    cols = [c for c in range(xlim[0], xlim[1]) if d[r, c] > 0.5]
    c0, c1 = cols[len(cols) // 2], cols[-8]
    w = d[rr, c0:c1].sum(1)
    return float((rr * w).sum() / w.sum())

G = np.round(np.arange(0.9, 4.2001, 0.02), 2)
allc = {}; rawrows = []; info = {}
for img, names, tag, leader in (('img-003.jpg', ['3', '2', '1', '0', '00'], 'left', None), ('img-004.jpg', ['5', '4'], 'right', 1.64)):
    d = dark(H + '/pdf/' + img)
    gx = line_pos(d, 0, 0, d.shape[1], 180); gy = line_pos(d, 1, 0, d.shape[0], 300)
    assert len(gx) == 10 and len(gy) == 6, (gx, gy)
    fx = axis_fit(f'char {tag} x (rel log E)', gx, np.arange(0, 4.51, 0.5))
    fy = axis_fit(f'char {tag} y (D)', gy, [2.5, 2.0, 1.5, 1.0, 0.5, 0.0])
    gr = [int(round(v)) for v in gy]
    pr = plateau(d, (int(gx[5]), int(gx[9]) - 20), gr, range(int(gy[0]) + 4, int(gy[1]) - 4))
    dmax = float(fy(pr))
    # the right chart's '5 --- 4' leader is a horizontal rule across both curves: those rows are skipped
    skip = [r for r in range(d.shape[0]) if leader and abs(fy(r) - leader) < 0.035]
    tr, rc = trace(d, names, range(int(pr) + 3, gr[-1] - 1), gr, (gx[1] + 2, gx[9] - 2), skip=skip,
                   gridcols=[int(round(v)) for v in gx], gridpos=gy[-1])
    info[tag] = dict(dmax=dmax, crossover_D=float(fy(rc)), plateau_row=pr)
    print(tag, 'Dmax (plateau line centroid) %.3f  crossover at D %.2f' % (dmax, fy(rc)))
    for n in names:
        r, x, m = tr[n]; le = fx(x); D = fy(r)
        for a, b, c in zip(le, D, m): rawrows.append(f'{n},{a:.4f},{b:.4f},{int(c)}')
        # monotone in D: interpolate logE(D) then invert onto a logE grid, with Dmin=0 and the plateau as ends
        o = np.argsort(D); Ds, Ls = D[o], le[o]
        Ls = np.maximum.accumulate(Ls)                      # x must not decrease with D
        Ls = Ls + np.arange(len(Ls)) * 1e-7
        Dg = np.interp(G, np.r_[Ls[0] - 0.6, Ls, Ls[-1] + 0.12], np.r_[0.0, Ds, dmax], left=0.0, right=dmax)
        allc[n] = Dg
order = ['00', '0', '1', '2', '3', '4', '5']
open(H + '/csv/char_curves_raw.csv', 'w').write('filter,rel_log_exposure,density_over_base,overlap_flag(0=own trace;1=shares a blob with other curves, positions spread evenly;2=flat toe from the top edge of the band, shared shape)\n' + '\n'.join(rawrows) + '\n')
np.savetxt(H + '/csv/char_curves_grid.csv', np.c_[G, *[allc[n] for n in order]], delimiter=',', fmt='%.4f',
           header='rel_log_exposure,' + ','.join('D_filter_' + n for n in order), comments='')

# ---- sheet metrics from the digitised curves (ISO 6846: 0.04 over base to 90 % of Dmax) ----
def iso(Dg, dmax):
    lo = np.interp(0.04, Dg, G); hi = np.interp(0.9 * dmax, Dg, G); sp = np.interp(0.6, Dg, G)
    return lo, hi, sp
SHEET_R = dict(zip(order, [180, 160, 130, 110, 90, 60, 40])); SHEET_P = dict(zip(order, [200] * 5 + [100] * 2))
rows = ['filter,ISO_R_sheet_table,ISO_R_from_digitised_curve,logE_at_D0.04,logE_at_0.9Dmax,logE_at_D0.6,ISO_P_sheet_table,rel_speed_from_curve_vs_filter2_log']
ref = None; met = {}
for n in order:
    dm = info['left' if n not in '45' else 'right']['dmax']
    lo, hi, sp = iso(allc[n], dm); met[n] = (lo, hi, sp)
sp2 = met['2'][2]
for n in order:
    lo, hi, sp = met[n]
    rows.append(f'{n},{SHEET_R[n]},{100 * (hi - lo):.0f},{lo:.3f},{hi:.3f},{sp:.3f},{SHEET_P[n]},{sp2 - sp:+.3f}')
    print('filter %2s  R table %3d  R digitised %3.0f   logE(D=0.6) %.3f' % (n, SHEET_R[n], 100 * (hi - lo), sp))
open(H + '/csv/sheet_metrics.csv', 'w').write('\n'.join(rows) + '\n')

# ---- spectral sensitivity: one curve, x ticks only; the y axis has NO scale on the sheet ----
d = dark(H + '/pdf/img-002.jpg')
# tick labels 400..650 sit under the frame; the frame has no tick marks, so the axis is fitted to the
# label glyph centres (measured below) -- coarser than a grid: residual reported.
bot = line_pos(d, 1, 100, d.shape[0], 300)[-1]; top = line_pos(d, 1, 0, 100, 300)[0]
lab = d[int(bot) + 8:int(bot) + 30]
cols = np.where(lab.max(0) > 0.5)[0]
grp = np.split(cols, np.where(np.diff(cols) > 6)[0] + 1)
cent = [0.5 * (g[0] + g[-1]) for g in grp]
assert len(cent) == 6, cent
fx = axis_fit('spectral x (nm), from label centres', cent, np.arange(400, 651, 50))
xs = []; ys = []
for c in range(12, d.shape[1] - 12):
    col = d[int(top) + 3:int(bot) - 1, c]
    if col.max() < 0.5: continue
    rr = np.arange(len(col)) + int(top) + 3; w = np.clip(col - 0.2, 0, None)
    # the curve is steep at both ends: take the centroid of the dark run
    xs.append(c); ys.append((rr * w).sum() / w.sum())
xs = np.array(xs); ys = np.array(ys)
h = (bot - ys) / (bot - top)                               # 0..1 of the box height, unit unknown
wl = fx(xs)
np.savetxt(H + '/csv/spectral_sensitivity_raw.csv', np.c_[wl, h], delimiter=',', fmt='%.3f',
           header='wavelength_nm,height_fraction_of_box (the sheet gives no y scale or unit)', comments='')
g5 = np.arange(380, 781, 5.0)
h5 = np.interp(g5, wl, h, left=0, right=0)
np.savetxt(H + '/csv/spectral_sensitivity_5nm.csv', np.c_[g5, h5], delimiter=',', fmt='%.4f',
           header='wavelength_nm,height_fraction_of_box', comments='')
print('spectral: %.0f..%.0f nm, peak %.0f nm, blue plateau %.2f, peak %.2f of box' % (wl.min(), wl.max(), wl[h.argmax()], h5[(g5 >= 410) & (g5 <= 430)].mean(), h.max()))
with open(H + '/csv/axis_residuals.csv', 'w') as f:
    f.write('axis,n_ticks,units_per_px,max_abs_residual,rms_residual\n')
    for r in resid:
        f.write('%s,%d,%.6f,%.5f,%.5f\n' % r); print('AXIS %-38s n=%d %.5f/px max|res| %.4f rms %.4f' % r)

# ---- overlay check ----
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
fig, ax = plt.subplots(1, 3, figsize=(17, 5))
raw = np.genfromtxt(H + '/csv/char_curves_raw.csv', delimiter=',', skip_header=1, dtype=str)
for a, names in ((ax[0], ['00', '0', '1', '2', '3']), (ax[1], ['4', '5'])):
    for n in names:
        a.plot(G, allc[n], lw=1, label=n); s = raw[raw[:, 0] == n]
        a.plot(s[:, 1].astype(float), s[:, 2].astype(float), '.', ms=1.5, color='k')
    a.set_xlim(1, 4.3); a.grid(alpha=.3); a.legend(); a.set_xlabel('relative log exposure'); a.set_ylabel('density')
ax[2].plot(wl, h); ax[2].set_xlabel('nm'); ax[2].set_title('spectral sensitivity, box-height fraction (no scale on sheet)')
fig.savefig(H + '/out/digitise_check.png', dpi=110, bbox_inches='tight')
