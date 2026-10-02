# Design sample (scratchpad): the scratch engine (mobile 371ad16 + pair_scratch.patch) renders two
# neighbouring 135 half frames on one strip. Not product code.
import sys, subprocess
from pathlib import Path
import numpy as np
ENG = Path(__file__).resolve().parent.parent / "meng/engine"
PROTO = Path("/Volumes/Hanze_Qiu/Documents/Summer 2026/SpektraLab_mobile/research/overscan/engine_proto")
sys.path.insert(0, str(ENG / "tests"))
import spk_ctypes as spk
OUT = Path(__file__).parent / "img"

def slot(name):  # the 3:4 half-frame gate cut from a 2:3 portrait: 1600 x 2133
    a = np.fromfile(PROTO / "in" / f"{name}.f32", dtype=np.float32).reshape(2400, 1600, 3)
    return a[133:133 + 2133]

H, W = 2133, 1600                  # 24 mm across the film, 18 mm along it
ADV = round(19.0 / 24.0 * H)       # one advance, 4 perforations = 19.00 mm -> 1689 px
L, R = slot("street"), slot("snow")
comp = np.empty((H, ADV + W, 3), np.float32)
comp[:, :W] = L
comp[:, ADV:] = R
# the 1 mm between the gates is never exposed (the kernel's gate decides); filled only so the meter
# sees the two pictures and nothing else
comp[:, W:ADV] = 0.5 * (L[:, -1:, :] + R[:, :1, :])

def run(delta, png, tier="preview"):
    base = {"film_stock": "kodak_gold_200", "print_stock": "kodak_supra_endura",
            "input_color_space": "ProPhoto RGB", "input_cctf_decoding": True,
            "output_color_space": "sRGB", "output_cctf_encoding": True,
            "overscan_active": True, "overscan_format": "135_half", "overscan_mode": "strip",
            "overscan_pair": True, "overscan_camera_seed": 19, "overscan_frame_seed": 5,
            "overscan_edge_text": "KODA GOLD 200"}
    with spk.Engine(dylib=ENG / "build/libspektrafilm_engine.dylib") as e:
        s = e.open(comp, {**base, **delta}); rgba, res = s.render(tier); s.close()
    raw = OUT / (Path(png).stem + ".u16")
    np.ascontiguousarray(rgba.astype("<u2")).tofile(raw)
    subprocess.run([str(PROTO / "imgio"), "encode", str(raw), str(rgba.shape[1]), str(rgba.shape[0]), str(png)], check=True, capture_output=True)
    raw.unlink()
    print(png.name, rgba.shape[1], "x", rgba.shape[0], f"{res.elapsed_ms:.0f} ms")

print("input", comp.shape[1], "x", comp.shape[0], "advance px", ADV)
run({}, OUT / "strip_pair_6_6A.png")
run({"overscan_holes": "black"}, OUT / "strip_pair_6_6A_black.png")
