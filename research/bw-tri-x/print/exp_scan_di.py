"""(b) scan of the negative and the Digital Intermediate, on the grey ramp. MEASURED."""
import json, numpy as np, common as c
eng = c.engine(); img = c.ramp(); res = {}
def table(tag, L):
    print(f"  {tag}")
    for n, k in (("L*", 0), ("a*", 1), ("b*", 2)):
        print(f"   {n:4s}  " + " ".join(f"{v:6.1f}" for v in L[:, k]))
for film in ("kodak_portra_400", "standin_bw_n00", "standin_bw_n03", "standin_bw_n06"):
    print("==", film)
    rgba, p = c.render(eng, img, dict(film_stock=film, scan_film=True))
    lin = c.srgb_decode(c.patches(rgba)); L = c.lab(lin)
    table("scan_film=true (the negative itself, viewing illuminant, no inversion in the engine)", L)
    res[film + "|scan"] = L.tolist()
    if film == "standin_bw_n03": c.save_png(rgba, c.OUT / "ramp_scan_film_bw.png")
    # host-side inversion of the scan: per-channel density above base, i.e. what a scanner app does
    base = lin[0]; dens = -np.log10(np.maximum(lin, 1e-6) / base)
    print("   net density R,G,B at 0 / +2 / +4 stops:", np.round(dens[[6, 8, 10]], 3).tolist())
    res[film + "|scan_net_density"] = dens.tolist()
    for mode, d in (("DI live (digital_intermediate=true)", dict(digital_intermediate=True)),):
        try:
            rgba, p = c.render(eng, img, dict(film_stock=film, **d))
            L = c.lab(c.srgb_decode(c.patches(rgba))); table(mode, L); res[film + "|di_live"] = L.tolist()
            if film == "standin_bw_n03": c.save_png(rgba, c.OUT / "ramp_di_bw.png")
        except Exception as e:
            print("  ", mode, "FAILED:", e); res[film + "|di_live"] = "FAILED: " + str(e)
    try:
        rgba, info = c.render(eng, img, dict(film_stock=film), di=True)
        pv = c.patches(rgba)
        print("   spk_render_digital_intermediate (Cineon log) code values/1023, R G B at -2/0/+2:",
              np.round(pv[[4, 6, 8]] * 1023, 1).tolist())
        print("   max |R-G|,|B-G| over ramp (10-bit codes):", np.round(np.abs(pv - pv[:, 1:2]).max(0) * 1023, 2).tolist())
        print("   info:", {k: info[k] for k in info if k not in ("lut",)} if isinstance(info, dict) else info)
        res[film + "|di_export"] = pv.tolist()
    except Exception as e:
        print("   spk_render_digital_intermediate FAILED:", e); res[film + "|di_export"] = "FAILED: " + str(e)
json.dump(res, open(c.OUT / "scan_di.json", "w"), indent=1)
