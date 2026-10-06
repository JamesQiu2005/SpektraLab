"""Is grain / halation the same on the three channels of an identical-channel negative? Flat grey field. MEASURED."""
import numpy as np, common as c
eng = c.engine()
img = np.full((256, 256, 3), 0.184, np.float32)
def go(tag, d):
    rgba, p = c.render(eng, img, {"film_stock": "standin_bw_n03", **d})
    f = c.to_float(rgba)[32:-32, 32:-32]
    print(f"{tag:40s} std R {f[...,0].std():.5f} G {f[...,1].std():.5f} B {f[...,2].std():.5f}   std(R-G) {(f[...,0]-f[...,1]).std():.5f} std(B-G) {(f[...,2]-f[...,1]).std():.5f}  mean {f.mean((0,1)).round(4)}  grain_active={p.get('grain_active')}")
for film_fmt in (35,):
    go("scan_film grain off", dict(scan_film=True, grain_active=False))
    go("scan_film grain on", dict(scan_film=True, grain_active=True))
    go("scan_film grain on, sublayers off", dict(scan_film=True, grain_active=True, grain_sublayers_active=False))
    go("DI grain on", dict(digital_intermediate=True, grain_active=True))
    go("endura solved grain on", dict(print_stock="kodak_portra_endura", m_filter_neutral=72.4, y_filter_neutral=85.3, grain_active=True))
    go("vc paper grain on", dict(print_stock="standin_vc_paper", m_filter_neutral=20, y_filter_neutral=60, grain_active=True))
    go("portra400 scan grain on (colour ref)", dict(film_stock="kodak_portra_400", scan_film=True, grain_active=True))
# halation: a bright bar on dark ground
img2 = np.full((256, 256, 3), 0.01, np.float32); img2[:, 120:136] = 8.0
for tag, d in (("halation on", dict(halation_active=True)), ("halation off", dict(halation_active=False))):
    rgba, p = c.render(eng, img2, dict(film_stock="standin_bw_n03", scan_film=True, **d))
    f = c.to_float(rgba)[128]
    print(f"{tag}: row profile at x=100..118 step 6  R {f[100:119:6,0].round(4)}  G {f[100:119:6,1].round(4)}  B {f[100:119:6,2].round(4)}  max|R-B| on row {np.abs(f[:,0]-f[:,2]).max():.4f}")
