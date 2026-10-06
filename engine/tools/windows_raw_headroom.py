"""Independent integration gate for the opt-in native RAW headroom policy.

The oracle uses rawpy's oriented uint16 camera RGB with highlight=1, then a
NumPy float64 matrix expression. A second rawpy decode to ProPhoto verifies
the reported matrix against LibRaw's own conversion, including clipping.
This checks the post-demosaic float seam, not an all-float RAW pipeline or
external Metal/colour-model parity. Python is test tooling only.
"""
from __future__ import annotations

import argparse
import hashlib
import math
from pathlib import Path
import sys
import time

import numpy as np

from rawpy_to_f32 import decoder_parameters
from windows_fixture import read_json, require, sha256_file, write_json
from windows_native_raw import difference_stats, execute, make_runtime, read_rgb16_tiff
from windows_render_matrix import BASE, COMMON, Engine, render


def array_hash(values: np.ndarray) -> str:
    digest = hashlib.sha256()
    for row in range(0, values.shape[0], 128):
        digest.update(np.ascontiguousarray(values[row:row + 128]).tobytes())
    return digest.hexdigest()


def sample_stats(values: np.ndarray) -> dict:
    """Exact finite/range/count checks, with explicitly sampled percentiles."""
    minimum = np.full(3, np.inf)
    maximum = np.full(3, -np.inf)
    negative = np.zeros(3, dtype=np.int64)
    above_one = np.zeros(3, dtype=np.int64)
    for row in range(0, values.shape[0], 128):
        band = values[row:row + 128]
        require(bool(np.isfinite(band).all()), "decoded plane contains non-finite samples")
        minimum = np.minimum(minimum, band.min(axis=(0, 1)))
        maximum = np.maximum(maximum, band.max(axis=(0, 1)))
        negative += (band < 0).sum(axis=(0, 1))
        above_one += (band > 1).sum(axis=(0, 1))
    stride = max(1, math.ceil(values.shape[0] * values.shape[1] / 100000))
    sample = values.reshape(-1, 3)[::stride].astype(np.float64)
    percentiles = [0, 0.1, 1, 50, 99, 99.9, 100]
    return {"all_samples_finite": True, "channel_minimum": minimum.tolist(),
            "channel_maximum": maximum.tolist(), "negative_channel_counts": negative.tolist(),
            "above_one_channel_counts": above_one.tolist(), "pixels": int(values.shape[0] * values.shape[1]),
            "sampled_percentiles": {"sampling": "every nth pixel in oriented row-major order",
                                    "stride_pixels": stride, "sampled_pixels": len(sample),
                                    "percentiles": percentiles,
                                    "channel_values": np.percentile(sample, percentiles, axis=0).tolist()}}


def float_matrix_oracle(actual: np.ndarray, camera: np.ndarray,
                        matrix: np.ndarray, restore: float) -> dict:
    """Bound float32 dot-product rounding without tolerating uint16 drift."""
    require(actual.shape == camera.shape, "native and rawpy camera orientations/dimensions differ")
    maximum, maximum_ratio, changed, rejected = 0.0, 0.0, 0, 0
    epsilon = float(np.finfo(np.float32).eps)
    for row in range(0, actual.shape[0], 128):
        samples = camera[row:row + 128].astype(np.float64)
        expected = (samples @ matrix.T) * (restore / 65535.0)
        observed = actual[row:row + 128].astype(np.float64)
        require(bool(np.isfinite(expected).all()) and bool(np.isfinite(observed).all()),
                "matrix oracle found non-finite values")
        difference = np.abs(observed - expected)
        # Three products and two additions in the native float32 expression,
        # followed by final float32 storage. The absolute-sum bound also covers
        # cancellation; a relative-only test would fail near zero.
        absolute_sum = (samples @ np.abs(matrix).T) * (restore / 65535.0)
        bound = np.maximum(8.0 * epsilon * absolute_sum, np.finfo(np.float32).tiny)
        maximum = max(maximum, float(difference.max(initial=0)))
        maximum_ratio = max(maximum_ratio, float((difference / bound).max(initial=0)))
        rejected += int(np.count_nonzero(difference > bound))
        changed += int(np.count_nonzero(observed != expected.astype(np.float32)))
    return {"passed": rejected == 0, "maximum_absolute_error": maximum,
            "maximum_fraction_of_rounding_bound": maximum_ratio,
            "outside_rounding_bound_channel_values": rejected,
            "different_from_one_final_float32_rounding_channel_values": changed,
            "bound": "8 * float32_epsilon * sum(abs(matrix_term)) * exposure_restore / 65535",
            "reference": "rawpy oriented camera RGB16, independent NumPy float64 matrix"}


