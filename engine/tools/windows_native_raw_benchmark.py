"""Measure fresh-process native RAW-to-TIFF runs with the default effects.

The native executable performs decode/render/export without Python or rawpy.
Python runs independent processes and validates retained RGB16 TIFF artifacts;
TIFF checks, hashing, and the separately labelled 8-bit preview are outside the
measured subprocess wall time. The operating-system file cache is not flushed.
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path
import statistics

import numpy as np

from windows_fixture import read_json, require, resource_snapshot, sha256_file, write_json
from windows_native_raw import execute, read_rgb16_tiff


def statistic(values: list[float]) -> dict:
    return {"count": len(values), "median_ms": statistics.median(values),
            "min_ms": min(values), "max_ms": max(values)}


def preview(pixels: np.ndarray, output: Path, icc: bytes) -> dict:
    from PIL import Image
    from PIL.PngImagePlugin import PngInfo

    encoded8 = ((pixels.astype(np.uint32) + 128) // 257).astype(np.uint8)
    image = Image.fromarray(encoded8)
    image.thumbnail((1600, 1600), Image.Resampling.LANCZOS)
    description = "Display preview only: downsampled 8-bit encoded sRGB; original RGB16 TIFF is the numerical artifact."
    metadata = PngInfo()
    metadata.add_text("Description", description)
    image.save(output, pnginfo=metadata, icc_profile=icc)
    return {"file": output.name, "sha256": sha256_file(output), "width": image.width,
            "height": image.height, "bits_per_sample": 8, "color_space": "sRGB",
            "transfer": "encoded", "description": description,
            "numerical_artifact": False, "timed": False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--processes", type=int, default=3)
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--decode-mode", choices=("compatible16", "headroom"),
                        help="omit to test the native host's default compatibility policy")
    args = parser.parse_args()
    for key in ("driver", "resources", "input", "output"):
        setattr(args, key, getattr(args, key).resolve())
    require(args.processes >= 3 and args.timeout > 0, "require at least three processes and a positive timeout")
    require(not args.output.exists(), "benchmark output exists; choose a fresh directory")
    require(args.driver.is_file() and args.input.is_file(), "native driver or RAW input is missing")
    args.output.mkdir(parents=True)
    report = {"success": False, "harness_sha256": sha256_file(Path(__file__)),
              "processes": args.processes, "params_argument_supplied": False,
              "decoded_output_argument_supplied": False, "runs": [],
              "decode_mode_argument": args.decode_mode,
              "scope": "fresh native process, RAW decode + engine create/open + default full render + RGB16 TIFF/report publication",
              "external_engine_parity": "unverified", "operating_system_file_cache_flushed": False,
              "validation_and_preview_in_subprocess_timing": False}
    try:
        input_hash = sha256_file(args.input)
        binaries = [args.driver, *sorted(args.driver.parent.glob("*.dll"))]
        report["binaries"] = {path.name: {"sha256": sha256_file(path), "bytes": path.stat().st_size}
                              for path in binaries}
        report["resources"] = resource_snapshot(args.resources)
        report["input"] = {"path": str(args.input), "sha256": input_hash,
                           "bytes": args.input.stat().st_size}
        icc = (args.resources / "io" / "sRGB.icc").read_bytes()
        shape = None
        for index in range(1, args.processes + 1):
            tiff = args.output / f"default-{index}.tif"
            native_json = args.output / f"default-{index}.json"
            command = [str(args.driver), "--input", str(args.input), "--output", str(tiff),
                       "--report", str(native_json), "--resources", str(args.resources)]
            if args.decode_mode:
                command += ["--decode-mode", args.decode_mode]
            process = execute(command, args.output, args.timeout, args.output / f"process-{index}.json")
            require(process["returncode"] == 0, f"native default run {index} failed: {process['stderr']}")
            native = read_json(native_json)
            require(native.get("success") is True, "native default report is not successful")
            require(native.get("decode", {}).get("mode", "compatible16") == (args.decode_mode or "compatible16"),
                    "native host used a different RAW decode policy")
            params = native.get("resolved_params", {})
            require(all(params.get(name) is True for name in ("grain_active", "glare_active", "auto_exposure")),
                    "native defaults disabled grain, glare, or automatic exposure")
            require(params.get("input_color_space") == "ProPhoto RGB" and params.get("input_cctf_decoding") is False and
                    params.get("output_color_space") == "sRGB" and params.get("output_cctf_encoding") is True,
                    "native default color contract changed")
            timings = native.get("timings_ms", {})
            require({"decode", "engine_create", "open", "render", "write"}.issubset(timings),
                    "native default report omits stage timing")
            require(all(isinstance(value, (int, float)) and not isinstance(value, bool) and
                        math.isfinite(value) and value >= 0 for value in timings.values()),
                    "native default report contains invalid timing")
            pixels, metadata = read_rgb16_tiff(tiff, icc)
            current_shape = (native["input"]["height"], native["input"]["width"], 3)
            require(pixels.shape == current_shape, "native default TIFF dimensions differ from the decoded RAW")
            require(shape is None or shape == current_shape, "native default dimensions changed across processes")
            shape = current_shape
            require(bool(np.any(pixels != pixels[0, 0])), "native default TIFF has no spatial variation")
            row = {"index": index, "subprocess_wall_ms": process["wall_ms"], "timings_ms": timings,
                   "resolved_params": params, "decode": native.get("decode"), "tiff": metadata,
                   "tiff_file": tiff.name, "native_report_file": native_json.name,
                   "alpha": "not applicable: RGB TIFF has no alpha channel"}
            report["runs"].append(row)
            if index == 1:
                report["preview"] = preview(pixels, args.output / "default-preview-8bit.png", icc)
            del pixels
            print(f"native default {index}/{args.processes}: wall={process['wall_ms']:.2f} ms, "
                  f"decode={timings['decode']:.2f}, render={timings['render']:.2f}, write={timings['write']:.2f}", flush=True)
        stage_names = set(report["runs"][0]["timings_ms"])
        require(all(set(row["timings_ms"]) == stage_names for row in report["runs"]),
                "native timing stages changed between processes")
        report["statistics"] = {name: statistic([row["timings_ms"][name] for row in report["runs"]])
                                for name in sorted(stage_names)}
        report["statistics"]["subprocess_wall"] = statistic([row["subprocess_wall_ms"] for row in report["runs"]])
        report["statistics_notes"] = (
            "Stage values are reported by the native process. Subprocess wall includes startup, teardown and publication. "
            "Nested engine or total timings must not be added to their enclosing stages. Each process renders once; "
            "this is not the in-process warm-render benchmark. Stochastic outputs are retained, not hash-compared to each other."
        )
        require(sha256_file(args.input) == input_hash, "RAW input changed during the benchmark")
        require(all(sha256_file(path) == report["binaries"][path.name]["sha256"] for path in binaries),
                "native binaries changed during the benchmark")
        require(resource_snapshot(args.resources) == report["resources"], "resources changed during the benchmark")
        report["success"] = True
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        write_json(args.output / "report.json", report)


if __name__ == "__main__":
    main()
