#!/usr/bin/env python3
"""API-SPEC §21-§26 (2026-11-09): the wire for light leaks, the MZ-S data line, 120 from 65 mm cine film,
135_sprocket's falloff, the diffusion filter and the lens aberrations. Needs only `build.sh dylib`.

    python3 engine/tests/wire_2026_11_checks.py [--dylib path] [--base-dylib path]

1. The schema: the new fields exist, in API-SPEC's order, after `grain_seed` and before `preview_long_edge`,
   all SHOOT and not live.
2. Every enumerated string refuses a name it does not know, with the field named.
3. Off is structural: a session given every new field at its default renders exactly what a session given
   none does -- and, with `--base-dylib` (an engine from before these fields), exactly what that engine
   renders, over a set of frames that exercise the film edge, the date back and the print.
"""
import argparse, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import spk_ctypes as spk  # noqa: E402

NEW = [
    ("diffusion_filter_active", False), ("diffusion_filter_family", "black_pro_mist"),
    ("diffusion_filter_strength", 0.5), ("diffusion_filter_spatial_scale", 1.0),
    ("diffusion_filter_halo_warmth", 0.0), ("diffusion_filter_core_intensity", 1.0),
    ("diffusion_filter_core_size", 1.0), ("diffusion_filter_halo_intensity", 1.0),
    ("diffusion_filter_halo_size", 1.0), ("diffusion_filter_bloom_intensity", 1.0),
    ("diffusion_filter_bloom_size", 1.0),
    ("lens_aberrations_active", False), ("lens_field_curvature_um", 0.0), ("lens_astigmatism_um", 0.0),
    ("lens_field_exponent", 2.0), ("lens_sharp_radius", 0.0), ("lens_coma_um", 0.0),
    ("lens_spherical_amount", 0.0), ("lens_spherical_um", 60.0), ("lens_lateral_ca_r", 0.0),
    ("lens_lateral_ca_b", 0.0), ("lens_loca_um", 0.0), ("lens_loca_sign", "purple"),
    ("lens_loca_highlight_gate", 1.0),
    ("leak_kind", "off"), ("leak_amount", 1.0), ("leak_rate", 1.0), ("leak_front", -1.0),
    ("date_imprint_data_placement", "gap"), ("date_imprint_data_leader", ""),
    ("overscan_perforation", "none"), ("overscan_falloff", 0.0),
]
ENUMS = ["diffusion_filter_family", "lens_loca_sign", "leak_kind", "date_imprint_data_placement",
         "overscan_perforation"]

BASE = {"film_stock": "kodak_portra_400", "print_stock": "kodak_supra_endura", "grain_active": False,
        "glare_active": False, "auto_exposure": False}
CASES = [
    {},
    {"overscan_active": True, "overscan_format": "135", "overscan_leaks": 2.0, "overscan_edge_text": "PORTRA 400"},
    {"overscan_active": True, "overscan_format": "120_6x7", "overscan_holes": "black", "_size": (695, 560)},
    {"date_imprint_active": True, "date_imprint_text": "'26 11 9"},
    {"overscan_active": True, "overscan_format": "135", "date_imprint_active": True, "date_imprint_style": "data",
     "date_imprint_text": "'26 11 9", "date_imprint_data_text": "P 1/180 F8 +0.0"},
    {"film_stock": "kodak_vision3_500t", "overscan_active": True, "overscan_format": "120_6x6", "_size": (600, 600)},
]

failures = 0


def check(ok, what, detail=""):
    global failures
    print(("PASS " if ok else "FAIL ") + what + (f" -- {detail}" if detail else ""))
    failures += 0 if ok else 1


def frame(w=900, h=600, seed=3):
    rng = np.random.default_rng(seed)
    y, x = np.mgrid[0:h, 0:w]
    img = 0.04 + 0.5 * (x / w)[..., None] * np.array([1.0, 0.85, 0.6]) + 0.3 * (y / h)[..., None]
    img[h // 3:h // 3 + 40, w // 2:w // 2 + 40] = 6.0          # a highlight, for every spatial effect
    return (img + 0.01 * rng.standard_normal((h, w, 3))).astype(np.float32)


def render(e, img, extra):
    extra = dict(extra)
    size = extra.pop("_size", None)
    if size:
        img = frame(*size)
    p = dict(BASE); p.update(extra)
    s = e.open(img, p)
    try:
        rgba, _ = s.render("live")
    finally:
        s.close()
    return rgba


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dylib", type=Path)
    ap.add_argument("--base-dylib", type=Path)
    a = ap.parse_args()
    e = spk.Engine(a.dylib)
    schema = e.params_schema()
    fields = schema.get("fields", schema)
    names = [f["name"] for f in fields] if isinstance(fields, list) else list(fields)
    want = [n for n, _ in NEW]
    check(all(n in names for n in want), "every new field is in the schema",
          ", ".join(n for n in want if n not in names))
    if all(n in names for n in want):
        idx = [names.index(n) for n in want]
        check(idx == sorted(idx) and idx == list(range(idx[0], idx[0] + len(idx))),
              "the new fields are one block, in API-SPEC's order")
        check(names[idx[0] - 1] == "grain_seed" and names[idx[-1] + 1] == "preview_long_edge",
              "the block sits after grain_seed and before preview_long_edge",
              f"{names[idx[0] - 1]} .. {names[idx[-1] + 1]}")
        by = {f["name"]: f for f in fields} if isinstance(fields, list) else fields
        bad = [n for n in want if by[n].get("layer") != "shoot" or by[n].get("live")]
        check(not bad, "all SHOOT, none live", ", ".join(bad))

    img = frame()
    for name in ENUMS:
        s = e.open(img, dict(BASE))
        try:
            try:
                s.set_params({name: "nonsense"})
                check(False, f"'{name}' refuses an unknown name")
            except spk.EngineError as err:
                check(name in str(err), f"'{name}' refuses an unknown name", str(err)[:90])
        finally:
            s.close()

    defaults = dict(NEW)
    for i, case in enumerate(CASES):
        plain = render(e, img, case)
        full = dict(case); full.update(defaults)
        check(np.array_equal(plain, render(e, img, full)),
              f"case {i}: every new field at its default renders as none sent")
    if a.base_dylib:
        b = spk.Engine(a.base_dylib)
        for i, case in enumerate(CASES):
            if case.get("date_imprint_active"):
                # The camera's imprints changed on purpose on 2026-11-10 (the LED's
                # base-scatter glow, date_imprint_ev 5.5): a dated case is held by
                # film_effects_checks.py against the engine just before that change.
                print(f"SKIP case {i}: a date (its mechanism changed 2026-11-10)")
                continue
            check(np.array_equal(render(b, img, case), render(e, img, case)),
                  f"case {i}: byte for byte the engine from before the fields")
        b.close()
    e.close()
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
