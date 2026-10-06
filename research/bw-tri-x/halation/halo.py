"""Halation colour on a 3-identical-channel stand-in negative. MEASURED through the built engine.
Shipped dylib for defaults; scratch dylib (params.cpp + env overrides, otherwise the shipped objects) for equalised strengths."""
from common import *
import json, itertools
from scipy.optimize import minimize
from PIL import Image
SCR = HERE + "/scratch_engine/build/libspektrafilm_engine.dylib"
W, H, FMT = 1200, 800, 12.0          # 10 um / px: a 12 x 8 mm piece of the negative
PX = FMT * 1000 / W
def scene():
    img = np.full((H, W, 3), 0.02, np.float32)
    y, x = np.mgrid[0:H, 0:W]
    img[(x - 350) ** 2 + (y - 400) ** 2 <= 20 ** 2] = 16.0     # 0.4 mm lamp, +9.6 stops over the surround
    img[:, 900:] = 4.0                                          # bright half-plane
    return img
IMG = scene()
def setenv(**kw):
    for k in ("SPKX_HAL_STRENGTH", "SPKX_HAL_SIGMA", "SPKX_SC_CORE", "SPKX_SC_TAIL", "SPKX_SC_W", "SPKX_DIR_SAME", "SPKX_DIR_INTER", "SPKX_DIR_DIFF"):
        os.environ.pop(k, None)
    for k, v in kw.items(): os.environ["SPKX_" + k] = v
ship = spk.Engine()
scr = spk.Engine(dylib=__import__("pathlib").Path(SCR), resources=__import__("pathlib").Path(HERE + "/resources"))
setenv()
a = render(ship, IMG, dict(film_stock="standin_bw_dyes", film_format_mm=FMT, scan_film=True))
b = render(scr, IMG, dict(film_stock="standin_bw_dyes", film_format_mm=FMT, scan_film=True))
print("scratch dylib without overrides == shipped:", np.array_equal(a, b))

# neutral print filters for the stand-ins (wire fields m/y_filter_neutral), so a print fringe is read against grey
def neutral(stock):
    g = np.full((32, 48, 3), 0.18, np.float32)
    def f(v):
        o = render(ship, g, dict(film_stock=stock, m_filter_neutral=float(np.clip(v[0], 0, 200)), y_filter_neutral=float(np.clip(v[1], 0, 200)), halation_active=False, dir_couplers_active=False))[16, 24]
        return (o[0] - o[1]) ** 2 + (o[2] - o[1]) ** 2
    r = minimize(f, [65, 55], method="Nelder-Mead", options=dict(xatol=0.05, fatol=1e-10, maxiter=200))
    return dict(m_filter_neutral=float(r.x[0]), y_filter_neutral=float(r.x[1]))
NF = {s: neutral(s) for s in ("standin_bw_dyes", "standin_bw_silver")}
NF["kodak_portra_400"] = {}
print("neutral filters", NF)

def profile_stats(o, label):
    row = o[400]                       # through the lamp centre
    far = o[100:140, 80:120].reshape(-1, 3).mean(0)   # 2.7 mm from the lamp, 7.8 mm from the edge
    out = {}
    for d_um in (50, 100, 200, 400):
        px = 350 + 20 + int(round(d_um / PX))
        v = row[px]
        out[d_um] = dict(rgb=[round(float(t), 4) for t in v], dRG_255=round(float((v[0] - v[1]) - (far[0] - far[1])) * 255, 2),
                         dBG_255=round(float((v[2] - v[1]) - (far[2] - far[1])) * 255, 2), dG_255=round(float(v[1] - far[1]) * 255, 2))
    e = {}
    for d_um in (50, 100, 200):
        v = o[150:250, 900 - int(round(d_um / PX))].mean(0); 
        e[d_um] = dict(dRG_255=round(float((v[0] - v[1]) - (far[0] - far[1])) * 255, 2), dBG_255=round(float((v[2] - v[1]) - (far[2] - far[1])) * 255, 2), dG_255=round(float(v[1] - far[1]) * 255, 2))
    return dict(label=label, far=[round(float(t), 4) for t in far], lamp=out, edge=e)