def prophoto_oracle(actual: np.ndarray, reference: np.ndarray, restore: float) -> dict:
    """Check the native matrix against LibRaw's separately executed conversion."""
    require(actual.shape == reference.shape, "native and rawpy ProPhoto dimensions differ")
    groups = {name: {"channel_values": 0, "changed_channel_values": 0,
                     "maximum_count_error": 0, "over_two_counts": 0}
              for name in ("all", "unclipped_reference", "reference_at_zero_or_65535")}
    for row in range(0, actual.shape[0], 128):
        # Native output has a final float32 rounding; reversing it may cross
        # an integer threshold. Two counts cover this and uint16 truncation,
        # but remain far below a visibly different matrix or exposure scale.
        restored = actual[row:row + 128].astype(np.float64) * (65535.0 / restore)
        reconstructed = np.floor(np.clip(restored, 0, 65535)).astype(np.int32)
        target = reference[row:row + 128].astype(np.int32)
        difference = np.abs(reconstructed - target)
        edges = (target == 0) | (target == 65535)
        for name, mask in (("all", None), ("unclipped_reference", ~edges),
                           ("reference_at_zero_or_65535", edges)):
            band = difference if mask is None else difference[mask]
            item = groups[name]
            item["channel_values"] += int(band.size)
            item["changed_channel_values"] += int(np.count_nonzero(band))
            item["maximum_count_error"] = max(item["maximum_count_error"], int(band.max(initial=0)))
            item["over_two_counts"] += int(np.count_nonzero(band > 2))
    return {"passed": groups["all"]["over_two_counts"] == 0, "maximum_allowed_count_error": 2,
            "reference": "independent rawpy ProPhoto RGB16 with highlight=1",
            "reconstruction": "floor(clip(native_float * 65535 / exposure_restore, 0, 65535))",
            "groups": groups}


