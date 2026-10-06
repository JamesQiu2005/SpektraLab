"""(c) STAND-IN variable-contrast silver paper in the existing 3-channel paper schema, zero engine change.
Does the Enlarger's M/Y pack act as a grade control, and is the print neutral? MEASURED on a fine grey ramp."""
import json, numpy as np, common as c
eng = c.engine()
stops = np.arange(-7, 7.01, 0.25)
img = c.ramp(stops, patch=12)
res = {}
def run(film, paper, m, y, extra=None):
    d = dict(film_stock=film, print_stock=paper, m_filter_neutral=m, y_filter_neutral=y); d.update(extra or {})
    rgba, p = c.render(eng, img, d)
    lin = c.srgb_decode(c.patches(rgba, n=len(stops)))
    L = c.lab(lin)
    Y = lin @ c.M_SRGB[1]
    return L, -np.log10(np.maximum(Y, 1e-6)), rgba
def metrics(D, L):
    """Print reflection density vs scene stops. ISO-R-like: scene log range between D=Dmin+0.04 and 0.9*(Dmax-Dmin)+Dmin,
    converted to negative density range with the stand-in film's slope is not needed: report in scene stops."""
    dmin, dmax = D.min(), D.max()
    s = stops[::-1]; d = D[::-1]              # density rises as scene gets darker
    lo = np.interp(dmin + 0.04, d, s); hi = np.interp(dmin + 0.9 * (dmax - dmin), d, s)
    mid = np.interp(0.0, stops, D)
    g = np.gradient(D, stops * np.log10(2)); 
    return dict(dmin=float(dmin), dmax=float(dmax), range_stops=float(lo - hi), D_mid=float(mid),
                max_gradient=float(np.abs(g).max()), max_C=float(np.hypot(L[:, 1], L[:, 2]).max()))
print("film standin_bw_n03 -> standin_vc_paper; pack (M, Y) in CC")
for m, y in ((0, 170), (0, 120), (0, 60), (20, 60), (40, 40), (65, 55), (60, 20), (60, 0), (120, 0), (170, 0)):
    L, D, rgba = run("standin_bw_n03", "standin_vc_paper", m, y)
    r = metrics(D, L); res[f"M{m}Y{y}"] = r
    print(f"  M{m:3d} Y{y:3d}  Dmin {r['dmin']:.2f} Dmax {r['dmax']:.2f}  scene range {r['range_stops']:.2f} st  D(mid grey) {r['D_mid']:.2f}  peak gradient {r['max_gradient']:.2f}  max C*ab {r['max_C']:.2f}")
print("the two existing sliders as a grade control: neutral pack M60 Y60, filter_shift_scale 60")
for ms, ys in ((-1, 1), (-0.5, 0.5), (0, 0), (0.5, -0.5), (1, -1)):
    L, D, rgba = run("standin_bw_n03", "standin_vc_paper", 60, 60, dict(m_filter_shift=ms, y_filter_shift=ys, filter_shift_scale=60))
    r = metrics(D, L); res[f"shift m{ms} y{ys}"] = r
    print(f"  m_shift {ms:+.1f} y_shift {ys:+.1f}  scene range {r['range_stops']:.2f} st  D(mid) {r['D_mid']:.2f}  peak gradient {r['max_gradient']:.2f}  max C*ab {r['max_C']:.2f}")
print("same sliders on a COLOUR paper (Endura, hand-solved M72.4 Y85.3), filter_shift_scale 40")
for ms, ys in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
    L, D, rgba = run("standin_bw_n03", "kodak_portra_endura", 72.4, 85.3, dict(m_filter_shift=ms, y_filter_shift=ys, filter_shift_scale=40))
    r = metrics(D, L); i0 = list(stops).index(0.0); res[f"endura shift m{ms} y{ys}"] = dict(r, a=float(L[i0, 1]), b=float(L[i0, 2]))
    print(f"  m_shift {ms:+.0f} y_shift {ys:+.0f}  scene range {r['range_stops']:.2f} st  peak gradient {r['max_gradient']:.2f}  mid grey a* {L[i0,1]:+.1f} b* {L[i0,2]:+.1f}")
print("image tone lives in the paper profile: warm stand-in (silver slope 0.5, cream base)")
L, D, rgba = run("standin_bw_n03", "standin_vc_paper_warm", 40, 40)
for s_ in (-3, 0, 3):
    i = list(stops).index(float(s_)); print(f"  stop {s_:+d}: L* {L[i,0]:.1f} a* {L[i,1]:+.2f} b* {L[i,2]:+.2f}")
res["warm"] = L.tolist()
print("film silver slope does not tint a silver print (n00 / n06 on VC paper, M40 Y40):")
for f in ("standin_bw_n00", "standin_bw_n06"):
    L, D, _ = run(f, "standin_vc_paper", 40, 40); r = metrics(D, L); res[f + "|vc"] = r
    print(f"  {f}: max C*ab {r['max_C']:.3f}  scene range {r['range_stops']:.2f} st  D(mid) {r['D_mid']:.2f}")
json.dump(res, open(c.OUT / "vc_paper.json", "w"), indent=1)
