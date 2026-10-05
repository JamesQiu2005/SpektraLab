"""Compare striped Windows renders and cached reprints against whole frames.

The fixture includes the 129 x 193 lifecycle regression and engaged FIR/IIR
cases. Every comparison is exact RGBA16; row counts identify boundary defects.
An optional archived DLL quantifies whole-frame changes across a repair.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

import numpy as np

from windows_fixture import FixtureError, require, resource_snapshot, sha256_file, write_json
from windows_lifecycle import OwnedResult, difference_stats, frame
from windows_render_matrix import BASE, COMMON
from spk_ctypes import Engine, EngineError


CASES = {
    "baseline": (129, 193, {}),
    "no_halation": (129, 193, {"halation_active": False}),
    "no_couplers": (129, 193, {"dir_couplers_active": False}),
    "scanner_iir": (129, 193, {"scanner_lens_blur": 3.0}),
    "film_fir": (180, 180, {"lens_blur_um": 100.0}),
    "print_fir": (180, 180, {"scanner_lens_blur": 2.0}),
    "narrow": (31, 17, {"lens_blur_um": 100.0, "scanner_lens_blur": 2.0}),
}


def compare(actual: np.ndarray, expected: np.ndarray) -> dict:
    result = difference_stats(actual, expected)
    delta = np.abs(actual.astype(np.int32) - expected.astype(np.int32))
    result["changed_channel_values_per_row"] = (delta != 0).sum(axis=(1, 2)).tolist()
    result["maximum_absolute_u16_per_row"] = delta.max(axis=(1, 2)).tolist()
    result["first_changed_coordinates_yxc"] = np.argwhere(delta != 0)[:12].tolist()
    return result


def fixture(name: str, height: int, width: int) -> np.ndarray:
    image = frame(height, width)
    if name in ("film_fir", "print_fir", "narrow"):
        y = np.arange(height, dtype=np.float64)[:, None, None]
        image = np.clip(image.astype(np.float64) + 0.15 * np.cos(2.0 * np.pi * y / 5.0),
                        0.01, 0.99).astype(np.float32)
    return image


def run(args) -> dict:
    require(not args.output.exists(), "output report already exists; use a new path")
    require(bool(args.reference_library) == bool(args.reference_resources),
            "pass both reference library and reference resources")
    require(all(rows >= 0 for rows in args.rows), "strip heights must be nonnegative")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    report = {"format_version": 1, "success": False, "external_parity": "unverified",
              "harness_sha256": sha256_file(Path(__file__).resolve()), "cases": {},
              "comparison": "exact RGBA16 against whole-frame render and cached reprint"}
    reference = None
    try:
        if args.reference_library:
            reference = Engine(library=args.reference_library, resources=args.reference_resources)
            report["reference"] = {"library": str(reference.library_path),
                "library_sha256": sha256_file(reference.library_path),
                "resources": resource_snapshot(reference.resources_path), "build_info": reference.build_info}
        with Engine(library=args.library, resources=args.resources) as engine:
            report["environment"] = {"library": str(engine.library_path),
                "library_sha256": sha256_file(engine.library_path),
                "resources": resource_snapshot(engine.resources_path), "build_info": engine.build_info}
            if reference:
                require(report["reference"]["resources"]["baked_sha256"] ==
                        report["environment"]["resources"]["baked_sha256"],
                        "reference baked resources differ")
            for name in args.cases:
                height, width, delta = CASES[name]
                params = {**COMMON, **BASE, **delta, "preview_long_edge": 800}
                image = fixture(name, height, width)
                case = {"success": False, "params_delta": params,
                        "width": width, "height": height, "striped": []}
                report["cases"][name] = case
                with engine.open(image, {**params, "striped": False}) as session:
                    with OwnedResult(session) as result:
                        whole = np.array(result.pixels(), copy=True)
                        case["whole"] = result.info()
                    with OwnedResult(session, reprint=True) as result:
                        whole_reprint = np.array(result.pixels(), copy=True)
                        case["whole_reprint"] = result.info()
                        require(bool(result.result.negative_was_cached), "whole reprint missed its negative")
                if reference:
                    with reference.open(image, {**params, "striped": False}) as session:
                        with OwnedResult(session) as result:
                            case["archived_whole"] = result.info()
                            case["whole_regression"] = compare(whole, result.pixels())
                for rows in list(dict.fromkeys([height, *args.rows])):
                    with engine.open(image, {**params, "striped": True, "strip_rows": rows}) as session:
                        with OwnedResult(session) as result:
                            entry = {"rows": rows, "render": result.info(),
                                     "render_difference": compare(result.pixels(), whole),
                                     "progress": session.progress()}
                        with OwnedResult(session, reprint=True) as result:
                            entry["reprint"] = result.info()
                            entry["reprint_difference"] = compare(result.pixels(), whole_reprint)
                            require(bool(result.result.negative_was_cached), "striped reprint missed its negative")
                        entry["success"] = entry["render_difference"]["bit_exact"] and entry["reprint_difference"]["bit_exact"]
                        case["striped"].append(entry)
                    print(f"{name}: rows={rows}, changed={entry['render_difference']['changed_channel_values']}, "
                          f"max={entry['render_difference']['maximum_absolute_u16']}", flush=True)
                # A shader boundary repair can correct pixels in whole frames
                # too. Archive differences remain visible; the acceptance here
                # is exact equality between the repaired execution paths.
                case["success"] = all(entry["success"] for entry in case["striped"])
            report["success"] = all(case["success"] for case in report["cases"].values())
    except Exception as exc:
        report["error"] = str(exc)
        raise
    finally:
        if reference:
            reference.close()
        write_json(args.output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--reference-library", type=Path)
    parser.add_argument("--reference-resources", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--rows", nargs="+", type=int, default=[0, 17, 7, 1])
    args = parser.parse_args()
    try:
        return 0 if run(args)["success"] else 1
    except (FixtureError, EngineError, OSError, ValueError) as exc:
        print(f"stripe regression failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
