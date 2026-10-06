"""Runs against the SCRATCH engine build (engine_scratch/, = repo source + scratch_engine.patch, which
only adds getenv overrides read in grain_realise / the stream table). Nothing here is in the product.
1 identity: no overrides -> bit-identical to the shipped dylib
2 equal Philox streams per channel (the 'one emulsion' fix) with and without equal scale/uniformity
3 particle area that gives RMS 17 (single layer), verified
4 noise power spectra: pixel pitch, grain blur, dye-cloud blur
"""
import os, json
import numpy as np
from glib import *
import model as M, standin
from PIL import Image

DY = HERE / "engine_scratch/build/libspektrafilm_engine.dylib"
out = {}
ENVS = ["SPK_GRAIN_EQUAL_STREAMS", "SPK_GRAIN_AREA", "SPK_GRAIN_SCALE", "SPK_GRAIN_UNI", "SPK_GRAIN_BLUR", "SPK_GRAIN_DYE", "SPK_GRAIN_LAYERS"]
def env(**kw):
    for k in ENVS: os.environ.pop(k, None)
    for k, v in kw.items(): os.environ["SPK_GRAIN_" + k] = str(v)

base, prof = standin.build(3.0)
pr = [make_probe(base, c, name=f"{base}_p{c}") for c in range(3)] + [make_probe(base, "sum", name=f"{base}_psum")]
W = white_of()

def level_for(e, target):
    levels = np.geomspace(0.002, 3000, 40)
    dd = np.array([-np.log10(render_lin(e, pr[1], l, 64, 100.0, grain_active=False)[..., 1].mean() / W) / PROBE_K for l in levels])
    return float(np.exp(np.interp(target, dd, np.log(levels))))

def crop_png(name, f, lo, hi, z=3):
    a = np.clip((f - lo) / (hi - lo), 0, 1)
    a = (255 * a[:160, :160]).astype(np.uint8) if a.ndim == 2 else (255 * a[:160, :160, :]).astype(np.uint8)
    Image.fromarray(a).resize((160 * z, 160 * z), Image.NEAREST).save(HERE / name)

env()
with Engine(resources=RES) as e0:
    lvl = level_for(e0, 1.0)
    ship = render_lin(e0, pr[1], lvl, 512, 8.0, grain_sublayers_active=False)
