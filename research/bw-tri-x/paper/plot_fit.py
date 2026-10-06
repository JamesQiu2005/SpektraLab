"""Overlay: sheet curves (digitised) vs the fitted model (python replica). -> out/fit_<tag>.png"""
import json, sys, numpy as np, mg
import matplotlib; matplotlib.use('Agg'); import matplotlib.pyplot as plt
tag = sys.argv[1] if len(sys.argv) > 1 else '_free'
f = json.load(open(mg.H + '/out/fit%s.json' % tag)); X, SH = mg.sheet_curves()
S = mg.sensitivities(f['g'], f['edge'], f['width'])
fig, ax = plt.subplots(1, 3, figsize=(18, 5))
for k, r in enumerate(f['grades']):
    dx, _ = mg.channel_logx(S, mg.pack(r['t']))
    D = mg.paper_density(X - r['x0'], dx, f['A'], f['centers'], f['sigmas'], f['weights'])
    a = ax[0] if r['grade'] not in '45' else ax[1]
    a.plot(X, SH[r['grade']], 'k', lw=2.5, alpha=.35); a.plot(X, D, lw=1.2, label='filter %s  rms %.3f' % (r['grade'], r['rms']))
for a in ax[:2]: a.legend(); a.grid(alpha=.3); a.set_xlim(1.2, 4.2); a.set_xlabel('relative log exposure (sheet axis)'); a.set_ylabel('D over base')
x = np.linspace(-1.5, 1.5, 400)
for i in range(3): ax[2].plot(x, f['A'][i] * mg.shape(x, f['centers'][i], f['sigmas'][i], f['weights'][i]), label='emulsion %d, log g %.2f' % (i, np.log10(f['g'][i])))
ax[2].legend(); ax[2].grid(alpha=.3); ax[2].set_title('fitted emulsion curves (engine log-exposure axis)')
fig.savefig(mg.H + '/out/fit%s.png' % tag, dpi=100, bbox_inches='tight')