def validate_report(report: dict) -> tuple[int, int, np.ndarray, float]:
    require(report.get("success") is True, "native report does not record success")
    info, decode = report.get("input", {}), report.get("decode", {})
    width, height = info.get("width"), info.get("height")
    require(isinstance(width, int) and isinstance(height, int) and width > 0 and height > 0,
            "native report has invalid dimensions")
    require(info.get("color_space") == "ProPhoto RGB" and info.get("transfer") == "linear",
            "native report mislabels decoded colour")
    require(decode.get("mode") == "headroom" and decode.get("preserves_negative_rgb") is True and
            decode.get("preserves_above_one_rgb") is True, "headroom policy was not enabled")
    require(decode.get("float_demosaic") is False and decode.get("sensor_saturation_reconstructed") is False and
            decode.get("preservation_scope") == "RGB conversion after uint16 demosaic",
            "report overstates RAW headroom preservation")
    matrix = np.asarray(decode.get("camera_to_output"), dtype=np.float64)
    require(matrix.shape == (12,) and bool(np.isfinite(matrix).all()), "invalid reported camera matrix")
    matrix = matrix.reshape(3, 4)
    require(bool((matrix[:, 3] == 0).all()), "headroom unexpectedly uses a fourth colour channel")
    restore = decode.get("white_balance_exposure_restore")
    require(isinstance(restore, (int, float)) and math.isfinite(restore) and restore >= 1,
            "invalid reported exposure restoration")
    wb = np.asarray(decode.get("post_scale_pre_mul"), dtype=np.float64)
    require(wb.shape == (4,) and bool(np.isfinite(wb).all()) and bool((wb > 0).all()) and wb.max() == 1,
            "white balance is not maximum-normalised over all four channels")
    require(abs(restore * wb.min() - 1) <= 8 * np.finfo(np.float64).eps,
            "exposure restoration excludes a channel or differs from applied white balance")
    expected_params = {**COMMON, **BASE, "extended_dynamic_range": False}
    require(all(report.get("resolved_params", {}).get(key) == value for key, value in expected_params.items()),
            "native CLI used unexpected effects or EDR instead of input headroom")
    out = report.get("output", {})
    require(out.get("width") == width and out.get("height") == height and
            out.get("color_space") == "sRGB" and out.get("output_cctf_encoding") is True,
            "native output does not describe the sRGB TIFF contract")
    return width, height, matrix[:, :3], float(restore)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("driver", "library", "resources", "input", "output"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--rawpy-path", type=Path,
                        default=Path(__file__).resolve().parents[3] / "deps" / "rawpy-python")
    parser.add_argument("--require-above-one", action="store_true",
                        help="require actual above-one RGB in a fixture known to exercise highlight headroom")
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    for key in ("driver", "library", "resources", "input", "output", "rawpy_path"):
        setattr(args, key, getattr(args, key).resolve())
    require(not args.output.exists(), "choose a fresh test output directory")
    require(args.timeout > 0 and math.isfinite(args.timeout), "timeout must be positive and finite")
    args.output.mkdir(parents=True)
    report = {"success": False, "verification": "native_headroom_post_demosaic_float_seam",
              "external_engine_parity": "unverified", "sensor_saturation_reconstruction": False,
              "float_demosaic": False, "harness_sha256": sha256_file(Path(__file__))}
    try:
        source_hash = sha256_file(args.input)
        report["raw_source"] = {"path": str(args.input), "sha256": source_hash, "bytes": args.input.stat().st_size}
        runtime = args.output / "runtime"
        report["runtime"] = make_runtime(args.driver, args.library, args.resources, runtime)
        driver, resources = runtime / args.driver.name, runtime / "resources"
        params = args.output / "params.json"
        write_json(params, {**COMMON, **BASE, "extended_dynamic_range": False})
        decoded, native_json, tiff = args.output / "decoded.f32", args.output / "native.json", args.output / "result.tif"
        command = [str(driver), "--input", str(args.input), "--resources", str(resources),
                   "--params", str(params), "--decode-mode", "headroom", "--decoded-output", str(decoded),
                   "--report", str(native_json), "--output", str(tiff)]
        process = execute(command, args.output, args.timeout, args.output / "native-process.json")
        report["native_process"] = process
        require(process["returncode"] == 0, "native headroom CLI failed: " + process["stderr"])
        native = read_json(native_json)
        report["native_report"] = native
        width, height, matrix, restore = validate_report(native)
        require(decoded.stat().st_size == width * height * 3 * 4, "native decoded byte count is inconsistent")
        pixels = np.memmap(decoded, dtype="<f4", mode="r", shape=(height, width, 3))
        report["decoded"] = {"sha256": sha256_file(decoded), "bytes": decoded.stat().st_size,
                             **sample_stats(pixels)}
        if args.require_above_one:
            require(sum(report["decoded"]["above_one_channel_counts"]) > 0,
                    "selected fixture did not exercise above-one headroom")
        # A real scene need not contain negative transformed RGB. Synthetic
        # matrix tests cover that case without imposing a scene-content gate.
        report["negative_scene_values_required"] = False
        sys.path.insert(0, str(args.rawpy_path))
        import rawpy
        report["oracle_versions"] = {"rawpy": rawpy.__version__, "rawpy_libraw": list(rawpy.libraw_version),
                                     "native_libraw": native["decode"]["libraw_version"],
                                     "rawpy_path": str(args.rawpy_path), "numpy": np.__version__}
        requested = decoder_parameters(rawpy)
        requested["highlight_mode"] = rawpy.HighlightMode.Ignore
        started = time.perf_counter()
        with rawpy.imread(str(args.input)) as raw:
            camera = raw.postprocess(**{**requested, "output_color": rawpy.ColorSpace.raw})
        report["camera_oracle_decode_ms"] = (time.perf_counter() - started) * 1000
        require(camera.dtype == np.uint16 and camera.shape == pixels.shape, "rawpy camera RGB is not expected oriented RGB16")
        report["camera_oracle_sha256"] = array_hash(camera)
        report["float_matrix_comparison"] = float_matrix_oracle(pixels, camera, matrix, restore)
        require(report["float_matrix_comparison"]["passed"], "native headroom differs from independent float matrix oracle")
        del camera
        started = time.perf_counter()
        with rawpy.imread(str(args.input)) as raw:
            prophoto = raw.postprocess(**requested)
        report["prophoto_oracle_decode_ms"] = (time.perf_counter() - started) * 1000
        require(prophoto.dtype == np.uint16 and prophoto.shape == pixels.shape, "rawpy ProPhoto output is not expected RGB16")
        report["prophoto_oracle_sha256"] = array_hash(prophoto)
        report["prophoto_comparison"] = prophoto_oracle(pixels, prophoto, restore)
        require(report["prophoto_comparison"]["passed"], "native reported colour matrix disagrees with LibRaw ProPhoto conversion")
        del prophoto
        print("headroom camera-space and ProPhoto oracles: passed", flush=True)
        tiff_pixels, report["tiff"] = read_rgb16_tiff(tiff, (resources / "io" / "sRGB.icc").read_bytes())
        with Engine(library=runtime / args.library.name, resources=resources) as engine:
            with engine.open(pixels, {**COMMON, **BASE, "extended_dynamic_range": False}) as session:
                expected, info = render(session, (height, width, 4))
                report["direct_c_abi_render"] = {"info": info, "resolved_params": session.get_params()}
        report["tiff_comparison"] = difference_stats(tiff_pixels, expected[..., :3])
        require(report["tiff_comparison"]["bit_exact"], "headroom TIFF differs from direct C ABI on the same float input")
        require(sha256_file(args.input) == source_hash, "RAW source was modified")
        require(not list(args.output.glob(".spk-*.tmp")), "native CLI left temporary output files")
        report["success"] = True
        print("headroom native TIFF and direct C ABI RGB16: byte-exact", flush=True)
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        write_json(args.output / "report.json", report)


if __name__ == "__main__":
    main()
