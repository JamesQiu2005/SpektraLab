"""The engine's output stage compresses lightness near white (CAM16-UCS gamut compression, not on the wire),
so -log10(Y) of a rendered patch is NOT the print's reflection density above Y ~ 0.5.
MEASURE the map: unexposed scratch papers whose flat base density is known -> displayed density.
Writes csv/output_lightness_map.csv (true_density, displayed_density)."""
import json, os, numpy as np, common as c
p = json.load(open(c.RES / 'profiles' / (c.PAPER + '.json')))
rows = []
for b in np.r_[np.arange(0, 0.6, 0.03), np.arange(0.6, 2.81, 0.2)]:
    q = json.loads(json.dumps(p)); q['data']['base_density'] = [float(b)] * 81; q['info']['stock'] = 'tmp_base'
    json.dump(q, open(c.RES / 'profiles/tmp_base.json', 'w'))
    with c.engine() as eng:
        D, L, _ = c.ramp_density(eng, [8, 9, 10], dict(film_stock=c.FILM, print_stock='tmp_base', m_filter_neutral=0.0, y_filter_neutral=68.0, print_exposure=0.05))
    rows.append((b, D.mean(), np.hypot(L[:, 1], L[:, 2]).max())); print('true %.2f displayed %.4f  C* %.3f' % rows[-1])
os.remove(c.RES / 'profiles/tmp_base.json')
np.savetxt(c.HERE / 'csv/output_lightness_map.csv', rows, delimiter=',', fmt='%.5f', header='true_density,displayed_density,displayed_chroma_Cab', comments='')
