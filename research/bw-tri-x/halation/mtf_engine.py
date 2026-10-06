"""MEASURED small-signal MTF of the built engine's film stage (scatter, halation, DIR) on the stand-in profiles.
10 % sinusoidal exposure gratings, 2 um/px; response = output modulation / output modulation of the same grating with
halation+scatter+DIR off (cancels the scanner unsharp and the output encoding)."""
from common import *
from mtf_model import scatter, halation, dir_mtf, G, sheet_mtf
import json, pathlib
from scipy.optimize import least_squares
scr = spk.Engine(dylib=pathlib.Path(HERE + "/scratch_engine/build/libspektrafilm_engine.dylib"), resources=pathlib.Path(HERE + "/resources"))
W, Hh, PXUM = 4096, 48, 2.0
FMT = W * PXUM / 1000
FREQ = [1, 2, 3, 5, 7, 10, 15, 20, 30, 40, 50, 60, 72, 100]
KEYS = ("HAL_STRENGTH", "HAL_SIGMA", "SC_CORE", "SC_TAIL", "SC_W", "DIR_SAME", "DIR_INTER", "DIR_DIFF", "DIR_TAILW")
def setenv(**kw):
    for k in KEYS: os.environ.pop("SPKX_" + k, None)
    for k, v in kw.items(): os.environ["SPKX_" + k] = v
x_mm = np.arange(W) * PXUM / 1000
def amp(o, f):
    row = o[Hh // 2, 600:-600]; x = x_mm[600:-600]
    A = np.c_[np.ones_like(x), np.sin(2 * np.pi * f * x), np.cos(2 * np.pi * f * x)]
    c = np.linalg.lstsq(A, row, rcond=None)[0]           # per channel
    return np.hypot(c[1], c[2])
def run(stock, env, extra):
    setenv(**env); out = []
    for f in FREQ:
        img = np.repeat((0.18 * (1 + 0.1 * np.sin(2 * np.pi * f * x_mm)))[None, :, None], Hh, 0).repeat(3, 2).astype(np.float32)
        out.append(amp(render(scr, img, dict(film_stock=stock, film_format_mm=FMT, scan_film=True, **extra)), f))
    setenv(); return np.array(out)       # (nf, 3)
OFF = dict(halation_active=False, dir_couplers_active=False)
F = np.array(FREQ, float); res = {"freq": FREQ}
def show(name, m, model=None):
    res[name] = m.tolist()
    print(name); print("   f     " + " ".join(f"{f:6.0f}" for f in FREQ))
    for c in range(m.shape[1]): print("   " + "RGB"[c] + " meas " + " ".join(f"{100*v:6.1f}" for v in m[:, c]))
    if model is not None: print("   model  " + " ".join(f"{100*v:6.1f}" for v in model)); print("   max |meas(G)-model| = %.2f %% pts" % (100 * np.abs(m[:, 1] - model).max()))
for stock in ("standin_bw_silver", "standin_bw_dyes"):
    ref = run(stock, {}, OFF)
    m = run(stock, {}, dict(dir_couplers_active=False)) / ref
    an = np.mean([scatter(F, c, t, w) * halation(F, s) for c, t, w, s in zip([2.2, 2.0, 1.6], [9.3, 9.7, 9.1], [0.78, 0.65, 0.67], [0.015, 0.005, 0.0])], 0)
    show(f"[{stock}] shipped defaults: scatter per-channel + halation preset 'strong', DIR off  (model = mean of the 3 analytic channels)", m, an)
    m = run(stock, {}, dict(halation_active=False)) / ref
    show(f"[{stock}] DIR couplers ON at default amount 1, halation+scatter off", m)
    kfit = [least_squares(lambda p: dir_mtf(F, p[0]) - m[:, c], [0.3], bounds=([0], [0.95])).x[0] for c in range(3)]
    print("   fitted k per output channel:", np.round(kfit, 3)); res[f"k_default_{stock}"] = kfit
stock = "standin_bw_silver"; ref = run(stock, {}, OFF)
m = run(stock, dict(SC_CORE="2,2,2", SC_TAIL="9.7,9.7,9.7", SC_W="0.65,0.65,0.65", HAL_STRENGTH="0,0,0"), dict(dir_couplers_active=False)) / ref
show("[silver] scatter = default G x3, no halation", m, scatter(F, 2.0, 9.7, 0.65))
fit = json.load(open(HERE + "/mtf_fit.json"))
a = fit["A2"]["core"]
m = run(stock, dict(SC_CORE=f"{a},{a},{a}", SC_W="0,0,0", HAL_STRENGTH="0,0,0"), dict(dir_couplers_active=False)) / ref
show(f"[silver] fit A2: core {a:.2f} um x3, tail weight 0", m, G(F, a))
# fit B2: Gaussian core + same-layer-only inhibition, three equal channels; scale gamma so the measured k matches
b, k = fit["B2"]["core"], fit["B2"]["k"]
def k_of(gs):
    mm = run(stock, dict(SC_W="0,0,0", SC_CORE="0,0,0", HAL_STRENGTH="0,0,0", DIR_SAME=f"{gs},{gs},{gs}", DIR_INTER="0,0,0,0,0,0"), dict(halation_scatter_amount=0.0)) / ref
    return least_squares(lambda p: dir_mtf(F, p[0]) - mm[:, 1], [0.2], bounds=([0], [0.95])).x[0]
k1 = k_of(0.3); gs = 0.3 * (k / (1 - k)) / (k1 / (1 - k1))     # k/(1-k) = m*g0 is linear in the matrix
print(f"same-layer gamma 0.3 -> k {k1:.3f} on the stand-in at 0.18 grey; gamma for k={k:.3f}: {gs:.3f}")
res["B2_gamma_same"] = gs; res["k_at_gamma_0.3"] = k1
m = run(stock, dict(SC_CORE=f"{b},{b},{b}", SC_W="0,0,0", HAL_STRENGTH="0,0,0", DIR_SAME=f"{gs},{gs},{gs}", DIR_INTER="0,0,0,0,0,0"), {}) / ref
show(f"[silver] fit B2: core {b:.2f} um, DIR same-layer {gs:.3f} x3, interlayer 0, diffusion 20 um", m, G(F, b) * dir_mtf(F, k))
fs, rs = sheet_mtf(); sh = np.interp(np.log(F), np.log(fs), rs)
print("   sheet  " + " ".join(f"{100*v:6.1f}" if fs.min() <= f <= fs.max() else "     -" for f, v in zip(F, sh)))
# wire-only attempt: dir_couplers_amount scaled, default (unequal) matrix
for amt in (0.25, 0.4):
    m = run(stock, dict(SC_CORE=f"{b},{b},{b}", SC_W="0,0,0", HAL_STRENGTH="0,0,0"), dict(dir_couplers_amount=amt)) / ref
    show(f"[silver] core {b:.2f} um + default coupler matrix at wire dir_couplers_amount={amt}", m)
json.dump(res, open(HERE + "/mtf_engine.json", "w"), indent=1)
