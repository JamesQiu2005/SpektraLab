"""MEASURED: do the DIR-coupler node and the print glare change a 3-identical-channel negative / its print?"""
from common import *
import json
e = spk.Engine()
NF = {s: neutral(e, s) for s in ("standin_bw_silver", "standin_bw_dyes")}; NF["kodak_portra_400"] = {}; print("neutral filters", NF)
try:
    import re
except Exception: pass
W, H, FMT = 1200, 400, 12.0
ramp = np.repeat((0.18 * 2.0 ** np.linspace(-7, 6, W))[None, :, None], H, 0).repeat(3, 2).astype(np.float32)   # uniform columns, 13 stops
steps = np.repeat(np.repeat(0.18 * 2.0 ** np.arange(-6, 6.01, 1.0), 90)[None, :W, None], H, 0).repeat(3, 2).astype(np.float32)  # 0.9 mm flat patches
edge = np.full((H, W, 3), 0.045, np.float32); edge[:, 600:] = 0.72            # a 4-stop edge around mid-grey
out = {}
for stock in ("standin_bw_silver", "standin_bw_dyes"):
    base = dict(film_stock=stock, film_format_mm=FMT, halation_active=False, **NF[stock])
    for sf in (True, False):
        tag = f"{stock} {'NEG' if sf else 'PRINT'}"
        a = render(e, steps, dict(base, scan_film=sf, dir_couplers_active=False)); b = render(e, steps, dict(base, scan_film=sf))
        centres = [45 + 90 * i for i in range(13)]
        d = np.array([b[200, c] - a[200, c] for c in centres]) * 255
        print(f"{tag}: flat patches (centre of 0.9 mm patch), DIR on - off, max |diff| = {np.abs(d).max():.3f}/255 ; per channel max {np.abs(d).max(0).round(3)}")
        a = render(e, edge, dict(base, scan_film=sf, dir_couplers_active=False)); b = render(e, edge, dict(base, scan_film=sf))
        d = (b[200] - a[200]) * 255
        i = np.abs(d).sum(1).argmax()
        print(f"{tag}: 4-stop edge, DIR on - off: largest change at x={i} ({(i-600)*10} um from the edge): dRGB = {d[i].round(2)} /255 ; R-G {d[i,0]-d[i,1]:+.2f}  B-G {d[i,2]-d[i,1]:+.2f}")
        g0 = render(e, np.full((32, 48, 3), 0.18, np.float32), dict(base, scan_film=sf, dir_couplers_active=False))[16, 24]
        print(f"      (0.18 grey renders {g0.round(4)})")
        for off in (-30, -10, -3, 2, 9, 29):
            print(f"      x-edge {off*10:+5d} um  dRGB {d[600+off].round(2)}")
        out[tag] = d[560:640].tolist()
# print glare: neutral? (unseeded -> compare means)
g = np.full((400, 600, 3), 0.18, np.float32)
for stock in ("standin_bw_silver", "kodak_portra_400"):
    a = render(e, g, dict(film_stock=stock, **NF[stock], glare_active=False)); 
    for amt in (1.0, 30.0):
        b = render(e, g, dict(film_stock=stock, **NF[stock], glare_active=True, glare_amount=amt))
        d = (b - a).reshape(-1, 3) * 255
        print(f"print glare on {stock}, amount {amt}: mean lift RGB {d.mean(0).round(3)} /255, sd {d.std(0).round(3)}")
    a = render(e, g, dict(film_stock=stock, **NF[stock], glare_active=False, scan_film=True)); b = render(e, g, dict(film_stock=stock, **NF[stock], glare_active=True, glare_amount=30.0, scan_film=True))
    print(f"   scan_film: glare on(30) - off max |diff| = {np.abs(b-a).max()*255:.4f}/255")
json.dump(out, open(HERE + "/dir_edge.json", "w"))
