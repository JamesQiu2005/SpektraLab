"""Write ilford_multigrade_iv_rc.json (engine paper schema) and grade_table.json from out/fit_free.json.

Written from scratch: no array is copied from a spektrafilm profile.
Tags in the profile's metadata.provenance. Run: "$REF/.venv/bin/python" build_profile.py [fit tag]
"""
import json, sys, numpy as np
from scipy.optimize import brentq
import mg
tag = sys.argv[1] if len(sys.argv) > 1 else '_free'
f = json.load(open(mg.H + '/out/fit%s.json' % tag))
A = np.array(f['A']); cen = np.array(f['centers']); sig = np.array(f['sigmas']); w = np.array(f['weights']); g = np.array(f['g'])
S = mg.sensitivities(g, f['edge'], f['width'])
BASE_D = 0.06            # ASSUMED: flat (neutral) paper white, reflectance 0.87. The sheet gives no base density.
MID_TARGET = -np.log10(0.184)   # CHOICE: a scene mid-grey prints at Y = 0.184 at filter 2 (what Portra 400 -> Endura measures: 0.748)
SPEED_D = 0.60           # SHEET: ISO P is defined at 0.6 over base; Ilford's filters are speed-matched there

rows = {r['grade']: r for r in f['grades']}
def curve(gr, u):        # density over base at fit coordinate u = X_sheet - x0
    return mg.paper_density(u, np.array(rows[gr]['dx']), A, cen, sig, w)
u_mid = brentq(lambda u: curve('2', u) - (MID_TARGET - BASE_D), -1.5, 1.5)
cen_p = cen - u_mid      # profile axis: x = 0 is the film's mid-grey at filter 2, print_exposure 1
def curve_p(gr, x): return mg.paper_density(x, np.array(rows[gr]['dx']), A, cen_p, sig, w)
x_speed = {gr: brentq(lambda x: curve_p(gr, x) - SPEED_D, -2, 2) for gr in mg.GRADES}

table = {}
for gr in mg.GRADES:
    c, m, y = mg.pack(rows[gr]['t'])
    pe = 10 ** (x_speed[gr] - x_speed['2'])
    # what the dichroic head itself costs in light, relative to filter 2 (python replica, not a render)
    _, lm = mg.channel_logx(S, (c, m, y)); _, lm2 = mg.channel_logx(S, mg.pack(rows['2']['t']))
    pe_mid = 10 ** brentq(lambda x: curve_p(gr, x) - (MID_TARGET - BASE_D), -2, 2)   # alternative: hold mid-grey itself
    table[gr] = dict(M=round(m, 1), Y=round(y, 1), print_exposure=round(float(pe), 4), print_exposure_hold_midgrey=round(float(pe_mid), 4),
                     head_light_loss_stops_vs_filter2=round(float((lm2 - lm) / np.log10(2)), 2),
                     sheet_axis_offset=float(rows[gr]['x0'] + u_mid + np.log10(pe)),   # X_sheet = (log exposure relative to this row's own mid-grey exposure) + this
                     fit_rms=rows[gr]['rms'], fit_R=rows[gr]['R_model'])
    print('filter %2s  M %5.1f Y %5.1f  print_exposure %.3f  head loss %+.2f st' % (gr, m, y, pe, table[gr]['head_light_loss_stops_vs_filter2']))
json.dump(dict(paper='ilford_multigrade_iv_rc', film='kodak_tri_x_400', enlarger_illuminant='TH-KG3',
               note='C = 0. print_exposure holds the D = 0.60-over-base point of the print on one negative density at every filter '
                    '(Ilford speed-matching, extended to 4 and 5). Half grades are not on the sheet and not in this table.',
               grades=table), open(mg.H + '/grade_table.json', 'w'), indent=1)

