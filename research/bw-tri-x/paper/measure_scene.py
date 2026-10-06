"""MEASURED on renders: what a scene grey ramp does through Tri-X -> ilford_multigrade_iv_rc at each filter,
the neutral-row and fallback behaviour, the M/Y shift sliders as a grade control, the enlarger's re-timing,
glare and the black/white correction nodes. Writes csv/scene_report.csv and out/scene_checks.json."""
import json, shutil, numpy as np, common as c, mg
stops = np.arange(-10, 10.001, 0.125)
BASE_OVER, DMAXP = 0.04, mg.DMAX
out = {}
def metrics(D_disp, L):
    D = c.true_density(D_disp); dmin_p = 0.06
    s = stops; lo_t = dmin_p + BASE_OVER; hi_t = dmin_p + 0.9 * DMAXP
    Dm = np.maximum.accumulate(D[::-1])[::-1]                       # density falls as the scene brightens
    hi_stop = float(np.interp(-lo_t, -Dm, s))                        # scene stop where the print is 0.04 over base
    reached = Dm.max() >= hi_t
    lo_stop = float(np.interp(-hi_t, -Dm, s)) if reached else float('nan')
    return dict(dmin=float(D.min()), dmax_on_ramp=float(D.max()), d_mid=float(np.interp(0, s, D)), d_mid_displayed=float(np.interp(0, s, D_disp)),
                white_displayed=float(D_disp.min()), highlight_stop=hi_stop, shadow_stop=lo_stop,
                range_stops=float(hi_stop - lo_stop) if reached else float('nan'),
                range_to_ramp_black_stops=float(hi_stop - np.interp(-(D.max() - 0.02), -Dm, s)),
                max_chroma=float(np.hypot(L[:, 1], L[:, 2]).max()))
def run(eng, delta, base=c.CLEAN, film=c.FILM, paper=c.PAPER):
    D, L, p = c.ramp_density(eng, stops, dict(film_stock=film, print_stock=paper, **delta), base=base)
    m = metrics(D, L); m.update(M=p['m_filter_neutral'], Y=p['y_filter_neutral'], C=p['c_filter_neutral'], pe=p['print_exposure']); return m
def show(tag, m):
    print('%-34s M%6.1f Y%6.1f pe %.3f | Dmin %.3f Dmax(ramp) %.3f Dmid %.3f | scene +%.2f .. %s st = %s st (to ramp black %.2f) | white shows as %.3f | C* %.3f'
          % (tag, m['M'], m['Y'], m['pe'], m['dmin'], m['dmax_on_ramp'], m['d_mid'], m['highlight_stop'],
             'n/r' if np.isnan(m['shadow_stop']) else '%.2f' % m['shadow_stop'], 'n/r' if np.isnan(m['range_stops']) else '%.2f' % m['range_stops'],
             m['range_to_ramp_black_stops'], m['white_displayed'], m['max_chroma']))
    out[tag] = m
rows = []
with c.engine() as eng:
    print('--- per filter, grade table, clean tone path (grain, halation, glare, couplers off; auto exposure off)')
    for g in mg.GRADES:
        m = run(eng, c.grade_delta(g)); show('filter ' + g, m); rows.append(dict(filter=g, **m))
    print('--- filter 2 with the engine defaults left on (couplers 1.0, glare, grain, halation)')
    dflt = dict(auto_exposure=False, input_cctf_decoding=False, input_color_space='sRGB', output_color_space='sRGB', output_cctf_encoding=True)
    show('filter 2, engine defaults', run(eng, c.grade_delta('2'), base=dflt))
    show('filter 2, couplers 0.4', run(eng, dict(c.grade_delta('2'), dir_couplers_amount=0.4), base=dflt))
    show('filter 2, clean + glare', run(eng, dict(c.grade_delta('2'), glare_active=True)))
    show('filter 5, clean + glare', run(eng, dict(c.grade_delta('5'), glare_active=True)))
    print('--- no pack on the wire, no database row: the silent fallback')
    show('fallback (no row)', run(eng, {}))
    print('--- enlarger re-timing: exposure_compensation_ev at filter 2 (mid-grey patch density)')
    for ev in (-2, -1, 0, 1, 2):
        show('filter 2, exp comp %+d EV' % ev, run(eng, dict(c.grade_delta('2'), exposure_compensation_ev=float(ev))))
    print('--- black / white correction nodes at filter 2')
    for wc, bc in ((True, False), (False, True), (True, True)):
        try: show('filter 2, white_corr %s black_corr %s' % (wc, bc), run(eng, dict(c.grade_delta('2'), scanner_white_correction=wc, scanner_black_correction=bc)))
        except Exception as ex: print('  ERROR', ex); out['bw %s %s' % (wc, bc)] = str(ex)
    for k, d in (('extended_dynamic_range', dict(extended_dynamic_range=True)), ('preflash 0.1', dict(preflash_exposure=0.1))):
        try: show('filter 2, ' + k, run(eng, dict(c.grade_delta('2'), **d)))
        except Exception as ex: print('  %s -> ERROR: %s' % (k, ex)); out[k] = 'ERROR: ' + str(ex)
# ---- with a database row for (paper, TH-KG3, film): needs its own resources dir -> res_row
T = c.grade_table(); r2 = T['grades']['2']
RR = c.HERE / 'res_row'
if RR.exists(): shutil.rmtree(RR)
RR.mkdir(); (RR / 'profiles').symlink_to(c.RES / 'profiles')
for f in ('spektrafilm_constants.bin', 'spektrafilm.metallib', 'print_luts.json'): (RR / f).symlink_to((c.RES / f).resolve())
db = json.load(open(c.RES / 'neutral_print_filters.json'))
db[c.PAPER] = {'TH-KG3': {c.FILM: [0.0, r2['M'], r2['Y']], 'kodak_tri_x_400_mgiv': [0.0, r2['M'], r2['Y']]}}
json.dump(db, open(RR / 'neutral_print_filters.json', 'w'), indent=1)
json.dump({c.PAPER: {'TH-KG3': {c.FILM: [0.0, r2['M'], r2['Y']]}}}, open(c.HERE / 'neutral_print_filters_row.json', 'w'), indent=1)
with c.Engine(resources=RR) as eng:
    print('--- WITH the row [0, %.1f, %.1f]: nothing on the wire but the two stocks' % (r2['M'], r2['Y']))
    show('row, no wire pack', run(eng, {}))
    print('--- the two existing sliders as a grade control on that row (filter_shift_scale 60), print_exposure left at 1')
    for ms, ys in ((0, 1), (0, 0.5), (0, 0), (0, -0.5), (0, -1), (0.5, -1), (1, -1)):
        show('row, m_shift %+.1f y_shift %+.1f' % (ms, ys), run(eng, dict(m_filter_shift=float(ms), y_filter_shift=float(ys), filter_shift_scale=60.0)))
keys = list(rows[0].keys())
open(c.HERE / 'csv/scene_report.csv', 'w').write(','.join(keys) + '\n' + '\n'.join(','.join(('%.4f' % r[k]) if isinstance(r[k], float) else str(r[k]) for k in keys) for r in rows) + '\n')
json.dump(out, open(c.OUT / 'scene_checks.json', 'w'), indent=1)
