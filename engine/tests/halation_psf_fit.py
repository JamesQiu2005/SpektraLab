"""Usage: python3 engine/tests/halation_psf_fit.py [n=1.48] [rho=0.35] [fixed-grid gaussians=6] [free gaussians=4]
Writes psf_*.json to the current directory; the four-Gaussian free fit is what
engine/src/core/halation_psf.hpp carries.

Back-reflection halation PSF of a colour negative without an anti-halation layer.

Geometry (lengths in units of the base thickness d):
  light leaves the emulsion into the base at polar angle theta (inside the base),
  reflects off the base/air face with Fresnel reflectance R(theta) (=1 past the
  critical angle, total internal reflection) and re-enters the emulsion at
  r = 2 tan(theta).

Single bounce, for a Lambertian source of unit power into the base:
  I(theta) = cos(theta)/pi per steradian
  E(r) = I R sin(theta) dtheta / (r dr) = R(theta) cos^4(theta) / (4 pi)       [d = 1]
plus an unscattered (specular) part: the lens cone, refracted into the base,
returning within r <= 2 tan(theta_lens) with R ~ 4 %.

The emulsion that the light returns to absorbs part (the exposure we see) and
re-scatters a fraction rho back into the base, Lambertian again, so the total
exposure kernel is the Neumann series
  K = h + rho h*h + rho^2 h*h*h + ...   ->   K^ = h^ / (1 - rho h^)
evaluated with a 2-D FFT. The kernel is then softened by the emulsion's own
thickness (Gaussian, sigma_e) and fitted with a signed Gaussian mixture that
stays non-negative everywhere.
"""
import json, sys
import numpy as np
from scipy.optimize import minimize

n = float(sys.argv[1]) if len(sys.argv) > 1 else 1.48      # cellulose triacetate
rho = float(sys.argv[2]) if len(sys.argv) > 2 else 0.35     # emulsion diffuse reflectance from below
spec = 0.15                                                 # unscattered fraction reaching the base
f_number = 2.8
sigma_e = 0.08                                              # emulsion thickness softening, units of d

theta_c = np.arcsin(1 / n)


def fresnel_internal(theta):
    """Unpolarised reflectance from inside a medium of index n into air."""
    s = n * np.sin(theta)
    out = np.ones_like(theta)
    ok = s < 1
    ti = theta[ok]
    tt = np.arcsin(s[ok])
    rs = ((n * np.cos(ti) - np.cos(tt)) / (n * np.cos(ti) + np.cos(tt))) ** 2
    rp = ((n * np.cos(tt) - np.cos(ti)) / (n * np.cos(tt) + np.cos(ti))) ** 2
    out[ok] = 0.5 * (rs + rp)
    return out


