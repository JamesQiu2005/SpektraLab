"""How different are films through the DI, against the same films through a paper?

A ColorChecker (xyY, D50) in linear ProPhoto, a grey ramp -6..+6 stops, and a
flat grey patch for grain. Every film sees the same exposure (no metering).
"""
import sys, itertools
from pathlib import Path
import numpy as np
import colour

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine/tests"))
from spk_ctypes import Engine

P = 48
cc = colour.CCS_COLOURCHECKERS["ColorChecker24 - After November 2014"]
names = list(cc.data.keys())
xyY = np.array(list(cc.data.values()))
XYZ = colour.xyY_to_XYZ(xyY)
pp = colour.RGB_COLOURSPACES["ProPhoto RGB"]
rgb = colour.XYZ_to_RGB(XYZ, pp, illuminant=cc.illuminant, chromatic_adaptation_transform="Bradford",
                        apply_cctf_encoding=False)
rgb *= 0.18 / rgb[21].mean()          # patch 22 (neutral 5) -> 0.18
stops = np.arange(-6, 7)
W = len(stops) * P
H = 4 * P + P + 2 * P
img = np.full((H, W, 3), 0.18, np.float32)
for i, c in enumerate(rgb):
    r, q = divmod(i, 6)
    img[r * P:(r + 1) * P, q * P:(q + 1) * P] = c
for i, s in enumerate(stops):
    img[4 * P:5 * P, i * P:(i + 1) * P] = 0.18 * 2.0 ** s
# rows 5..6: flat grey for grain

def centre(a, y, x):
    return a[y * P + 12:(y + 1) * P - 12, x * P + 12:(x + 1) * P - 12].reshape(-1, a.shape[2])

b = 10 ** ((95 - 685) / 300)
def cineon(code):  return (10 ** ((code * 1023 - 685) / 300) - b) / (1 - b)
def romm(v):       return np.where(v < 16 / 512, v / 16, v ** 1.8)

def oklab(lin):
    xyz = colour.RGB_to_XYZ(np.clip(lin, 0, None), pp, illuminant=pp.whitepoint, apply_cctf_decoding=False)
    xyz65 = colour.adaptation.chromatic_adaptation_VonKries(xyz, colour.xy_to_XYZ(pp.whitepoint),
                                                           colour.xy_to_XYZ([0.3127, 0.3290]), "Bradford")
    return colour.XYZ_to_Oklab(xyz65)

FILMS = ["kodak_vision3_50d", "kodak_vision3_250d", "kodak_vision3_200t", "kodak_vision3_500t",
         "kodak_portra_400", "kodak_ektar_100", "kodak_gold_200", "fujifilm_c200"]
BASE = {"auto_exposure": False, "exposure_compensation_ev": 0.0, "halation_active": False,
        "glare_active": False, "grain_active": False}

def render(eng, film, di, grain=False, paper="kodak_2383"):
    d = dict(BASE, film_stock=film, print_stock=paper, grain_active=grain,
             digital_intermediate=di, scan_film=False)
    with eng.open(img, d) as s:
        rgba, _ = s.render("full")
    v = rgba[..., :3].astype(np.float64) / 65535
    return cineon(v) if di else romm(v)

eng = Engine()
res = {}
for f in FILMS:
    for di in (True, False):
        res[(f, di)] = render(eng, f, di)

scene_lab = oklab(rgb)
def patches(lin):
    return np.array([centre(lin, *divmod(i, 6)).mean(0) for i in range(24)])

def norm_grey(p):
    # compare colour and tone after equalising the neutral-5 patch's level,
    # so an exposure offset between films is not counted as a difference
    return p * (0.18 / p[21, 1])

print("== patch Oklab difference x100 between films (mean / max over 24 patches), neutral-5 levelled ==")
for label, group in [("Vision3 among themselves", FILMS[:4]), ("stills among themselves", FILMS[4:])]:
    for di in (True, False):
        d = []
        for a, c in itertools.combinations(group, 2):
            la, lc = oklab(norm_grey(patches(res[(a, di)]))), oklab(norm_grey(patches(res[(c, di)])))
            e = np.linalg.norm(la - lc, axis=1) * 100
            d.append((a, c, e.mean(), e.max()))
        m = np.mean([x[2] for x in d])
        print(f"  {label:26s} {'DI   ' if di else '2383 '} mean pairwise {m:5.2f}   "
              + "  ".join(f"{a.split('_')[-1]}-{c.split('_')[-1]} {em:4.1f}/{ex:4.1f}" for a, c, em, ex in d))

print("\n== distance from the scene (Oklab x100, mean / max), neutral-5 levelled ==")
for f in FILMS:
    out = []
    for di in (True, False):
        e = np.linalg.norm(oklab(norm_grey(patches(res[(f, di)]))) - scene_lab, axis=1) * 100
        out.append(f"{'DI' if di else '2383'} {e.mean():5.2f}/{e.max():5.2f}")
    print(f"  {f:22s} " + "   ".join(out))

print("\n== grey ramp: output stops relative to neutral-5 (DI decoded; 2383 display-linear) ==")
print("  scene " + " ".join(f"{s:+6.0f}" for s in stops))
for f in FILMS[:4] + ["kodak_portra_400"]:
    for di in (True, False):
        lin = res[(f, di)]
        g = np.array([centre(lin, 4, i).mean(0)[1] for i in range(len(stops))])
        ref = patches(lin)[21, 1]
        print(f"  {f.split('_')[-1]:>5s} {'DI  ' if di else '2383'} " +
              " ".join(f"{np.log2(max(v, 1e-9) / ref):+6.2f}" for v in g))

print("\n== grain: std of log2 luminance on flat grey (stops), grain on ==")
for f in FILMS:
    out = []
    for di in (True, False):
        lin = render(eng, f, di, grain=True)
        y = lin[5 * P + 8:7 * P - 8, 8:-8] @ np.array([0.2880, 0.7119, 0.0001])
        out.append(f"{'DI' if di else '2383'} {np.std(np.log2(np.clip(y, 1e-6, None))):.4f}")
    print(f"  {f:22s} " + "   ".join(out))

print("\n== stale-constants check: open on 50D, switch to 500T, vs a fresh 500T session ==")
d = dict(BASE, film_stock="kodak_vision3_50d", print_stock="kodak_2383", digital_intermediate=True, scan_film=False)
with eng.open(img, d) as s:
    s.render("full")
    s.set_params({"film_stock": "kodak_vision3_500t"})
    switched, _ = s.render("full")
fresh = render(eng, "kodak_vision3_500t", True)
sw = cineon(switched[..., :3].astype(np.float64) / 65535)
print(f"  max |switched - fresh| = {np.abs(sw - fresh).max():.3e}   "
      f"max |50D - 500T fresh| = {np.abs(res[('kodak_vision3_50d', True)] - fresh).max():.3e}")
