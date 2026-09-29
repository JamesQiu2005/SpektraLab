import importlib.util, json, numpy as np
from pathlib import Path
REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("p", REPO / "rfc/probes/rfc028-demask-probe.py")
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
eng = p.engine()
stops = np.arange(-8, 8.01, 0.25)
films = ["kodak_vision3_50d", "kodak_vision3_250d", "kodak_vision3_200t", "kodak_vision3_500t",
         "kodak_portra_160", "kodak_portra_400", "kodak_portra_800", "kodak_ektar_100",
         "kodak_gold_200", "kodak_ultramax_400", "fujifilm_c200", "fujifilm_pro_400h", "fujifilm_xtra_400"]
print(f"{'film':22s} {'paper':22s} printing-density gamma R/G/B   G/0.6")
for f in films:
    target = p.profile(f)["info"]["target_print"]
    p.PAPER = target
    sc = p.scanners()
    cmy = p.wedge(eng, f, stops)
    inv = p.Inversion(p.Negative(f), sc["printing"], stops, cmy)
    g = inv.gamma
    print(f"{f:22s} {target:22s} {g[0]:.3f} / {g[1]:.3f} / {g[2]:.3f}      {g[1]/0.6:.2f}")
