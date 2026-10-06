"""MEASURED: the paper's characteristic curve per filter, from engine renders of a grey ramp through Tri-X.
Three print exposures (table x 1/8, x1, x8; capped to the wire's 0.05..20) are stitched on
x = -(film density - film density at mid-grey) + log10(exposure multiple).
Compared with the sheet's digitised curve on the sheet's own axis (offset from the fit, no free shift),
and again with the best horizontal shift. Writes csv/rendered_curves.csv, csv/grade_report.csv, out/rendered_vs_sheet.png"""
import json, numpy as np, common as c, mg
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
X, SH = mg.sheet_curves(); T = c.grade_table()
stops = np.arange(-10, 10.001, 0.125)
Df = c.film_density(stops); dDf = Df - c.film_density([0.0])[0]
rep = []; allrows = []
fig, ax = plt.subplots(1, 2, figsize=(14, 5.5))
with c.engine() as eng:
    for g in mg.GRADES:
        row = T['grades'][g]; segs = []; chroma = 0.0
        for mult in (0.125, 1.0, 8.0):
            d = c.grade_delta(g); pe = float(np.clip(d['print_exposure'] * mult, 0.05, 20.0)); d['print_exposure'] = pe
            D, L, p = c.ramp_density(eng, stops, dict(film_stock=c.FILM, print_stock=c.PAPER, **d))
            assert abs(p['m_filter_neutral'] - row['M']) < 1e-6 and abs(p['y_filter_neutral'] - row['Y']) < 1e-6
            segs.append((-dDf + np.log10(pe / row['print_exposure']), c.true_density(D), D)); chroma = max(chroma, float(np.hypot(L[:, 1], L[:, 2]).max()))
        dmin = min(s[1].min() for s in segs); dmax = max(s[1].max() for s in segs)
        # stitch consistency: where two segments overlap in x they must give the same density
        xa, da, _ = segs[1]; o = np.argsort(xa); incons = 0.0
        for xb, db, _ in (segs[0], segs[2]):
            m = (xb > xa.min()) & (xb < xa.max()) & (np.abs(np.gradient(db, xb)) > 0.05)
            if m.any(): incons = max(incons, float(np.abs(np.interp(xb[m], xa[o], da[o]) - db[m]).max()))
        x = np.concatenate([s[0] for s in segs]); D = np.concatenate([s[1] for s in segs]) - dmin
        o = np.argsort(x); x, D = x[o], D[o]
        xg = np.arange(-2.2, 2.2001, 0.02); Dg = np.maximum.accumulate(np.interp(xg, x, D))
        net = dmax - dmin
        R = mg.iso_range(xg, Dg + np.arange(len(xg)) * 1e-9, net)
        Xs = xg + row['sheet_axis_offset']                       # on the sheet's axis
        sel = (X >= 1.3) & (X <= 4.1)
        fixed = float(np.sqrt(np.mean((np.interp(X[sel], Xs, Dg) - SH[g][sel]) ** 2)))
        shifts = np.arange(-0.15, 0.1501, 0.005)
        fr = [float(np.sqrt(np.mean((np.interp(X[sel], Xs + s, Dg) - SH[g][sel]) ** 2))) for s in shifts]
        Rsheet = mg.iso_range(X, np.maximum.accumulate(SH[g]) + np.arange(len(X)) * 1e-9, mg.DMAX)
        sp = float(np.interp(0.6, Dg, Xs)); sps = float(np.interp(0.6, SH[g], X))
        gam = float(np.max(np.gradient(Dg, xg)))
        rep.append(dict(filter=g, M=row['M'], Y=row['Y'], print_exposure=row['print_exposure'], R_rendered=R, R_sheet_table=mg.SHEET_R[g],
                        R_sheet_curve=Rsheet, rms_fixed=fixed, rms_best_shift=min(fr), best_shift=float(shifts[int(np.argmin(fr))]),
                        dmin_true=dmin, dmax_true=dmax, dmax_over_base=net, speed_X_rendered=sp, speed_X_sheet=sps,
                        peak_gradient=gam, max_chroma=chroma, stitch_inconsistency=incons))
        r = rep[-1]
        print('filter %2s M%5.1f Y%5.1f pe %.3f | R %5.1f (table %d, sheet curve %.0f) | rms %.3f (best shift %.3f @ %+.3f) | Dmin %.3f Dmax %.3f | D0.6 at X %.3f (sheet %.3f) | C* %.3f | stitch %.4f'
              % (g, r['M'], r['Y'], r['print_exposure'], R, mg.SHEET_R[g], Rsheet, fixed, min(fr), r['best_shift'], dmin, dmax, sp, sps, chroma, incons))
        a = ax[0] if g not in '45' else ax[1]
        a.plot(X, SH[g], color='k', lw=3, alpha=.3); a.plot(Xs, Dg, lw=1.2, label='filter %s: R %.0f (sheet %d), rms %.3f' % (g, R, mg.SHEET_R[g], fixed))
        for xi, di in zip(xg, Dg): allrows.append('%s,%.3f,%.3f,%.4f' % (g, xi, xi + row['sheet_axis_offset'], di))
for a in ax: a.legend(fontsize=8); a.grid(alpha=.3); a.set_xlim(1.2, 4.2); a.set_xlabel('relative log exposure (sheet axis)'); a.set_ylabel('print density over base')
ax[0].set_title('grey = Ilford sheet (digitised raster); colour = ENGINE RENDER, Tri-X ramp -> ilford_multigrade_iv_rc')
fig.savefig(c.OUT / 'rendered_vs_sheet.png', dpi=110, bbox_inches='tight')
open(c.HERE / 'csv/rendered_curves.csv', 'w').write('filter,log_exposure_rel_to_table_midgrey,sheet_axis_X,print_density_over_base\n' + '\n'.join(allrows) + '\n')
keys = list(rep[0].keys())
open(c.HERE / 'csv/grade_report.csv', 'w').write(','.join(keys) + '\n' + '\n'.join(','.join(('%.4f' % r[k]) if isinstance(r[k], float) else str(r[k]) for k in keys) for r in rep) + '\n')
