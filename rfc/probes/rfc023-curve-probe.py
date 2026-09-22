# rfc023-curve-probe.py -- RFC-023's curve: the m-family, the example mappings
# of §6, and the derivative tables of §7.
#
# Analysis only. Nothing here is product code and nothing in the build or the
# app runs it (CLAUDE.md: no Python at build or run time). It reproduces every
# number in RFC-023 §1, §6 and §7.3 so they can be re-derived rather than
# trusted:   python3 rfc/probes/rfc023-curve-probe.py
#
# The profile statistics in §7.3 and §8.2 come from a separate reading of
# engine/resources/profiles/*.json -- density_curves against log_exposure,
# first and second differences, converted to per-stop by log10(2) -- and are
# reproduced by --profiles.
import math, sys

STOP = math.log10(2.0)

# --- the curve -------------------------------------------------------------
# g_m(D) = D * H / (H^m + D^m)^(1/m): the smooth minimum of D and H.
# g(0)=0, g'(0)=1, contact of order m with the identity, g -> H, g' > 0.

def g(D, H, m):
    if D <= 0.0: return 0.0
    return D * H / (H**m + D**m) ** (1.0 / m)

def gp(D, H, m):
    if D <= 0.0: return 1.0
    s = D / H
    return (1.0 + s**m) ** (-(m + 1.0) / m)

def gpp(D, H, m):
    if D <= 0.0:
        return 0.0 if m > 1.0 else -2.0 / H          # m=1 has a step here
    s = D / H
    return -(m + 1.0) / H * s**(m - 1.0) * (1.0 + s**m) ** (-(2.0 * m + 1.0) / m)

def curv_peak(H, m):
    """max |g''| and where it sits. For m>1 the peak is at D/H = ((m-1)/(m+2))^(1/m)."""
    if m <= 1.0: return 2.0 / H, 0.0
    s = ((m - 1.0) / (m + 2.0)) ** (1.0 / m)
    return abs(gpp(s * H, H, m)), s * H

def f(E, P):
    Kh, Hh, Ks, Hs, m = P
    if E > Kh: return Kh + g(E - Kh, Hh, m)
    if E < Ks: return Ks - g(Ks - E, Hs, m)
    return E

def fp(E, P):
    Kh, Hh, Ks, Hs, m = P
    if E > Kh: return gp(E - Kh, Hh, m)
    if E < Ks: return gp(Ks - E, Hs, m)
    return 1.0

def fpp(E, P):
    Kh, Hh, Ks, Hs, m = P
    if E > Kh: return gpp(E - Kh, Hh, m)
    if E < Ks: return -gpp(Ks - E, Hs, m)
    return 0.0

def delta_m2(D, H):
    """The form the kernel evaluates (§5.6): f(E)-E, rationalised so it does
    not cancel near the knee, and exactly 0.0 inside the core."""
    if D <= 0.0: return 0.0
    r = math.sqrt(H * H + D * D)
    return -(D * D * D) / (r * (H + r))

# --- the fit (§9.2) --------------------------------------------------------

def solve_K(a, C, N, m):
    """Knee K such that f(a) = a - N with the ceiling pinned at C (H = C-K).
    f(a) is strictly decreasing in K, so this is bracketed and cannot fail.
    m=1 is closed form; m>1 is bisection seeded from it."""
    t = a - N
    if N <= 0.0: return None
    if t > C:  raise ValueError("pull-back too small: %.3f would land past the boundary %.3f" % (t, C))
    K1 = t - math.sqrt((a - t) * (C - t))            # the m=1 closed form
    if abs(m - 1.0) < 1e-12: return K1
    lo, hi = K1 - 40.0, min(t, C) - 1e-9
    for _ in range(200):
        mid = 0.5 * (lo + hi)
        if mid + g(a - mid, C - mid, m) > t: hi = mid
        else: lo = mid
    return 0.5 * (lo + hi)

