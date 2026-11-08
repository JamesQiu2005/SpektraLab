"""Usage: python3 engine/tests/halation_psf_fit.py [--write-json DIR]

The back-reflection halo of a colour negative with no anti-halation layer, per
sensitive layer, integrated and fitted as the four-Gaussian mixtures in
`engine/src/core/halation_psf.hpp`. Prints the C++ tables; rerun it rather than
editing those numbers by hand.

Geometry (lengths in units of the base thickness d): light leaves the emulsion
into the base at polar angle theta and comes back to it at r = 2 tan(theta).

* **Rear face.** Fresnel reflectance from n = 1.48 (cellulose triacetate) into
  air, rising to 1 past the critical angle theta_c = asin(1/n) = 42.5 deg (total
  internal reflection).
* **Pressure plate.** Inside theta_c about 96 % of the light *leaves* the base;
  a camera's pressure plate sends some of it back (CineStill's own account of
  its halation names "base and pressure plate"). Plate reflectance R_p, the
  two crossings of the face, and the plate-face interreflection give
  R_eff = R_f + (1 - R_f)^2 R_p / (1 - R_f R_p). It fills the gap inside the
  ring: a point light shows a disc with a brighter rim, not a donut.
* **One bounce,** Lambertian light into the base:
  E_c(r) = R_eff(theta) cos^4(theta) / (4 pi) * A_c(theta).
* **Path absorption, per layer** (after GPT Astra's study, 2026-10-23, which
  wrote the kernel as Fresnel x exp(-mu path)): the light returning to the green
  layer crosses the red one -- and its coloured cyan masking coupler -- at the
  slant theta, twice, and blue crosses red, green and the yellow filter, so
  A_c(theta) = exp(-tau_c (1/cos(theta) - 1)) relative to normal incidence (the
  strength holds the normal-incidence part). Red, bottom-most, crosses nothing:
  tau_r = 0. This is what makes green's halo narrower than red's, which every
  CineStill scan shows (red/green half-height radius 1.49-2.65 on five lights,
  Astra's `measurements.json`), whatever the source's brightness.
* plus the unscattered 15 % (the lens's cone at f/2.8, refracted, Fresnel);
* **re-scatter:** the emulsion sends rho = 0.35 back down, Lambertian again, so
  K = h + rho h*h + ... (an FFT);
* softened by the emulsion's own thickness (sigma 0.08 d), unit mass.

The fit: four Gaussians per layer with signed weights, non-negative everywhere,
sum(|w|) <= 2 and sigmas at least 1.35x apart, because the GPU blur's IIR
branch is an approximation and a mixture that cancels large weights would
amplify its error (an unconstrained fit wanted +56/-113/+58).
"""
import json, sys
import numpy as np
from scipy.optimize import minimize

N_BASE = 1.48
RHO = 0.35
SPEC = 0.15
F_NUMBER = 2.8
SIGMA_E = 0.08
R_PLATE = 0.10
TAU = {"red": 0.0, "green": 1.2, "blue": 3.0}

theta_c = np.arcsin(1 / N_BASE)


def fresnel_internal(theta):
    s = N_BASE * np.sin(theta)
    out = np.ones_like(theta)
    ok = s < 1
    ti, tt = theta[ok], np.arcsin(s[ok])
    rs = ((N_BASE * np.cos(ti) - np.cos(tt)) / (N_BASE * np.cos(ti) + np.cos(tt))) ** 2
    rp = ((N_BASE * np.cos(tt) - np.cos(ti)) / (N_BASE * np.cos(tt) + np.cos(ti))) ** 2
    out[ok] = 0.5 * (rs + rp)
    return out


def r_eff(theta):
    rf = fresnel_internal(theta)
    return rf + (1 - rf) ** 2 * R_PLATE / (1 - rf * R_PLATE)


