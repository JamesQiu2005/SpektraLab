# rfc023-engine-check.py -- RFC-023 as implemented in the engine: the gates
# HANDOFF-SCENE-LATITUDE §7 names, on one real frame, through the C ABI.
#
# Analysis only; nothing in the build or the app runs it. Needs numpy (the
# fork's .venv), this tree's dylib (`engine/build.sh dylib`) and a decoded frame:
#
#   swiftc -O rfc/probes/rfc023-decode-raw.swift -o $T/decode
#   $T/decode frame.NEF $T/scene.f32 2048                     # prints "W H"
#   python rfc/probes/rfc023-engine-check.py $T/scene.f32 W H OUTDIR [BASELINE_DYLIB]
#
# BASELINE_DYLIB is a build from before the node existed (with its own
# ../resources beside it); the bypass gate compares against it byte for byte.
import json, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(HERE / "engine" / "tests"))
from spk_ctypes import Engine, EngineError

import importlib.util
def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, HERE / "rfc" / "probes" / file)
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod
slm = _load("slm", "rfc023-slm-probe.py")
vcm = _load("vcm", "rfc024-vcm-probe.py")

# Numbers, not realisations: grain and glare are stochastic.
BASE = {"auto_exposure": True, "auto_exposure_method": "balanced",
        "grain_active": False, "glare_active": False}

def diff(a, b):
    return int(np.abs(a.astype(np.int64) - b.astype(np.int64)).max())

