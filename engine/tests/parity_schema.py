"""Diff the C++ transport schema and digested params against the Python service.

RFC-014 keeps the wire unchanged (contract §2), and "unchanged" has to mean
something checkable. This compares, field for field:

  * `params_schema` -- name, path, type, layer, default, live flag, range.
    A row added on one side and not the other is a failure here unless it is a
    named native-product extension with its complete contract pinned below.
  * `read_params` for six stock pairs, which is what every reply carries.
  * the *digested internals* -- the stock-specific DIR-coupler gammas, the
    halation preset, the neutral filter pack from the database, and the
    nanmin/nanmax of each profile's density curves. None of these cross the
    wire, and all of them decide the picture, so the wire cannot show them
    wrong.

Usage: engine/tests/parity_schema.py [--binary path]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE.parent / "src"))

STOCK_PAIRS = [
    ("kodak_portra_400", "kodak_portra_endura"),
    ("kodak_gold_200", "kodak_endura_premier"),
    ("fujifilm_velvia_100", "kodak_portra_endura"),
    ("fujifilm_provia_100f", "kodak_portra_endura"),
    ("kodak_ektachrome_100", "kodak_ektacolor_edge"),
    ("kodak_portra_800", "kodak_portra_endura"),
]


# Divergences from the Python oracle that are **deliberate**, each with the
# reason it is not a break. The shape is `parity_render.py`'s (`lens_blur_um`,
# which the C++ engine implements and the reference prunes) and `AGENTS.md`
# trap 22's: a known difference is written down, named, and checked in both
# directions — a divergence that stops diverging is a failure too, so the list
# cannot go stale.
KNOWN = {
    ("output_color_space", "default"): (
        "ProPhoto RGB",
        "RFC-018 §5.1: the declared output default is the *working space*, so that "
        "`core/params.hpp` and `spk_open` stop disagreeing (§4.2 named that "
        "disagreement as a defect — the header said sRGB while the behaviour was "
        "Display P3). The Python oracle still declares sRGB because it is the old "
        "product's schema and nothing regenerates it; what this harness exists to "
        "catch — a rename, a moved path, a changed layer or order — is unchanged. "
        "The wire is still transport 1 / schema 1 and no client reads this default.",
    ),
}

# Product-native fields added after the Python reference was frozen. Keep the
# exception exact: the test still fails on a rename, reordered row, changed
# path/type/layer/default/live/range, or if the Python oracle later gains it.
NATIVE_ONLY = {
    "extended_dynamic_range": {
        "path": "print_render.edr_enabled", "type": "bool", "layer": "print",
        "default": False, "live": False, "range": None,
    },
    # RFC-020 §4's striped execution. Three, not one, and the split is the
    # point: `striped` is the switch, `strip_rows` the height (`0` = the
    # engine's policy decides, per §7), and the budget is accepted and varied
    # by nothing yet. All three are `live` because switching modes cannot move
    # a pixel -- if one of them ever needed a rebuild, that is a schema lie and
    # this table is where it should be visible.
    "striped": {
        "path": "settings.striped", "type": "bool", "layer": "print",
        "default": False, "live": True, "range": None,
    },
    "strip_rows": {
        "path": "settings.strip_rows", "type": "int", "layer": "print",
        "default": 0, "live": True, "range": [0, 16384],
    },
    "strip_budget_bytes": {
        "path": "settings.strip_budget_bytes", "type": "int", "layer": "print",
        "default": 0, "live": True, "range": [0, 8e9],
    },
    # RFC-024's virtual contrast mask: print layer (a mask edit reprints the
    # cached negative), not live (the analysis is prepared per run, and a
    # rebuild is the honest default). `active = false` is the exact bypass.
    "contrast_mask_active": {
        "path": "print_render.contrast_mask.active", "type": "bool", "layer": "print",
        "default": False, "live": False, "range": None,
    },
    "contrast_mask_highlights": {
        "path": "print_render.contrast_mask.highlights", "type": "float", "layer": "print",
        "default": 0.0, "live": False, "range": [0.0, 3.0],
    },
    "contrast_mask_shadows": {
        "path": "print_render.contrast_mask.shadows", "type": "float", "layer": "print",
        "default": 0.0, "live": False, "range": [0.0, 3.0],
    },
    "contrast_mask_core": {
        "path": "print_render.contrast_mask.core", "type": "float", "layer": "print",
        "default": 1.0, "live": False, "range": [0.0, 3.0],
    },
    "contrast_mask_scale": {
        "path": "print_render.contrast_mask.scale", "type": "float", "layer": "print",
        "default": 0.03, "live": False, "range": [0.002, 0.12],
    },
    "contrast_mask_scheme": {
        "path": "print_render.contrast_mask.scheme", "type": "str", "layer": "print",
        "default": "gaussian", "live": False, "range": None,
    },
    # RFC-023 Scene Latitude: the resolved curve, SHOOT layer (it sits before the film).
    "scene_latitude_active": {
        "path": "camera.scene_latitude.active", "type": "bool", "layer": "shoot",
        "default": False, "live": False, "range": None,
    },
    "scene_latitude_norm": {
        "path": "camera.scene_latitude.norm", "type": "str", "layer": "shoot",
        "default": 'power', "live": False, "range": None,
    },
    "scene_latitude_highlight_knee": {
        "path": "camera.scene_latitude.highlight_knee", "type": "float", "layer": "shoot",
        "default": 2.0, "live": False, "range": [-24.0, 24.0],
    },
    "scene_latitude_highlight_room": {
        "path": "camera.scene_latitude.highlight_room", "type": "float", "layer": "shoot",
        "default": 0.0, "live": False, "range": [0.0, 24.0],
    },
    "scene_latitude_shadow_knee": {
        "path": "camera.scene_latitude.shadow_knee", "type": "float", "layer": "shoot",
        "default": -2.0, "live": False, "range": [-24.0, 24.0],
    },
    "scene_latitude_shadow_room": {
        "path": "camera.scene_latitude.shadow_room", "type": "float", "layer": "shoot",
        "default": 0.0, "live": False, "range": [0.0, 24.0],
    },
    "scene_latitude_rolloff": {
        "path": "camera.scene_latitude.rolloff", "type": "float", "layer": "shoot",
        "default": 2.0, "live": False, "range": [1.0, 4.0],
    },
    "scene_latitude_max_lift": {
        "path": "camera.scene_latitude.max_lift", "type": "float", "layer": "shoot",
        "default": 4.0, "live": False, "range": [0.25, 12.0],
    },
}


def close(a, b, tol=1e-12) -> bool:
    if isinstance(a, bool) or isinstance(b, bool):
        return bool(a) == bool(b)
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
        return abs(float(a) - float(b)) <= tol * max(1.0, abs(float(a)))
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)):
        return len(a) == len(b) and all(close(x, y, tol) for x, y in zip(a, b))
    return a == b


def check_schema(got: dict) -> int:
    from spektrafilm.service import schema as pyschema

    want = pyschema.transport_schema()
    failures = 0
    if got["schema_version"] != want["schema_version"]:
        print(f"FAIL schema_version: C++ {got['schema_version']}, Python {want['schema_version']}")
        failures += 1

    g = {f["name"]: f for f in got["fields"]}
    w = {f["name"]: f for f in want["fields"]}
    for name in sorted(set(g) | set(w)):
        if name not in g:
            print(f"FAIL field {name!r}: declared by the Python service, missing from the engine")
            failures += 1
            continue
        if name not in w:
            expected = NATIVE_ONLY.get(name)
            actual = {key: g[name].get(key) for key in expected} if expected else None
            if expected is not None and actual == expected:
                print(f"native-only field {name!r}: {expected}")
                continue
            print(f"FAIL field {name!r}: declared by the engine, missing from the Python service")
            failures += 1
            continue
        for key in ("path", "type", "layer", "default", "live", "range"):
            a, b = g[name].get(key), w[name].get(key)
            if close(a, b):
                if (name, key) in KNOWN:
                    expected, _ = KNOWN[(name, key)]
                    print(f"FAIL field {name!r}.{key}: the two sides now agree ({a!r}); "
                          f"the recorded divergence is stale — remove it from KNOWN")
                    failures += 1
                continue
            if (name, key) in KNOWN:
                expected, reason = KNOWN[(name, key)]
                if a != expected:
                    print(f"FAIL field {name!r}.{key}: C++ {a!r} is neither the oracle's {b!r} "
                          f"nor the recorded divergence {expected!r}")
                    failures += 1
                else:
                    print(f"known field {name!r}.{key}: C++ {a!r}, Python {b!r} — {reason}")
                continue
            print(f"FAIL field {name!r}.{key}: C++ {a!r}, Python {b!r}")
            failures += 1

    order_cpp = [f["name"] for f in got["fields"]]
    order_py = [f["name"] for f in want["fields"]]
    for name in NATIVE_ONLY:
        order_py.insert(order_py.index("preview_long_edge"), name)
    if order_cpp != order_py:
        print("FAIL field order differs")
        print(f"     C++:    {order_cpp}")
        print(f"     Python: {order_py}")
        failures += 1
    if not failures:
        print(f"schema: {len(g)} engine fields; Python fields identical plus "
              f"{len(NATIVE_ONLY)} pinned native extension")
    return failures


def python_internals(film_stock: str, print_stock: str):
    from spektrafilm.runtime.params_builder import digest_params, init_params
    from spektrafilm.service import schema as pyschema

    p = digest_params(init_params(film_profile=film_stock, print_profile=print_stock))
    dc = p.film_render.dir_couplers
    hal = p.film_render.halation

    def minmax(profile):
        curves = np.asarray(profile.data.density_curves)
        normalized = curves - np.nanmin(curves, axis=0)
        return list(np.nanmin(curves, axis=0)), list(np.nanmax(normalized, axis=0))

    film_min, film_max = minmax(p.film)
    print_min, print_max = minmax(p.print)
    return pyschema.read_params(p), {
        "dir_couplers.gamma_samelayer_rgb": list(dc.gamma_samelayer_rgb),
        "dir_couplers.gamma_interlayer_r_to_gb": list(dc.gamma_interlayer_r_to_gb),
        "dir_couplers.gamma_interlayer_g_to_rb": list(dc.gamma_interlayer_g_to_rb),
        "dir_couplers.gamma_interlayer_b_to_rg": list(dc.gamma_interlayer_b_to_rg),
        "halation.halation_first_sigma_um": list(hal.halation_first_sigma_um),
        "halation.halation_strength": list(hal.halation_strength),
        "grain.micro_structure": list(p.film_render.grain.micro_structure),
        "scanner.unsharp_mask": list(p.scanner.unsharp_mask),
        "enlarger.c_filter_neutral": float(p.enlarger.c_filter_neutral),
        "enlarger.m_filter_neutral": float(p.enlarger.m_filter_neutral),
        "enlarger.y_filter_neutral": float(p.enlarger.y_filter_neutral),
        "profile.film.type": p.film.info.type,
        "profile.film.use": p.film.info.use,
        "profile.film.antihalation": p.film.info.antihalation,
        "profile.film.reference_illuminant": p.film.info.reference_illuminant,
        "profile.print.viewing_illuminant": p.print.info.viewing_illuminant,
        "profile.film.density_min": film_min,
        "profile.film.density_max": film_max,
        "profile.print.density_min": print_min,
        "profile.print.density_max": print_max,
    }


def check_pairs(got: dict) -> int:
    failures = 0
    # The same KNOWN divergences as `check_schema`, applied to the *resolved*
    # params: `output_color_space` is the same field with the same new default,
    # merely read back per stock pair rather than off the schema.
    announced: set = set()
    for film, print_stock in STOCK_PAIRS:
        key = f"{film}|{print_stock}"
        if key not in got:
            print(f"FAIL {key}: the engine produced no entry")
            failures += 1
            continue
        want_params, want_internals = python_internals(film, print_stock)
        g = got[key]
        for name in sorted(set(g["params"]) | set(want_params)):
            a, b = g["params"].get(name), want_params.get(name)
            if name in NATIVE_ONLY and name not in want_params:
                if a != NATIVE_ONLY[name]["default"]:
                    print(f"FAIL {key} params.{name}: native default {a!r}, "
                          f"expected {NATIVE_ONLY[name]['default']!r}")
                    failures += 1
                continue
            if close(a, b):
                if (name, "default") in KNOWN:
                    print(f"FAIL {key} params.{name}: the two sides now agree ({a!r}); "
                          f"the recorded divergence is stale — remove it from KNOWN")
                    failures += 1
                continue
            entry = KNOWN.get((name, "default"))
            if entry is not None and a == entry[0]:
                if name not in announced:
                    announced.add(name)
                    print(f"known params.{name} ({len(STOCK_PAIRS)} pairs): C++ {a!r}, "
                          f"Python {b!r} — {entry[1]}")
                continue
            print(f"FAIL {key} params.{name}: C++ {a!r}, Python {b!r}")
            failures += 1
        for name in sorted(want_internals):
            a, b = g["internals"].get(name), want_internals[name]
            if not close(a, b):
                print(f"FAIL {key} internals.{name}: C++ {a!r}, Python {b!r}")
                failures += 1
    if not failures:
        print(f"params + internals: {len(STOCK_PAIRS)} stock pairs, identical")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", type=Path, default=ENGINE / "build" / "dump_json")
    args = ap.parse_args()
    out = subprocess.run([str(args.binary), str(ENGINE / "resources")],
                         check=True, capture_output=True, text=True).stdout
    got = json.loads(out)
    failures = check_schema(got["schema"]) + check_pairs(got["pairs"])
    print(f"\n{failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