def fit(scene, medium, Nh, Ns, m):
    Kh = solve_K(scene[1], medium[1], Nh, m); Hh = medium[1] - Kh
    Ks = -solve_K(-scene[0], -medium[0], Ns, m); Hs = -medium[0] + Ks
    return (Kh, Hh, Ks, Hs, m)


# --- §7.4: the families, compared at an equal landing point ----------------

BRANCHES = [
    ("g_m, m=1 (hyperbola)",  1, lambda D, H: D * H / (H + D),
                                 lambda D, H: (H / (H + D)) ** 2),
    ("H(1-exp(-D/H))",        1, lambda D, H: H * (1.0 - math.exp(-D / H)),
                                 lambda D, H: math.exp(-D / H)),
    ("g_m, m=2  RECOMMENDED", 2, lambda D, H: D * H / math.hypot(H, D),
                                 lambda D, H: H ** 3 / (H * H + D * D) ** 1.5),
    ("H*tanh(D/H)",           2, lambda D, H: H * math.tanh(D / H),
                                 lambda D, H: 1.0 / math.cosh(D / H) ** 2),
    ("g_m, m=3",              3, lambda D, H: D * H / (H ** 3 + D ** 3) ** (1 / 3),
                                 lambda D, H: (1.0 + (D / H) ** 3) ** (-4 / 3)),
]

def branch_table(a=8.0, C=4.2, t=3.95):
    print("%-24s %4s %8s %8s %9s %9s %10s %11s"
          % ("branch", "ord", "K_h", "H_h", "f'(+6)", "f'(+8)", "f'(+16)", "max|f''|"))
    for name, order, gf, gpf in BRANCHES:
        lo, hi = -60.0, t - 1e-9                       # f(a) is decreasing in K
        for _ in range(400):
            K = 0.5 * (lo + hi)
            if K + gf(a - K, C - K) > t: hi = K
            else: lo = K
        K = 0.5 * (lo + hi); H = C - K
        mx, D = 0.0, 1e-6
        while D < 60.0:                                 # numeric max |f''|
            mx = max(mx, abs((gpf(D + 1e-4, H) - gpf(D - 1e-4, H)) / 2e-4))
            D += 0.002
        print("%-24s %4d %+8.3f %8.3f %9.5f %9.5f %10.6f %11.3f"
              % (name, order, K, H, gpf(6 - K, H), gpf(8 - K, H), gpf(16 - K, H), mx))

# --- reports ---------------------------------------------------------------

ROWS = [-16, -10, -7, -5, -4, -3, -2, 0, 2, 3, 4, 5, 6, 7, 8, 10, 16]

def report(title, scene, medium, Nh, Ns, m):
    P = fit(scene, medium, Nh, Ns, m)
    Kh, Hh, Ks, Hs, m = P
    c, d = curv_peak(Hh, m)
    print("=" * 74); print(title)
    print("  scene %s -> medium %s   m=%.1f   pull-back %.2f / %.2f stops"
          % (scene, medium, m, Nh, Ns))
    print("  K_h=%+.3f H_h=%.3f ceiling=%+.3f | K_s=%+.3f H_s=%.3f floor=%+.3f"
          % (Kh, Hh, Kh + Hh, Ks, Hs, Ks - Hs))
    print("  identity core [%+.2f,%+.2f] = %.2f stops%s"
          % (Ks, Kh, Kh - Ks, "" if Ks < Kh else "   <-- KNEES CROSS, INVALID"))
    print("  peak |f''| (highlight) = %.3f /stop^2, %.2f stops past the knee" % (c, d))
    print("  %6s %8s %8s %9s" % ("E", "f(E)", "f'", "f''"))
    for E in ROWS:
        print("  %+6.1f %+8.3f %8.4f %+9.4f" % (E, f(E, P), fp(E, P), fpp(E, P)))
    return P

