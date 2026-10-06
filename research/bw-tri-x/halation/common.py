import os, sys, numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = "/Volumes/Hanze_Qiu/Documents/Summer 2026/filmify"
os.environ["SPEKTRAFILM_ENGINE_RESOURCES"] = HERE + "/resources"
sys.path.insert(0, REPO + "/engine/tests")
import spk_ctypes as spk
BASE = {"print_stock": "kodak_supra_endura", "grain_active": False, "glare_active": False,
        "auto_exposure": False, "lens_blur_um": 0.0, "scanner_lens_blur": 0.0}
def render(e, img, extra, tier="full"):
    p = dict(BASE); p.update(extra)
    s = e.open(img, p)
    try:
        rgba, _ = s.render(tier)
        return rgba[..., :3].astype(np.float64) / 65535.0
    finally:
        s.close()

def neutral(e, stock):
    """m/y_filter_neutral (wire fields) that print 0.18 grey neutral for a stand-in; print-stage balance only."""
    from scipy.optimize import minimize
    g = np.full((32, 48, 3), 0.18, np.float32)
    def f(v):
        o = render(e, g, dict(film_stock=stock, m_filter_neutral=float(np.clip(v[0], 0, 200)), y_filter_neutral=float(np.clip(v[1], 0, 200)), halation_active=False, dir_couplers_active=False))[16, 24]
        return (o[0] - o[1]) ** 2 + (o[2] - o[1]) ** 2
    r = minimize(f, [65, 55], method="Nelder-Mead", options=dict(xatol=0.05, fatol=1e-10, maxiter=200))
    return dict(m_filter_neutral=float(r.x[0]), y_filter_neutral=float(r.x[1]))