with Engine(dylib=DY, resources=RES) as e:
    mine = render_lin(e, pr[1], lvl, 512, 8.0, grain_sublayers_active=False)
    out["identity_max_abs_diff_16bit"] = float(np.abs(ship - mine).max() * 65535)
    print("1 identity: max |shipped - scratch| in 16-bit counts:", out["identity_max_abs_diff_16bit"])

    # 2 ---------------------------------------------------------------
    for label, kw in (("default streams", {}), ("equal streams", dict(EQUAL_STREAMS=1)),
                      ("equal streams + equal scale 1.6 + equal uniformity 0.99", dict(EQUAL_STREAMS=1, SCALE=1.6, UNI=0.99))):
        for sub in (False, True):
            env(**kw)
            f = [density(e, pr[c], lvl, 1024, 6.0, W, grain_sublayers_active=sub) for c in range(3)]
            s3 = density(e, pr[3], lvl, 1024, 6.0, W, grain_sublayers_active=sub)
            cc = np.corrcoef(np.stack([a.ravel() for a in f]))
            r = dict(path="sublayers" if sub else "single", corr_RG=float(cc[0, 1]), corr_RB=float(cc[0, 2]), corr_GB=float(cc[1, 2]),
                     max_abs_R_minus_G=float(np.abs(f[0] - f[1]).max()), max_abs_B_minus_G=float(np.abs(f[2] - f[1]).max()),
                     rms48=[1000 * aperture_sigma(a, 6.0) for a in f], rms48_sum3=1000 * aperture_sigma(s3, 6.0))
            out.setdefault("2_streams", {})[label + (" / sublayers" if sub else " / single")] = r
            print("2", label, json.dumps(r))
            if not sub:
                # colour of the grain if the three channels were three dyes: RGB composite of the density noise
                rgb = np.stack([a - a.mean() for a in f], axis=-1)
                crop_png(f"crop_rgbnoise_{'equal' if kw else 'independent'}{'_eqparams' if 'SCALE' in kw else ''}.png", rgb, -0.25, 0.25)

    # 3 ---------------------------------------------------------------
    rows = []
    for dmax in (2.5, 3.0, 3.5):
        b2, p2 = standin.build(dmax)
        q = make_probe(b2, 1, name=f"{b2}_p1")
        for u in (0.99, 0.97):
            a_selwyn = 0.017 ** 2 * A48 / (1.03 * (dmax + 0.03) * (1 - u * 1.03 / (dmax + 0.03)))
            _, ga = M.kernel_gain(6.0); a_6um = a_selwyn * (np.sqrt(36.0 / A48) / ga) ** 2
            env(AREA=a_6um, SCALE=1.0, UNI=u)
            lv = None
            levels = np.geomspace(0.002, 3000, 40)
            dd = np.array([-np.log10(render_lin(e, q, l, 64, 100.0, grain_active=False)[..., 1].mean() / W) / PROBE_K for l in levels])
            lv = float(np.exp(np.interp(1.0, dd, np.log(levels))))
            d = density(e, q, lv, 1024, 6.0, W, grain_sublayers_active=False)
            rows.append(dict(dmax=dmax, u=u, area_eff_selwyn=a_selwyn, area_eff_for_17_at_6um=a_6um,
                             particle_area_um2_if_scale_1p6=a_6um / 1.6, measured_rms48_at_6um=1000 * aperture_sigma(d, 6.0),
                             default_G_rms_selwyn=float(M.rms_from_var(M.var_simple(dmax, 1, 1.0, 6.0), 6.0)),
                             grain_amount_for_17_selwyn=17 / float(M.rms_from_var(M.var_simple(dmax, 1, 1.0, 6.0), 6.0))))
            print("3", json.dumps(rows[-1]))
    out["3_area"] = rows

    # 4 ---------------------------------------------------------------
    spectra = {}
    lvl = level_for(e, 1.0)
    cases = [("single px12", False, 12.0, 1024, {}), ("single px6", False, 6.0, 1024, {}), ("single px2", False, 2.0, 2048, {}),
             ("single px2 blur0", False, 2.0, 2048, dict(BLUR=0)),
             ("sublayers px2 (dye clouds 1.0 um, default)", True, 2.0, 2048, {}),
             ("sublayers px2 dye0", True, 2.0, 2048, dict(DYE=0)),
             ("sublayers px2 dye0 blur0", True, 2.0, 2048, dict(DYE=0, BLUR=0)),
             ("sublayers px2 dye3", True, 2.0, 2048, dict(DYE=3.0)),
             ("sublayers px6", True, 6.0, 1024, {}), ("sublayers px6 dye0", True, 6.0, 1024, dict(DYE=0))]
    for name, sub, px, n, kw in cases:
        env(**kw)
        frame_n = n
        frame = None
        import glib
        d = None
        out_lin = render_lin(e, pr[1], lvl, frame_n, px, grain_sublayers_active=sub)[..., 1]
        d = (-np.log10(np.maximum(deunsharp(out_lin), 1e-6) / W) / PROBE_K)[16:-16, 16:-16]
        f, w = nps_radial(d, px)
        spectra[name] = dict(px=px, f=f.tolist(), W=w.tolist(), sigma_px=float(d.std()), rms48=1000 * aperture_sigma(d, px),
                             f_half=float(np.interp(0.5 * w[:3].mean(), w[::-1], f[::-1])) if w[-1] < 0.5 * w[:3].mean() else None)
        print("4 %-45s sigma_px %.4f rms48 %.2f  W(0) %.3f um^2  half-power at %s c/mm" % (name, d.std(), spectra[name]["rms48"], w[:3].mean(), spectra[name]["f_half"]))
        if px == 2.0:
            crop_png("crop_" + name.split(" (")[0].replace(" ", "_") + ".png", d, 0.4, 1.6)
    out["4_nps"] = spectra
env()
json.dump(out, open(HERE / "out_t4.json", "w"), indent=1)