def main():
    print("### §1: the m sweep at a FIXED landing point (f(+8) = +3.950)")
    print("%5s %9s %8s %8s %9s %11s %8s" % ("m", "K_h", "H_h", "core", "f'(+8)", "peak|f''|", "at"))
    for m in (1.0, 1.5, 2.0, 2.5, 3.0, 4.0):
        K = solve_K(8.0, 4.2, 4.05, m); H = 4.2 - K
        Ks = -solve_K(7.0, 4.3, 2.95, m)
        c, d = curv_peak(H, m)
        print("%5.1f %+9.3f %8.3f %8.2f %9.4f %11.3f %8.2f"
              % (m, K, H, K - Ks, gp(8 - K, H, m), c, d))
    print()

    report("§6.1  15 EV -> 8.5 EV (portra_400 + portra_endura)", (-7.0, 8.0), (-4.3, 4.2), 4.05, 2.95, 2.0)
    report("§6.2  15 EV -> 12 EV (neutral_wide_060)",            (-7.0, 8.0), (-6.0, 6.0), 2.25, 1.25, 2.0)
    report("§6.3  12 EV -> 8.5 EV (well-exposed scene)",         (-5.5, 6.5), (-4.3, 4.2), 2.55, 1.45, 2.0)

    print("=" * 74)
    print("§6.4  asymmetry: the two sliders share one budget")
    print("      material bound: N_h >= 3.80, N_s >= 2.70")
    print("%5s %5s | %8s %8s %6s | %8s %8s | %9s %9s" %
          ("N_h", "N_s", "K_h", "K_s", "core", "f(+8)", "f(-7)", "f'(+8)", "f'(-7)"))
    for Nh, Ns in [(3.90, 2.80), (4.05, 2.95), (4.50, 2.95), (4.05, 3.40), (4.50, 3.40)]:
        P = fit((-7.0, 8.0), (-4.3, 4.2), Nh, Ns, 2.0)
        cross = "" if P[2] < P[0] else "   <-- knees cross, INVALID"
        print("%5.2f %5.2f | %+8.3f %+8.3f %6.2f | %+8.3f %+8.3f | %9.4f %9.4f%s"
              % (Nh, Ns, P[0], P[2], P[0] - P[2], f(8, P), f(-7, P), fp(8, P), fp(-7, P), cross))

    print()
    print("=" * 74)
    print("§5.6  the kernel's delta form is exactly zero in the core")
    P = fit((-7.0, 8.0), (-4.3, 4.2), 4.05, 2.95, 2.0)
    for E in (-1.0, 0.0, 1.0, P[0]):
        D = max(E - P[0], 0.0)
        print("  E=%+6.3f  D=%.6f  delta=%r  (0.0 means k == exp2(EV_film) bit for bit)"
              % (E, D, delta_m2(D, P[1])))

    print()
    print("=" * 74)
    print("§7.4  every branch family fitted to the SAME landing point (f(+8)=+3.950,")
    print("      ceiling +4.200), so shape is compared and not strength.")
    branch_table()

def profiles():
    import json, os
    root = os.path.join(os.path.dirname(__file__), "..", "..", "engine", "resources", "profiles")
    print("%-26s %3s %8s %10s %10s" % ("profile", "ch", "Dmax", "peak D/st", "max|D''|"))
    for name in ("kodak_portra_400", "kodak_ektar_100", "kodak_portra_endura", "kodak_endura_premier"):
        d = json.load(open(os.path.join(root, name + ".json")))["data"]
        x, curves = d["log_exposure"], d["density_curves"]
        h = x[1] - x[0]; n = len(x)
        for ch in range(3):
            y = [r[ch] for r in curves]
            d1 = max((y[min(i+1,n-1)] - y[max(i-1,0)]) / ((min(i+1,n-1) - max(i-1,0)) * h) for i in range(n))
            d2 = max(abs((y[min(i+1,n-1)] - 2*y[i] + y[max(i-1,0)]) / (h*h)) for i in range(n))
            print("%-26s %3d %8.3f %10.4f %10.4f" % (name, ch, max(y), d1*STOP, d2*STOP*STOP))

if __name__ == "__main__":
    (profiles if "--profiles" in sys.argv else main)()