CASES = [
 ("portra400 colour, own preset strong {.015,.005,0}", "kodak_portra_400", {}, {}),
 ("dyes  halation OFF", "standin_bw_dyes", {}, dict(halation_active=False)),
 ("dyes  preset strong {.015,.005,0} (shipped behaviour)", "standin_bw_dyes", {}, {}),
 ("dyes  struct default {.05,.015,0}", "standin_bw_dyes", dict(HAL_STRENGTH="0.05,0.015,0"), {}),
 ("dyes  preset weak {.08,.02,0}", "standin_bw_dyes", dict(HAL_STRENGTH="0.08,0.02,0"), {}),
 ("dyes  equalised {.05,.05,.05}", "standin_bw_dyes", dict(HAL_STRENGTH="0.05,0.05,0.05"), {}),
 ("dyes  equalised {.08,.08,.08}", "standin_bw_dyes", dict(HAL_STRENGTH="0.08,0.08,0.08"), {}),
 ("dyes  equalised strength, scatter still per-channel default", "standin_bw_dyes", dict(HAL_STRENGTH="0.05,0.05,0.05"), {}),
 ("dyes  equalised strength + scatter {2,9.7,.65}x3", "standin_bw_dyes", dict(HAL_STRENGTH="0.05,0.05,0.05", SC_CORE="2,2,2", SC_TAIL="9.7,9.7,9.7", SC_W="0.65,0.65,0.65"), {}),
 ("silver halation OFF", "standin_bw_silver", {}, dict(halation_active=False)),
 ("silver preset weak {.08,.02,0} red-weighted", "standin_bw_silver", dict(HAL_STRENGTH="0.08,0.02,0"), {}),
 ("silver equalised {.0333}x3 (same mean)", "standin_bw_silver", dict(HAL_STRENGTH="0.033333,0.033333,0.033333"), {}),
 ("silver equalised {.08}x3", "standin_bw_silver", dict(HAL_STRENGTH="0.08,0.08,0.08"), {}),
]
res = []; imgs = {}
for label, stock, env, extra in CASES:
    setenv(**env)
    for sf in (True, False):
        o = render(scr, IMG, dict(film_stock=stock, film_format_mm=FMT, scan_film=sf, dir_couplers_active=False, **NF[stock], **extra))
        st = profile_stats(o, label + (" | NEG scan" if sf else " | PRINT")); res.append(st); imgs[(label, sf)] = o
        print(st["label"]); print("   far", st["far"]); 
        for k, v in st["lamp"].items(): print(f"   lamp +{k} um  rgb {v['rgb']}  d(R-G) {v['dRG_255']:+.2f}/255  d(B-G) {v['dBG_255']:+.2f}/255  dG {v['dG_255']:+.2f}/255")
        for k, v in st["edge"].items(): print(f"   edge -{k} um  d(R-G) {v['dRG_255']:+.2f}/255  d(B-G) {v['dBG_255']:+.2f}/255  dG {v['dG_255']:+.2f}/255")
setenv()
json.dump(res, open(HERE + "/halo_results.json", "w"), indent=1)
# crops: lamp neighbourhood, 4x, saturation exaggerated version too
def crop(o): return o[320:480, 270:470]
tiles = []
for key in [("dyes  preset strong {.015,.005,0} (shipped behaviour)", True), ("dyes  struct default {.05,.015,0}", True), ("dyes  equalised {.05,.05,.05}", True),
            ("dyes  preset strong {.015,.005,0} (shipped behaviour)", False), ("dyes  struct default {.05,.015,0}", False), ("dyes  equalised {.05,.05,.05}", False),
            ("silver preset weak {.08,.02,0} red-weighted", False), ("silver equalised {.0333}x3 (same mean)", False), ("silver equalised {.08}x3", False)]:
    tiles.append(np.kron(crop(imgs[key]), np.ones((3, 3, 1))))
rows = [np.concatenate(tiles[i:i + 3], 1) for i in (0, 3, 6)]
Image.fromarray((np.clip(np.concatenate(rows, 0), 0, 1) * 255).astype(np.uint8)).save(HERE + "/halo_crops.png")
print("wrote halo_crops.png: rows = dyes NEG / dyes PRINT / silver PRINT; cols = red-weighted preset, red-weighted default, equalised")
