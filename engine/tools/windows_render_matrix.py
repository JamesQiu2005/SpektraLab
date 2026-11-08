"""Exercise the Windows C ABI on decoded linear ProPhoto RGB input.

This is an execution/feature gate, not an external Python/Metal parity oracle.
The default case retains stochastic grain, glare and automatic exposure.
Outputs are tight RGBA16 in encoded sRGB; PNG files are 8-bit display previews.
"""
from __future__ import annotations

import argparse
import ctypes
import json
from pathlib import Path
import sys
import time

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE / "tests"))
from spk_ctypes import Engine, EngineError, SpkResult, SPK_OK
from windows_fixture import FixtureError, read_json, require, resource_snapshot, sha256_file, write_json

COMMON = {"film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura",
          "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False,
          "output_color_space": "sRGB", "output_cctf_encoding": True}
BASE = {"grain_active": False, "glare_active": False, "auto_exposure": False}
CASES = {
    "baseline": BASE,
    "default": {},
    "simple_grain": {"grain_sublayers_active": False, "glare_active": False},
    "boost": {**BASE, "halation_boost_ev": 1.0},
    "bw_correction": {**BASE, "scanner_white_correction": True, "scanner_black_correction": True},
    "edr": {**BASE, "extended_dynamic_range": True},
}


def load_input(path: Path, width: int, height: int, metadata: Path | None) -> tuple[np.ndarray, dict]:
    require(width > 0 and height > 0, "width and height must be positive")
    require(path.is_file(), f"input is missing: {path}")
    size = width * height * 3 * 4
    require(path.stat().st_size == size, "input byte count does not match dimensions")
    digest = sha256_file(path)
    provenance = {}
    if metadata:
        provenance = read_json(metadata)
        expected = {"format_version": 2, "width": width, "height": height, "channels": 3,
                    "output_sha256": digest, "output_byte_count": size,
                    "dtype": "little-endian float32", "layout": "packed HWC RGB",
                    "row_order": "top_down", "row_stride_px": width,
                    "output_color_space": "ProPhoto RGB", "output_cctf_encoding": False,
                    "gamma": [1, 1]}
        require(all(provenance.get(key) == value for key, value in expected.items()),
                "decoder metadata does not match the pixels or linear ProPhoto contract")
    image = np.fromfile(path, dtype="<f4").reshape(height, width, 3)
    require(bool(np.isfinite(image).all()), "input contains NaN or infinity")
    return image, {"file": str(path.resolve()), "sha256": digest, "width": width, "height": height,
                   "channels": 3, "format": "float32_le_rgb", "color_space": "ProPhoto RGB",
                   "transfer": "linear", "minimum": float(image.min()), "maximum": float(image.max()),
                   "metadata_file": str(metadata.resolve()) if metadata else None,
                   "metadata_sha256": sha256_file(metadata) if metadata else None,
                   "decoder": provenance}


def validate_params(actual: dict, case_name: str) -> None:
    expected = {**COMMON, "grain_active": True, "glare_active": True, "auto_exposure": True,
                **CASES[case_name]}
    require(all(actual.get(key) == value for key, value in expected.items()),
            f"resolved parameters do not match case {case_name}")


def render(session, expected_shape: tuple[int, int, int], reprint=False) -> tuple[np.ndarray, dict]:
    result = SpkResult()
    start = time.perf_counter()
    fn = session._engine._lib.spk_reprint if reprint else session._engine._lib.spk_render
    status = fn(session._handle, b"full", ctypes.byref(result))
    wall_ms = (time.perf_counter() - start) * 1000
    try:
        if status != SPK_OK:
            raise EngineError(session._engine._last_error())
        require(bool(result.rgba16) and result.width > 0 and result.height > 0
                and result.row_stride_px >= result.width, "invalid returned image layout")
        require((result.height, result.width, 4) == expected_shape,
                "returned dimensions do not match the requested full image")
        flat = np.ctypeslib.as_array(result.rgba16, shape=(result.height * result.row_stride_px * 4,))
        rgba = np.array(flat.reshape(result.height, result.row_stride_px, 4)[:, :result.width], copy=True)
        info = {"width": result.width, "height": result.height, "row_stride_px": result.row_stride_px,
                "engine_elapsed_ms": result.elapsed_ms, "wall_ms": wall_ms,
                "reprint": bool(result.reprint), "negative_was_cached": bool(result.negative_was_cached),
                "rgb_minimum": int(rgba[..., :3].min()), "rgb_maximum": int(rgba[..., :3].max()),
                "rgb_mean_counts": rgba[..., :3].mean(axis=(0, 1)).tolist(),
                "rgb_std_counts": rgba[..., :3].std(axis=(0, 1)).tolist()}
        require(bool((rgba[..., 3] == 65535).all()), "output alpha is not opaque")
        require(bool(np.any(rgba[..., :3] != rgba[0, 0, :3])), "output has no spatial variation")
        return rgba, info
    finally:
        session._engine._lib.spk_result_free(ctypes.byref(result))


