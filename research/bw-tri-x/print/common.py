"""Shared helpers. Run with REF venv python; PYTHONPATH must include <repo>/engine/tests."""
import os, sys, json, math
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
REPO = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify")
RES = HERE / "res"
OUT = HERE / "out"
sys.path.insert(0, str(REPO / "engine/tests"))
from spk_ctypes import Engine  # noqa

def engine():
    return Engine(resources=RES)

STOPS = np.arange(-6, 6.01, 1.0)
def ramp(stops=STOPS, patch=48):
    """Grey patches, linear, 0.184*2^stop; rows repeated."""
    row = np.repeat(0.184 * 2.0 ** stops, patch)
    img = np.tile(row[None, :, None], (patch * 2, 1, 3)).astype(np.float32)
    return img

BASE = dict(auto_exposure=False, input_cctf_decoding=False, input_color_space="sRGB",
            output_color_space="sRGB", output_cctf_encoding=True,
            grain_active=False, halation_active=False, glare_active=False,
            scanner_white_correction=False, scanner_black_correction=False)

def srgb_decode(v):
    v = np.asarray(v, float)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
M_SRGB = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
WHITE = M_SRGB @ np.ones(3)
def lab(rgb_lin):
    xyz = np.asarray(rgb_lin) @ M_SRGB.T / WHITE
    f = np.where(xyz > (6/29)**3, np.cbrt(np.maximum(xyz, 1e-12)), xyz / (3*(6/29)**2) + 4/29)
    return np.stack([116*f[..., 1]-16, 500*(f[..., 0]-f[..., 1]), 200*(f[..., 1]-f[..., 2])], -1)

def to_float(rgba):
    return rgba[..., :3].astype(np.float64) / 65535.0

def patches(rgba, n=len(STOPS), patch=48):
    f = to_float(rgba)
    h, w = f.shape[:2]
    pw = w / n
    out = []
    for i in range(n):
        x0, x1 = int((i + 0.3) * pw), int((i + 0.7) * pw)
        out.append(f[int(h*0.3):int(h*0.7), x0:x1].reshape(-1, 3).mean(0))
    return np.array(out)

def render(eng, img, delta, tier="full", di=False):
    d = dict(BASE); d.update(delta)
    with eng.open(img, d) as s:
        if di:
            rgba, info = s.render_digital_intermediate()
            return rgba, info
        rgba, _ = s.render(tier)
        return rgba, s.get_params()

def save_png(rgba, path):
    from PIL import Image
    Image.fromarray((to_float(rgba) * 255 + 0.5).clip(0, 255).astype(np.uint8)).save(path)

def smoke():
    sys.path.insert(0, "/Volumes/Hanze_Qiu/Documents/Summer 2026/spektrafilm/src")
    from spektrafilm.utils.io import load_image_oiio
    a = np.asarray(load_image_oiio(str(REPO / "tests/Test_image/_smoke_1mp.tif")), dtype=np.float32)
    return np.ascontiguousarray(a[..., :3])
