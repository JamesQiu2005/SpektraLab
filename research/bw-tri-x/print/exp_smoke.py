"""All options on tests/Test_image/_smoke_1mp.tif (ProPhoto linear), engine defaults except where stated.
Saves PNGs (sRGB) and measures chroma. MEASURED."""
import json, numpy as np, common as c
from PIL import Image
eng = c.engine(); img = c.smoke(); res = {}
SM = dict(auto_exposure=True, input_color_space="ProPhoto RGB", grain_active=True, halation_active=True, glare_active=True)
def stats(rgba):
    L = c.lab(c.srgb_decode(c.to_float(rgba))); C = np.hypot(L[..., 1], L[..., 2])
    return dict(L_mean=float(L[..., 0].mean()), a_mean=float(L[..., 1].mean()), b_mean=float(L[..., 2].mean()),
                C_mean=float(C.mean()), C_p95=float(np.percentile(C, 95)), C_max=float(C.max()),
                nan=bool(np.isnan(L).any())), L
def go(tag, delta, di=False, save=True):
    d = dict(SM); d.update(delta)
    try:
        rgba, info = c.render(eng, img, d, di=di)
    except Exception as e:
        print(f"{tag:46s} FAILED: {e}"); res[tag] = "FAILED: " + str(e); return None, None
    s, L = stats(rgba); res[tag] = s
    if save: c.save_png(rgba, c.OUT / f"smoke_{tag}.png")
    print(f"{tag:46s} L {s['L_mean']:5.1f}  a {s['a_mean']:+6.2f} b {s['b_mean']:+6.2f}  C mean {s['C_mean']:5.2f} p95 {s['C_p95']:5.2f} max {s['C_max']:5.1f}")
    return rgba, L
BW = "standin_bw_n03"; SOLVED = dict(m_filter_neutral=72.4, y_filter_neutral=85.3)
go("ref_portra400_endura", dict(film_stock="kodak_portra_400"))
go("a_bw_endura_fallback_filters", dict(film_stock=BW, print_stock="kodak_portra_endura"))
rgba_a, L_a = go("a_bw_endura_solved", dict(film_stock=BW, print_stock="kodak_portra_endura", **SOLVED))
go("a_bw_endura_solved_nograin", dict(film_stock=BW, print_stock="kodak_portra_endura", grain_active=False, **SOLVED))
go("a_bw_endura_solved_nograin_nohalation", dict(film_stock=BW, print_stock="kodak_portra_endura", grain_active=False, halation_active=False, **SOLVED))
go("a_bw_endura_solved_nograin_nohal_noglare", dict(film_stock=BW, print_stock="kodak_portra_endura", grain_active=False, halation_active=False, glare_active=False, **SOLVED))
go("a_bw_endura_solved_nograin_nohal_noglare_nodir", dict(film_stock=BW, print_stock="kodak_portra_endura", grain_active=False, halation_active=False, glare_active=False, dir_couplers_active=False, **SOLVED), save=False)
go("b_bw_scan_film", dict(film_stock=BW, scan_film=True))
go("b_bw_di_live", dict(film_stock=BW, digital_intermediate=True))
go("b_bw_di_live_nograin_nohal", dict(film_stock=BW, digital_intermediate=True, grain_active=False, halation_active=False), save=False)
go("b_bw_di_export_cineon", dict(film_stock=BW), di=True)
go("b_portra400_di_live", dict(film_stock="kodak_portra_400", digital_intermediate=True), save=False)
for g, (m, y) in (("soft", (0, 120)), ("mid", (20, 60)), ("hard", (60, 0))):
    go(f"c_bw_vc_paper_{g}_M{m}Y{y}", dict(film_stock=BW, print_stock="standin_vc_paper", m_filter_neutral=m, y_filter_neutral=y))
go("c_bw_vc_paper_mid_nograin_nohal", dict(film_stock=BW, print_stock="standin_vc_paper", m_filter_neutral=20, y_filter_neutral=60, grain_active=False, halation_active=False), save=False)
go("c_bw_vc_paper_warm_M20Y60", dict(film_stock=BW, print_stock="standin_vc_paper_warm", m_filter_neutral=20, y_filter_neutral=60))
# (d) desaturate the colour-paper print at the very end: keep CIE Y, drop chroma
if rgba_a is not None:
    lin = c.srgb_decode(c.to_float(rgba_a)); Y = lin @ c.M_SRGB[1]
    enc = np.where(Y <= 0.0031308, 12.92 * Y, 1.055 * np.maximum(Y, 0) ** (1 / 2.4) - 0.055)
    Image.fromarray((np.repeat(enc[..., None], 3, 2) * 255 + 0.5).clip(0, 255).astype(np.uint8)).save(c.OUT / "smoke_d_bw_endura_solved_desaturated.png")
    C = np.hypot(L_a[..., 1], L_a[..., 2]); res["d_removed_chroma"] = dict(C_mean=float(C.mean()), C_p95=float(np.percentile(C, 95)))
    print("d: desaturating a_bw_endura_solved removes C* mean %.2f / p95 %.2f; L* unchanged by construction" % (C.mean(), np.percentile(C, 95)))
json.dump(res, open(c.OUT / "smoke.json", "w"), indent=1)