def save_image(directory: Path, name: str, image: np.ndarray, preview: bool) -> dict:
    path = directory / f"{name}.rgba16"
    np.asarray(image, dtype="<u2", order="C").tofile(path)
    result = {"file": path.name, "sha256": sha256_file(path), "byte_count": path.stat().st_size,
              "format": "uint16_le_rgba", "color_space": "sRGB", "transfer": "encoded"}
    if preview:
        from PIL import Image
        from PIL.PngImagePlugin import PngInfo
        display = Image.fromarray(((image[..., :3].astype(np.uint32) + 128) // 257).astype(np.uint8))
        display.thumbnail((1280, 1280), Image.Resampling.LANCZOS)
        preview_path = directory / f"{name}-preview.png"
        colour_tag = PngInfo()
        colour_tag.add(b"sRGB", b"\x00")
        display.save(preview_path, pnginfo=colour_tag)
        result["preview"] = {"file": preview_path.name, "sha256": sha256_file(preview_path),
                             "width": display.width, "height": display.height,
                             "purpose": "8-bit display preview; may be resized, not grain/parity evidence"}
    return result


def run_matrix(args) -> dict:
    output = args.output.resolve()
    require(not output.exists(), "output directory already exists; use a new directory")
    image, input_info = load_input(args.input, args.width, args.height, args.input_metadata)
    output.mkdir(parents=True)
    report = {"format_version": 1, "success": False, "verification": "execution_and_feature_checks",
              "external_parity": "unverified", "input": input_info, "cases": {},
              "harness_sha256": sha256_file(Path(__file__).resolve())}
    try:
        with Engine(library=args.library, resources=args.resources) as engine:
            report["environment"] = {"library": str(engine.library_path),
                "library_sha256": sha256_file(engine.library_path), "build_info": engine.build_info,
                "capabilities": engine.capabilities(), "numpy": np.__version__,
                "runtime_libraries": {name: sha256_file(engine.library_path.parent / name)
                    for name in ("libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll")
                    if (engine.library_path.parent / name).is_file()}}
            report["resources"] = resource_snapshot(engine.resources_path)
            for name in args.cases:
                delta = {**COMMON, **CASES[name]}
                case = {"params_delta": delta, "success": False}
                report["cases"][name] = case
                with engine.open(image, delta) as session:
                    case["open_reply"] = session.reply
                    case["resolved_params"] = session.get_params()
                    validate_params(case["resolved_params"], name)
                    shape = (args.height, args.width, 4)
                    first, first_info = render(session, shape)
                    case["first"] = {**first_info, **save_image(output, name, first, args.preview)}
                    if args.repeat:
                        second, second_info = render(session, shape)
                        changed = int(np.count_nonzero(first[..., :3] != second[..., :3]))
                        case["repeat"] = {**second_info, "different_rgb_values": changed}
                        if name in ("baseline", "boost", "bw_correction", "edr"):
                            require(changed == 0, f"deterministic case {name} changed across full renders")
                        else:
                            require(changed > 0, f"stochastic case {name} did not draw a fresh realisation")
                    if name == "baseline" and args.reprint:
                        printed, info = render(session, shape, reprint=True)
                        require(np.array_equal(first, printed), "unchanged deterministic reprint differs")
                        require(info["reprint"] and info["negative_was_cached"], "reprint did not reuse the negative")
                        case["reprint"] = {**info, "bit_exact": True}
                        session.set_params({"print_exposure": 1.2})
                        require(session.get_params().get("print_exposure") == 1.2,
                                "print exposure edit did not take effect")
                        edited, info = render(session, shape, reprint=True)
                        require(info["negative_was_cached"] and not np.array_equal(first, edited),
                                "print exposure did not change the cached-negative print")
                        case["print_exposure_reprint"] = {**info, **save_image(output, name + "-print-edit", edited, args.preview)}
                        full, info = render(session, shape)
                        require(np.array_equal(edited, full), "edited reprint differs from full render")
                        case["edited_full"] = {**info, "matches_reprint": True}
                    case["memory_report"] = engine.memory_report()
                    case["success"] = True
                print(f"{name}: {args.width}x{args.height}, {first_info['wall_ms']:.1f} ms, passed", flush=True)
            report["success"] = True
    except Exception as exc:
        report["error"] = str(exc)
        raise
    finally:
        write_json(output / "report.json", report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--input-metadata", type=Path)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--repeat", action="store_true")
    parser.add_argument("--reprint", action="store_true")
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    try:
        require(len(args.cases) == len(set(args.cases)), "case names must be unique")
        run_matrix(args)
        return 0
    except (FixtureError, EngineError, OSError, ValueError) as exc:
        print(f"render matrix failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