# --- 2-D grid ---------------------------------------------------------------
N, L = 2048, 40.0                    # 40 d wide
dx = L / N
x = (np.arange(N) - N // 2) * dx
X, Y = np.meshgrid(x, x)
Rr = np.hypot(X, Y)
th = np.arctan(Rr / 2)
h_diff = fresnel_internal(th) * np.cos(th) ** 4 / (4 * np.pi)

# specular: the lens cone in air, refracted into the base, uniform over the cone's footprint
th_l = np.arcsin(np.sin(np.arctan(1 / (2 * f_number))) / n)
r_l = 2 * np.tan(th_l)
R0 = fresnel_internal(np.array([0.0]))[0]
h_spec = np.where(Rr <= r_l, R0 / (np.pi * r_l ** 2), 0.0)

h = (1 - spec) * h_diff + spec * h_spec
eta = h.sum() * dx * dx
eta_tir = (1 - spec) * np.cos(theta_c) ** 2

H = np.fft.fft2(np.fft.ifftshift(h)) * dx * dx
K = np.real(np.fft.fftshift(np.fft.ifft2(H / (1 - rho * H)))) / (dx * dx)
# emulsion softening
G = np.exp(-(Rr ** 2) / (2 * sigma_e ** 2)); G /= G.sum()
K = np.real(np.fft.fftshift(np.fft.ifft2(np.fft.fft2(np.fft.ifftshift(K)) * np.fft.fft2(np.fft.ifftshift(G)))))
Ktot = K.sum() * dx * dx
K /= Ktot

# radial profile
r = x[N // 2:]
k_r = K[N // 2, N // 2:]
rc = 2 * np.tan(theta_c)
cum = np.cumsum(k_r * 2 * np.pi * r * dx)
print(f"n={n} rho={rho}: theta_c={np.degrees(theta_c):.1f} deg, r_c={rc:.3f} d")
print(f"single-bounce return eta={eta:.3f} (TIR part {eta_tir:.3f}); series total {Ktot:.3f} = eta/(1-rho*eta)={eta/(1-rho*eta):.3f}")
for q in (0.5, 0.8, 0.9, 0.95):
    print(f"  {int(q*100)} % of the halo energy within r = {r[np.searchsorted(cum, q)]:.2f} d")
print(f"  fraction inside r_c: {cum[np.searchsorted(r, rc)]:.3f}")

# --- fit: K(r) ~ sum_k w_k g(r; s_k), g the unit-mass 2-D Gaussian -------------
sig = np.geomspace(0.12, 6.0, int(sys.argv[3]) if len(sys.argv) > 3 else 8)
rf = r[r <= 14]
kf = k_r[r <= 14]
A = np.stack([np.exp(-rf ** 2 / (2 * s ** 2)) / (2 * np.pi * s ** 2) for s in sig], 1)
wt = rf + 0.05                       # weight by ring area (energy), not peak
def loss(w):
    return np.sum(wt * (A @ w - kf) ** 2)
cons = [{"type": "ineq", "fun": lambda w: A @ w},                    # K_fit >= 0
        {"type": "eq", "fun": lambda w: w.sum() - 1.0}]              # unit mass
w0 = np.linalg.lstsq(A * np.sqrt(wt)[:, None], kf * np.sqrt(wt), rcond=None)[0]
res = minimize(loss, w0, constraints=cons, method="SLSQP", options={"maxiter": 2000, "ftol": 1e-14})
w = res.x
fit = A @ w
err = np.sqrt(np.sum(wt * (fit - kf) ** 2) / np.sum(wt * kf ** 2))
print(f"fit: {len(sig)} gaussians, rel energy err {err:.3f}, min {fit.min():.2e}, sum w {w.sum():.4f}")
json.dump({"n": n, "rho": rho, "sigma_over_d": sig.tolist(), "weight": w.tolist(), "rc_over_d": rc,
           "r": rf[::4].tolist(), "k": kf[::4].tolist(), "fit": fit[::4].tolist()},
          open(f"psf_n{n}_rho{rho}_{len(sig)}.json", "w"))
for s, ww in zip(sig, w):
    print(f"   sigma {s:.4f} d   weight {ww:+.5f}")


# --- free sigmas: log-sigma and weights optimised together ----------------------
MIN_RATIO = np.log(1.35)
L1_MAX = 2.0


def sigmas(p, m):
    # log sigma_0, then increments >= log 1.35: well separated by construction
    return np.exp(p[0] + np.concatenate([[0], np.cumsum(MIN_RATIO + p[1:m] ** 2)]))


def model(p, rr):
    m = len(p) // 2
    s = sigmas(p, m); ww = p[m:]
    return (np.exp(-rr[:, None] ** 2 / (2 * s[None] ** 2)) / (2 * np.pi * s[None] ** 2)) @ ww


rr2 = np.linspace(0, 16, 1600)
k2 = np.interp(rr2, r, k_r)
wt2 = rr2 + 0.05


def loss2(p):
    return np.sum(wt2 * (model(p, rr2) - k2) ** 2) / np.sum(wt2 * k2 ** 2)


best = None
M = int(sys.argv[4]) if len(sys.argv) > 4 else 5
rng = np.random.default_rng(0)
for trial in range(60):
    s0 = np.sort(np.geomspace(0.25, 8, M) * np.exp(rng.normal(0, 0.3, M)))
    inc = np.sqrt(np.maximum(np.diff(np.log(s0)) - MIN_RATIO, 1e-3))
    sp = np.concatenate([[np.log(s0[0])], inc])
    Ainit = np.exp(-rr2[:, None] ** 2 / (2 * sigmas(sp, M)[None] ** 2)) / (2 * np.pi * sigmas(sp, M)[None] ** 2)
    w_init = np.clip(np.linalg.lstsq(Ainit * np.sqrt(wt2)[:, None], k2 * np.sqrt(wt2), rcond=None)[0], -0.5, 1.5)
    p0 = np.concatenate([sp, w_init])
    cons2 = [{"type": "ineq", "fun": lambda p: model(p, rr2) + 1e-7},
             {"type": "ineq", "fun": lambda p: L1_MAX - np.sum(np.sqrt(p[M:] ** 2 + 1e-10))},
             {"type": "ineq", "fun": lambda p: np.log(12.0) - np.log(sigmas(p, M)[-1])},
             {"type": "ineq", "fun": lambda p: np.log(sigmas(p, M)[0]) - np.log(0.1)},
             {"type": "eq", "fun": lambda p: p[M:].sum() - 1.0}]
    rs = minimize(loss2, p0, constraints=cons2, method="SLSQP", options={"maxiter": 4000, "ftol": 1e-15})
    if rs.success and (best is None or rs.fun < best.fun):
        best = rs
p = best.x
print(f"free fit, {M} gaussians: rel energy err {np.sqrt(best.fun):.3f}, min {model(p, rr2).min():.2e}, "
      f"sum|w| {np.abs(p[M:]).sum():.3f}")
for s, ww in zip(sigmas(p, M), p[M:]):
    print(f"   sigma {s:.4f} d   weight {ww:+.6f}")


def esf(prof_r, prof_k):
    """Edge response: the halo energy beyond x from a half-plane source (Abel projection)."""
    kk = np.interp(Rr, prof_r, prof_k, right=0)
    lsf = kk.sum(0) * dx
    return np.cumsum(lsf[::-1])[::-1] * dx


e_true = esf(r, k_r)
e_fit = esf(rr2, model(p, rr2))
for q in (0.25, 0.5, 1.0, 1.5, 1.83, 2.2, 3, 4, 6, 8):
    i = np.searchsorted(x, q)
    print(f"   ESF at {q:5.2f} d: true {e_true[i]:.4f}  fit {e_fit[i]:.4f}")
json.dump({"n": n, "rho": rho, "sigma_over_d": sigmas(p, M).tolist(), "weight": p[M:].tolist(),
           "x": x[N // 2::8].tolist(), "esf": e_true[N // 2::8].tolist(), "esf_fit": e_fit[N // 2::8].tolist(),
           "r": rr2[::5].tolist(), "k": k2[::5].tolist(), "kfit": model(p, rr2)[::5].tolist()},
          open(f"psf_free_n{n}_rho{rho}_{M}.json", "w"))