# ---- the profile -------------------------------------------------------------------------
LE = np.linspace(-3.0, 4.0, 256)
from scipy.special import ndtr
amp = A[:, None] * w                                             # [channel][layer]
layers = np.stack([[amp[c, l] * ndtr((LE - cen_p[c, l]) / sig[c, l]) for c in range(3)] for l in range(3)], 0)  # [layer][channel][k]
dc = layers.sum(0).T                                             # [k][channel]
# sensitivity scale: geometric-mean raw through the Tri-X mid-grey negative (0.286 + 0.574) at filter 2 = 1,
# so the un-normalised preflash offset is of a sane size. ASSUMED convention; the normalised print does not see it.
raw = (mg.enlarger(mg.pack(rows['2']['t']))[:, None] * 10 ** -0.86 * S).sum(0)
S = S / np.exp(np.log(raw).mean())
logS = np.log10(np.maximum(S, 1e-10))
silver = np.ones_like(mg.WL)                                     # ASSUMED: spectrally flat developed silver (neutral image tone)
base = np.full_like(mg.WL, BASE_D)                               # ASSUMED: flat base
profile = dict(
    metadata=dict(
        version='feasibility-1', created='2026-10-07',
        copyright='SpektraLab research data. Not a spektrafilm profile; no array is derived from one.',
        datasource='HARMAN technology Ltd, "MULTIGRADE RC PAPERS Technical Information", June 2019 '
                   '(MULTIGRADE-IV-RC-Papers-060619.pdf): characteristic curves for filters 00-5 (raster charts, p3), '
                   'ISO R / ISO P tables (p2), spectral sensitivity chart (p1, no ordinate scale).',
        provenance=dict(
            density_curves_model='FITTED to the sheet curves: three emulsions (one per channel), each a sum of three normal cdfs',
            log_sensitivity='SHEET shape (one curve for the whole paper, ordinate taken as linear relative sensitivity: ASSUMED) '
                            'split into a shared blue part and a green part scaled per emulsion (split edge and green speeds FITTED; '
                            'per-emulsion sensitivities are not published)',
            channel_density='ASSUMED spectrally flat silver in all three channels: neutral image tone '
                            '(the sheet says Cool/Neutral for MGIV RC De Luxe and gives no spectrum)',
            base_density='ASSUMED flat 0.06 (the sheet says Cool/Neutral base and gives no number)',
            log_exposure_origin='CHOICE: 0 = the exposure a Tri-X mid-grey negative gives at filter 2, landing on Y = 0.184',
            fit=dict(green_speed_log10=np.log10(g).tolist(), blue_edge_nm=f['edge'], blue_edge_width_nm=f['width'], dmax_over_base=mg.DMAX))),
    info=dict(stock='ilford_multigrade_iv_rc', name='ILFORD MULTIGRADE IV RC De Luxe (feasibility fit)', type='negative',
              support='paper', stage='printing', use='still', antihalation='strong', target_print=None,
              channel_model='bw', densitometer='diffuse_visual', log_sensitivity_density_over_min=0.6,
              reference_illuminant='TH-KG3', viewing_illuminant='D50'),
    data=dict(wavelengths=mg.WL.tolist(), log_sensitivity=logS.tolist(),
              channel_density=np.stack([silver] * 3, 1).tolist(), base_density=base.tolist(),
              midscale_neutral_density=(base + 0.7 * silver).tolist(),
              log_exposure=LE.tolist(), density_curves=dc.tolist(),
              density_curves_layers=np.transpose(layers, (2, 0, 1)).tolist(),
              density_curves_model=dict(model_type='cdfs', centers=cen_p.tolist(), amplitudes=amp.tolist(), sigmas=sig.tolist())))
for dst in (mg.H + '/ilford_multigrade_iv_rc.json', mg.H + '/res/profiles/ilford_multigrade_iv_rc.json'):
    json.dump(profile, open(dst, 'w'))
np.savetxt(mg.H + '/csv/profile_sensitivity.csv', np.c_[mg.WL, logS], delimiter=',', fmt='%.4f',
           header='wavelength_nm,logS_emulsion_fast_green,logS_emulsion_mid,logS_emulsion_slow_green', comments='')
np.savetxt(mg.H + '/csv/profile_curves.csv', np.c_[LE, dc, dc.sum(1)], delimiter=',', fmt='%.5f',
           header='log_exposure,D_emulsion_1,D_emulsion_2,D_emulsion_3,sum_at_zero_stagger', comments='')
# a LOCAL copy of the film whose DI paper is this paper (the original is not touched)
t = json.load(open(mg.H + '/../profile/kodak_tri_x_400.json')); t['info']['stock'] = 'kodak_tri_x_400_mgiv'; t['info']['target_print'] = 'ilford_multigrade_iv_rc'
json.dump(t, open(mg.H + '/res/profiles/kodak_tri_x_400_mgiv.json', 'w'))
print('profile written; Dmax over base %.3f; centres' % dc.sum(1).max(), np.round(cen_p, 3).tolist())
