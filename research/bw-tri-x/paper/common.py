"""Render helpers (shipping dylib through engine/tests/spk_ctypes.py; resources = ./res, a scratch copy)."""
import os, sys, json
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
REPO = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify")
REFROOT = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/spektrafilm")
RES = HERE / "res"; OUT = HERE / "out"
sys.path.insert(0, str(REPO / "engine/tests"))
from spk_ctypes import Engine, EngineError  # noqa
PAPER = "ilford_multigrade_iv_rc"; FILM = "kodak_tri_x_400"

def engine(): return Engine(resources=RES)

def ramp(stops, patch=12, rows=24):
    row = np.repeat(0.184 * 2.0 ** np.asarray(stops, float), patch)
    return np.tile(row[None, :, None], (rows, 1, 3)).astype(np.float32)

# everything that is not the straight tone path is off for the curve measurements
CLEAN = dict(auto_exposure=False, input_cctf_decoding=False, input_color_space="sRGB",
             output_color_space="sRGB", output_cctf_encoding=True, grain_active=False, halation_active=False,
             glare_active=False, scanner_white_correction=False, scanner_black_correction=False,
             dir_couplers_amount=0.0)

def srgb_decode(v):
    v = np.asarray(v, float); return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
M_SRGB = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
WHITE = M_SRGB @ np.ones(3)
def lab(rgb_lin):
    xyz = np.asarray(rgb_lin) @ M_SRGB.T / WHITE
    f = np.where(xyz > (6/29)**3, np.cbrt(np.maximum(xyz, 1e-12)), xyz / (3*(6/29)**2) + 4/29)
    return np.stack([116*f[..., 1]-16, 500*(f[..., 0]-f[..., 1]), 200*(f[..., 1]-f[..., 2])], -1)
def to_float(rgba): return rgba[..., :3].astype(np.float64) / 65535.0
def patches(rgba, n):
    f = to_float(rgba); h, w = f.shape[:2]; pw = w / n
    return np.array([f[int(h*0.3):int(h*0.7), int((i+0.3)*pw):int((i+0.7)*pw)].reshape(-1, 3).mean(0) for i in range(n)])

def render(eng, img, delta, tier="full", base=CLEAN):
    d = dict(base); d.update(delta)
    with eng.open(img, d) as s:
        rgba, _ = s.render(tier); return rgba, s.get_params()

def ramp_density(eng, stops, delta, base=CLEAN):
    """-> (visual reflection density per patch = -log10 Y, Lab per patch, params)"""
    rgba, p = render(eng, ramp(stops), delta, base=base)
    lin = srgb_decode(patches(rgba, len(stops)))
    return -np.log10(np.maximum(lin @ M_SRGB[1], 1e-6)), lab(lin), p

def film_density(stops, film=FILM):
    """Tri-X net density for a grey of 0.184*2^stop (profile curve; mid-grey sits at log exposure 0)."""
    d = json.load(open(RES / "profiles" / f"{film}.json"))["data"]
    return np.interp(np.asarray(stops) * np.log10(2), d["log_exposure"], np.array(d["density_curves"])[:, 1])

def grade_table():
    return json.load(open(HERE / "grade_table.json"))
def grade_delta(g, table=None):
    r = (table or grade_table())["grades"][g]
    return dict(c_filter_neutral=0.0, m_filter_neutral=r["M"], y_filter_neutral=r["Y"], print_exposure=r["print_exposure"])

def save_png(rgba, path):
    from PIL import Image
    Image.fromarray((to_float(rgba) * 255 + 0.5).clip(0, 255).astype(np.uint8)).save(path)

def load_image(name):
    if name == "smoke":
        sys.path.insert(0, str(REFROOT / "src"))
        from spektrafilm.utils.io import load_image_oiio
        return np.ascontiguousarray(np.asarray(load_image_oiio(str(REPO / "tests/Test_image/_smoke_1mp.tif")), dtype=np.float32)[..., :3])
    return np.ascontiguousarray(np.load(HERE / "inputs" / (name + ".npy")))

def true_density(displayed):
    """invert the output stage's lightness compression (calibrate_output.py; identity above D ~ 0.45)"""
    m = np.genfromtxt(HERE / 'csv/output_lightness_map.csv', delimiter=',', skip_header=1)
    return np.interp(displayed, m[:, 1], m[:, 0])
