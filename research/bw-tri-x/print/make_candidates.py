"""Candidate base/silver spectra for a single-silver-layer Tri-X written into the 3-channel schema.
Grid = the profiles' own (380..780 nm, 5 nm, 81 points); units = spectral density (log10), as in kodak_portra_400.json.
Everything spectral here is ASSUMED except the two base+fog totals (SHEET, F-4017 p8). Also verifies that a
neutral_print_filters.json row added in the scratch resources is honoured by the engine (MEASURED)."""
import json, numpy as np, common as c
wl = np.arange(380, 781, 5.0)
def silver(n): return (550.0 / wl) ** n          # normalised to 1.0 at 550 nm (~ diffuse visual)
out = dict(wavelengths=wl.tolist(), note="ASSUMED shapes; see REPORT.md")
for n in (0.0, 0.3, 0.6):
    s = silver(n)
    out[f"silver_n{n}"] = s.tolist()
    out[f"channel_density_n{n}"] = [[v / 3] * 3 for v in s]   # three identical channels summing to the silver image
stain = 0.03 * np.exp(-0.5 * ((wl - 565) / 30) ** 2)           # optional residual sensitising-dye stain (pink/purple)
out["base_density_135"] = (0.24 + 0.06 * silver(0.3)).tolist()  # grey-dyed acetate + fog; total 0.30 @550 (SHEET total)
out["base_density_120"] = (0.14 + 0.06 * silver(0.3)).tolist()  # total 0.20 @550 (SHEET total)
out["optional_stain"] = stain.tolist()
out["midscale_neutral_density_rule"] = "base_density + D_mid * silver, D_mid = net density of the curve at mid-scale exposure; the engine never reads it"
json.dump(out, open(c.OUT / "trix_candidate_spectra.json", "w"), indent=1)
for n in (0.0, 0.3, 0.6):
    s = silver(n); print(f"n={n}: D(450)/D(550) {np.interp(450, wl, s):.3f}  D(650)/D(550) {np.interp(650, wl, s):.3f}  blue/red {np.interp(450, wl, s)/np.interp(650, wl, s):.3f}")
# database row honoured?
p = c.RES / "neutral_print_filters.json"; db = json.load(open(p))
db["kodak_portra_endura"]["TH-KG3"]["standin_bw_n03"] = [0.0, 72.4, 85.3]; json.dump(db, open(p, "w"), indent=1)
eng = c.engine()
with eng.open(c.ramp(), dict(film_stock="standin_bw_n03", print_stock="kodak_portra_endura")) as s:
    g = s.get_params(); print("with a scratch DB row -> M", g["m_filter_neutral"], "Y", g["y_filter_neutral"])
with eng.open(c.ramp(), dict(film_stock="standin_bw_n06", print_stock="kodak_portra_endura")) as s:
    g = s.get_params(); print("no row (n06)        -> M", g["m_filter_neutral"], "Y", g["y_filter_neutral"])
print("print LUT catalog:", {k: v["paired_film"] for k, v in eng.print_lut_catalog().items()})
with eng.open(c.ramp(), dict(film_stock="standin_bw_n03")) as s:
    for stock in ("kodak_portra_endura", "standin_vc_paper"):
        try:
            _, info = s.preview_stock_lut(stock); print("preview_stock_lut", stock, "->", {k: info[k] for k in info if k != "lut"})
        except Exception as e: print("preview_stock_lut", stock, "FAILED:", e)
        try:
            _, info = s.export_di(stock); print("export_di", stock, "->", {k: (v if not isinstance(v, list) else "...") for k, v in info.items()})
        except Exception as e: print("export_di", stock, "FAILED:", e)
# leave the scratch database as shipped, so exp_colour_paper.py's "fallback" rows stay a fallback
import shutil; shutil.copy(c.REPO / "engine/resources/neutral_print_filters.json", p)