def main():
    scene_path, w, h, outdir = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
    baseline = Path(sys.argv[5]) if len(sys.argv) > 5 else None
    outdir.mkdir(parents=True, exist_ok=True)
    scene = slm.load_scene(scene_path, w, h)
    report = {}

    eng = Engine()
    ses = eng.open(scene, BASE)
    straight, _ = ses.render("full")

    # --- gate 1: the bypass is structural ------------------------------------
    if baseline:
        beng = Engine(dylib=baseline)
        bses = beng.open(scene, BASE)
        old, _ = bses.render("full")
        bses.close(); beng.close()
        report["bypass_vs_pre_rfc_build"] = bool(np.array_equal(old, straight))
    ses.set_params({"scene_latitude_active": True, "scene_latitude_highlight_room": 0.0,
                    "scene_latitude_shadow_room": 0.0})
    zero, _ = ses.render("full")
    report["bypass_active_zero_rooms"] = bool(np.array_equal(zero, straight))
    ses.set_params({"scene_latitude_active": False})

    # --- the Fit, as the UI would ask for it ----------------------------------
    # max_lift 8: on the RFC's night portrait the suggestion needs more than
    # the default 4 once the Fit solves for the bounded landing (P0.1 sits
    # 3.0 stops under a 7-stop medium) -- at 4 it is refused with knees_cross.
    fit = ses.scene_latitude({"max_lift": 8.0})
    report["default_lift_refusal"] = [i["code"] for i in ses.scene_latitude()["fit"]["issues"]]
    report["medium"] = {k: fit["medium"][k] for k in ("shadow_ev", "highlight_ev", "latitude_stops")}
    report["scene"] = {k: fit["scene"][k] for k in ("p0_1", "p1", "p50", "p99", "p99_9", "samples")}
    report["suggested"] = fit["suggested"]
    report["fit"] = {k: fit["fit"][k] for k in ("valid", "issues", "warnings", "core_stops", "highlight", "shadow")}
    delta = fit["fit"].get("params_delta")
    report["fit_params_delta"] = delta

    # --- refusals ---------------------------------------------------------------
    def refused(req=None, params=None):
        try:
            (ses.scene_latitude(req) if req is not None else ses.set_params(params))
            return False
        except EngineError as e:
            return str(e)
    report["refuses_crossed_knees"] = refused(params={
        "scene_latitude_active": True, "scene_latitude_highlight_knee": -1.0,
        "scene_latitude_highlight_room": 2.0, "scene_latitude_shadow_knee": 1.0,
        "scene_latitude_shadow_room": 2.0})
    ses.set_params({"scene_latitude_active": False, "scene_latitude_highlight_knee": 2.0,
                    "scene_latitude_shadow_knee": -2.0, "scene_latitude_highlight_room": 0.0,
                    "scene_latitude_shadow_room": 0.0})
    report["refuses_unknown_norm"] = refused(params={"scene_latitude_norm": "b"})
    below = ses.scene_latitude({"highlight_pull_back": 0.01,
                                "shadow_pull_back": max(0.01, fit["fit"]["shadow"]["minimum_pull_back"] - 0.2)})
    report["fit_below_minimum_issues"] = [i["code"] + "/" + i["side"] for i in below["fit"]["issues"]]
    report["fit_below_minimum_has_no_delta"] = "params_delta" not in below["fit"]

    if not delta:
        print(json.dumps(report, indent=2)); return

    # --- the fitted render ----------------------------------------------------
    ses.set_params(delta)
    fitted, res = ses.render("full")
    report["shoot_edit_redevelops"] = not bool(res.negative_was_cached)
    ses.set_params({"striped": True, "strip_rows": 97})
    striped, _ = ses.render("full")
    ses.set_params({"striped": False, "strip_rows": 0})
    report["striped_equals_unstriped"] = bool(np.array_equal(striped, fitted))
    report["striped_max_abs_diff"] = diff(striped, fitted)

    # --- the node against the numpy reference the RFC measured with ----------
    # Pre-meter the frame, then: arm A maps it in numpy and renders with the
    # node off; arm B renders it unmapped with the node on. Same curve, same
    # norm, same lift bound -- the difference is float32 against float64.
    ev = ses.solve("exposure")["exposure_ev_by_method"]["balanced"]
    metered = (scene * np.float32(2.0 ** ev)).astype(np.float32)
    p = delta
    mapped, _k = slm.apply_slm2(metered,
                                p["scene_latitude_highlight_knee"], p["scene_latitude_highlight_room"],
                                p["scene_latitude_shadow_knee"], p["scene_latitude_shadow_room"],
                                p["scene_latitude_rolloff"], kind="power",
                                max_lift=p["scene_latitude_max_lift"])
    manual = {"auto_exposure": False, "grain_active": False, "glare_active": False}
    a_ses = eng.open(mapped, {**manual, "scene_latitude_active": False})
    arm_a, _ = a_ses.render("full"); a_ses.close()
    b_ses = eng.open(metered, {**manual, **p})
    arm_b, _ = b_ses.render("full"); b_ses.close()
    report["node_vs_numpy_max_abs_16bit"] = diff(arm_a, arm_b)
    report["node_vs_numpy_p999_abs_16bit"] = float(np.percentile(
        np.abs(arm_a.astype(np.int64) - arm_b.astype(np.int64)), 99.9))
    report["numpy_gain_max_stops"] = float(np.log2(_k.max()))
    report["numpy_frac_identity"] = float((_k == 1.0).mean())

    # --- what it did to the picture -------------------------------------------
    L0, L1 = vcm.to_lab(straight)[..., 0], vcm.to_lab(fitted)[..., 0]
    for name, m in {"shadows (L*<25)": L0 < 25, "midtones (40..60)": (L0 > 40) & (L0 < 60),
                    "highlights (L*>80)": L0 > 80}.items():
        report.setdefault("regions", {})[name] = {
            "fraction": round(float(m.mean()), 4),
            "L_median": [round(float(np.median(L0[m])), 2), round(float(np.median(L1[m])), 2)]}
    vcm.png(outdir / "straight.png", straight)
    vcm.png(outdir / "fitted.png", fitted)
    json.dump(fit, open(outdir / "scene_latitude_reply.json", "w"), indent=1)
    ses.close(); eng.close()
    json.dump(report, open(outdir / "report.json", "w"), indent=2)
    print(json.dumps(report, indent=2))

if __name__ == "__main__":
    main()
