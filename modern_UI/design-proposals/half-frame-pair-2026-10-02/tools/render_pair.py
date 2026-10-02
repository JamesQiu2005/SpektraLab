# Design-asset renders only (scratchpad; not part of the product): real source frames
# through filmify's own engine dylib, so the drawings show what the app would show.
import sys, json, subprocess
from pathlib import Path
import numpy as np
FILMIFY = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify")
PROTO = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/SpektraLab_mobile/research/overscan/engine_proto")
sys.path.insert(0, str(FILMIFY / "engine/tests"))
import spk_ctypes as spk
OUT = Path(__file__).parent / "img"
BASE = {"film_stock": "kodak_gold_200", "print_stock": "kodak_supra_endura",
        "input_color_space": "ProPhoto RGB", "input_cctf_decoding": True,
        "output_color_space": "sRGB", "output_cctf_encoding": True}
SIZES = {"street": (1600, 2400), "snow": (1600, 2400), "cathedral": (2400, 1600), "bund": (2400, 1600), "nyc": (2400, 1600)}

def enc(rgba, png):
    raw = OUT / (Path(png).stem + ".u16")
    np.ascontiguousarray(rgba.astype("<u2")).tofile(raw)
    subprocess.run([str(PROTO / "imgio"), "encode", str(raw), str(rgba.shape[1]), str(rgba.shape[0]), str(png)], check=True)
    raw.unlink()

def run(img, delta, png, tier="preview"):
    with spk.Engine() as e:
        s = e.open(img, {**BASE, **delta}); rgba, res = s.render(tier); s.close()
    enc(rgba, png); print(png.name, rgba.shape, rgba.dtype, rgba.reshape(-1, rgba.shape[2])[:, :3].mean(0) if png.name.startswith("gap") else "")

def src(name):
    w, h = SIZES[name]
    return np.fromfile(PROTO / "in" / f"{name}.f32", dtype=np.float32).reshape(h, w, 3)

# A 3:4 slot cut from a 2:3 portrait keeps 1600 x 2133 of 2400: the slot's long edge is 24 mm.
ff = 24 * 2400 / 2133
run(src("street"), {"film_format_mm": ff}, OUT / "half_street.png")
run(src("snow"), {"film_format_mm": ff}, OUT / "half_snow.png")
run(src("snow"), {"film_format_mm": ff, "print_exposure": 2 ** -0.4}, OUT / "half_snow_bright.png")
run(src("cathedral"), {"film_format_mm": 24 * 2400 / 1600}, OUT / "cathedral.png")
# The gap: unexposed film of the same stock, printed. Grain included, so it is a patch, not a colour.
gap = np.full((2133, 96, 3), 1e-6, np.float32)
for tag, stops in (("gap", 0.0), ("gap_overscan_up", 0.4), ("gap_overscan_up2", 1.5)):
    run(gap, {"film_format_mm": 24 * 2133 / 2133 * 1.0, "auto_exposure": False, "exposure_compensation_ev": 0.0,
              "print_exposure": 2 ** -stops}, OUT / f"{tag}.png")