N, L = 2048, 40.0
dx = L / N
x = (np.arange(N) - N // 2) * dx
X, Y = np.meshgrid(x, x)
Rr = np.hypot(X, Y)
th = np.arctan(Rr / 2)
G = np.exp(-(Rr ** 2) / (2 * SIGMA_E ** 2))
G /= G.sum()
th_l = np.arcsin(np.sin(np.arctan(1 / (2 * F_NUMBER))) / N_BASE)
r_l = 2 * np.tan(th_l)


def kernel(tau):
    att = np.exp(-tau * (1 / np.cos(th) - 1))
    h_diff = r_eff(th) * np.cos(th) ** 4 / (4 * np.pi) * att
    h_spec = np.where(Rr <= r_l, r_eff(np.array([0.0]))[0] / (np.pi * r_l ** 2), 0.0)
    h = (1 - SPEC) * h_diff + SPEC * h_spec
    eta = h.sum() * dx * dx
    Hf = np.fft.fft2(np.fft.ifftshift(h)) * dx * dx
    K = np.real(np.fft.fftshift(np.fft.ifft2(Hf / (1 - RHO * Hf)))) / (dx * dx)
    K = np.real(np.fft.fftshift(np.fft.ifft2(np.fft.fft2(np.fft.ifftshift(K)) * np.fft.fft2(np.fft.ifftshift(G)))))
    total = K.sum() * dx * dx
    return K / total, eta, total


MIN_RATIO, L1_MAX, M = np.log(1.35), 2.0, 4


def sigmas(p):
    return np.exp(p[0] + np.concatenate([[0], np.cumsum(MIN_RATIO + p[1:M] ** 2)]))


def model(p, rr):
    s = sigmas(p)
    return (np.exp(-rr[:, None] ** 2 / (2 * s[None] ** 2)) / (2 * np.pi * s[None] ** 2)) @ p[M:]


def fit(r, k):
    rr = np.linspace(0, 16, 1600)
    kk = np.interp(rr, r, k)
    wt = rr + 0.05
    loss = lambda p: np.sum(wt * (model(p, rr) - kk) ** 2) / np.sum(wt * kk ** 2)
    cons = [{"type": "ineq", "fun": lambda p: model(p, rr) + 1e-7},
            {"type": "ineq", "fun": lambda p: L1_MAX - np.sum(np.sqrt(p[M:] ** 2 + 1e-10))},
            {"type": "ineq", "fun": lambda p: np.log(12.0) - np.log(sigmas(p)[-1])},
            {"type": "ineq", "fun": lambda p: np.log(sigmas(p)[0]) - np.log(0.1)},
            {"type": "eq", "fun": lambda p: p[M:].sum() - 1.0}]
    rng = np.random.default_rng(0)
    best = None
    for _ in range(60):
        s0 = np.sort(np.geomspace(0.25, 8, M) * np.exp(rng.normal(0, 0.3, M)))
        inc = np.sqrt(np.maximum(np.diff(np.log(s0)) - MIN_RATIO, 1e-3))
        sp = np.concatenate([[np.log(s0[0])], inc])
        A = np.exp(-rr[:, None] ** 2 / (2 * sigmas(sp)[None] ** 2)) / (2 * np.pi * sigmas(sp)[None] ** 2)
        w0 = np.clip(np.linalg.lstsq(A * np.sqrt(wt)[:, None], kk * np.sqrt(wt), rcond=None)[0], -0.5, 1.5)
        rs = minimize(loss, np.concatenate([sp, w0]), constraints=cons, method="SLSQP",
                      options={"maxiter": 4000, "ftol": 1e-15})
        if rs.success and (best is None or rs.fun < best.fun):
            best = rs
    return best.x, np.sqrt(best.fun), rr, kk


def esf(prof_r, prof_k):
    kk = np.interp(Rr, prof_r, prof_k, right=0)
    return np.cumsum((kk.sum(0) * dx)[::-1])[::-1] * dx


def main():
    out_dir = sys.argv[sys.argv.index("--write-json") + 1] if "--write-json" in sys.argv else None
    r = x[N // 2:]
    rc = 2 * np.tan(theta_c)
    print(f"n={N_BASE} rho={RHO} R_plate={R_PLATE}: theta_c={np.degrees(theta_c):.1f} deg, r_c={rc:.3f} d")
    tables = {}
    for layer, tau in TAU.items():
        K, eta, total = kernel(tau)
        k_r = K[N // 2, N // 2:]
        cum = np.cumsum(k_r * 2 * np.pi * r * dx)
        inner = k_r[(r > 0.5) & (r < 1.2)].mean()
        ring = k_r[(r > 1.6) & (r < 2.6)].max()
        q = {f"{int(f * 100)}%": round(float(r[np.searchsorted(cum, f)]), 2) for f in (0.5, 0.9)}
        p, err, rr, kk = fit(r, k_r)
        e_true, e_fit = esf(r, k_r), esf(rr, model(p, rr))
        worst = max(abs(e_true[np.searchsorted(x, v)] - e_fit[np.searchsorted(x, v)]) for v in (0.5, 1, 1.83, 3, 4))
        print(f"{layer:5s} tau={tau}: return {total:.3f} of the light into the base, energy radii {q}, "
              f"disc/ring {inner / ring:.2f}; fit rel err {err:.3f}, edge-response err <= {worst:.4f}")
        tables[layer] = (sigmas(p), p[M:])
        if out_dir:
            json.dump({"tau": tau, "r": r[::8].tolist(), "k": k_r[::8].tolist(),
                       "kfit": np.interp(r[::8], rr, model(p, rr)).tolist(),
                       "x": x[N // 2::8].tolist(), "esf": e_true[N // 2::8].tolist(),
                       "esf_fit": e_fit[N // 2::8].tolist()},
                      open(f"{out_dir}/psf_{layer}.json", "w"))
    print("\n// sigma / d, per component, per layer (red, green, blue)")
    for k in range(M):
        print("    {" + ", ".join(f"{tables[l][0][k]:.6f}" for l in TAU) + "},")
    print("// weight")
    for k in range(M):
        print("    {" + ", ".join(f"{tables[l][1][k]:+.6f}" for l in TAU) + "},")


if __name__ == "__main__":
    main()
