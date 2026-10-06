"""Generate fixed pixels, run the Windows DLL driver, and compare an external oracle.

``run`` establishes an execution result and always records parity as unverified.
``compare`` requires a separate reference artifact and its provenance metadata;
the metadata declares its origin, rather than proving that origin independently.
No image decoder, RAW file, Python reference installation, or engine is needed
to generate a fixture. NumPy is the only non-standard dependency of this tool.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

import numpy as np

ENGINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ENGINE / "tests"))
from parity_render import (BASE, COUNT_OUTLIER_FRACTION, COUNT_TOLERANCE,
                           FLOAT_TOLERANCE, load_frame, to_counts)

PRODUCER = "spektralab_windows_fixture_driver"
PARAMS = {**BASE, "film_stock": "kodak_portra_400", "print_stock": "kodak_portra_endura",
          "input_color_space": "ProPhoto RGB", "input_cctf_decoding": False,
          "output_color_space": "ProPhoto RGB", "output_cctf_encoding": True}
INPUT_FORMAT = "float32_le_rgb"
OUTPUT_FORMAT = "uint16_le_rgba"


class FixtureError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def json_bytes(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2,
                       allow_nan=False) + "\n").encode("utf-8")


def write_json(path: Path, value: dict) -> None:
    path.write_bytes(json_bytes(value))


def read_json(path: Path) -> dict:
    if path.stat().st_size > 10 * 1024 * 1024:
        raise FixtureError(f"JSON file is too large: {path}")
    def reject_constant(text):
        raise FixtureError(f"JSON contains non-finite number: {text}")
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"), parse_constant=reject_constant)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise FixtureError(f"invalid JSON {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise FixtureError(f"expected a JSON object: {path}")
    return value


def require(condition: bool, message: str) -> None:
    if not condition:
        raise FixtureError(message)


def same_file(a: Path, b: Path) -> bool:
    if a.exists() and b.exists():
        return os.path.samefile(a, b)
    return a.resolve() == b.resolve()


def protect_output(path: Path, inputs: list[Path]) -> None:
    require(not any(same_file(path, source) for source in inputs),
            f"output path would overwrite an input or provenance file: {path}")


def generate_fixture(output_dir: Path, size: int = 180) -> dict:
    require(type(size) is int and size > 0, "size must be a positive integer")
    output_dir = output_dir.resolve()
    paths = [output_dir / name for name in ("input.f32", "params.json", "manifest.json")]
    require(not any(path.exists() for path in paths), "fixture files already exist; use a new directory")
    frame = load_frame(size)
    require(frame.dtype == np.float32 and frame.ndim == 3 and frame.shape[2] == 3
            and bool(np.isfinite(frame).all()), "generator returned invalid RGB float32 pixels")
    output_dir.mkdir(parents=True, exist_ok=True)
    np.asarray(frame, dtype="<f4", order="C").tofile(paths[0])
    write_json(paths[1], PARAMS)
    h, w = frame.shape[:2]
    manifest = {
        "format_version": 1, "fixture": "synthetic_default",
        "verification": "unverified",
        "generator": {"producer": "parity_render.load_frame", "seed": 7, "height": size,
                      "numpy_version": np.__version__,
                      "source_sha256": sha256_file(ENGINE / "tests" / "parity_render.py")},
        "input": {"file": "input.f32", "sha256": sha256_file(paths[0]),
                  "width": w, "height": h, "channels": 3, "format": INPUT_FORMAT,
                  "byte_count": paths[0].stat().st_size, "row_order": "top_down",
                  "color_space": "ProPhoto RGB", "transfer": "linear"},
        "params": {"file": "params.json", "sha256": sha256_file(paths[1])},
        "output_contract": {"width": w, "height": h, "channels": 4, "format": OUTPUT_FORMAT,
                            "row_order": "top_down", "color_space": "ProPhoto RGB",
                            "transfer": "encoded"},
    }
    write_json(paths[2], manifest)
    return manifest


def validate_fixture(fixture_dir: Path) -> tuple[dict, dict]:
    manifest = read_json(fixture_dir / "manifest.json")
    require(manifest.get("format_version") == 1, "unsupported fixture format_version")
    require(all(isinstance(manifest.get(key), dict) for key in ("input", "params", "output_contract")),
            "fixture input, params and output_contract must be objects")
    require("resource_contract" not in manifest or isinstance(manifest["resource_contract"], dict),
            "fixture resource_contract must be an object")
    inp, params, out = (manifest.get(key, {}) for key in ("input", "params", "output_contract"))
    require(inp.get("file") == "input.f32" and params.get("file") == "params.json",
            "fixture file names must be input.f32 and params.json")
    w, h = inp.get("width"), inp.get("height")
    require(type(w) is int and type(h) is int and 0 < w < 2**32 and 0 < h < 2**32,
            "fixture dimensions must be positive uint32 integers")
    require(inp.get("channels") == 3 and inp.get("format") == INPUT_FORMAT
            and inp.get("row_order") == "top_down" and inp.get("color_space") == "ProPhoto RGB"
            and inp.get("transfer") == "linear", "invalid input type, layout, or color contract")
    require(out == {"width": w, "height": h, "channels": 4, "format": OUTPUT_FORMAT,
                    "row_order": "top_down", "color_space": "ProPhoto RGB", "transfer": "encoded"},
            "invalid output type, dimensions, or color contract")
    pixel_path, params_path = fixture_dir / inp["file"], fixture_dir / params["file"]
    expected_bytes = w * h * 3 * 4
    require(pixel_path.stat().st_size == expected_bytes and inp.get("byte_count") == expected_bytes,
            "input file length does not match its dimensions")
    require(sha256_file(pixel_path) == inp.get("sha256"), "input SHA-256 does not match manifest")
    require(sha256_file(params_path) == params.get("sha256"), "params SHA-256 does not match manifest")
    require(bool(np.isfinite(np.fromfile(pixel_path, dtype="<f4")).all()),
            "input contains NaN or infinity")
    actual_params = read_json(params_path)
    require(actual_params == PARAMS, "this fixture tool supports only the explicit deterministic default case")
    return manifest, actual_params


def resource_snapshot(directory: Path) -> dict:
    require(directory.is_dir(), f"resource directory does not exist: {directory}")
    files = {path.relative_to(directory).as_posix():
             {"sha256": sha256_file(path), "byte_count": path.stat().st_size}
             for path in sorted(directory.rglob("*")) if path.is_file()}
    required = ["spektrafilm_constants.bin", "neutral_print_filters.json", "print_luts.json",
                "profiles/kodak_portra_400.json", "profiles/kodak_portra_endura.json"]
    require(all(name in files for name in required), "required baked resource files are missing")
    # Metal/Vulkan kernels are different artifacts; only the shared baked data
    # identify the resource contract an external backend must use.
    baked = {name: value for name, value in files.items()
             if name.split("/")[0] != "vulkan" and Path(name).suffix not in (".spv", ".metallib")}
    return {"directory": str(directory.resolve()), "files": files,
            "tree_sha256": hashlib.sha256(json_bytes(files)).hexdigest(),
            "baked_sha256": hashlib.sha256(json_bytes(baked)).hexdigest(),
            "baked_scope": "all files except vulkan/ and .spv/.metallib kernels"}


def read_rgba16(path: Path, width: int, height: int) -> np.ndarray:
    require(path.stat().st_size == width * height * 4 * 2,
            f"RGBA16 file length does not match {width}x{height}: {path}")
    pixels = np.fromfile(path, dtype="<u2").reshape(height, width, 4)
    require(bool((pixels[..., 3] == 65535).all()), "RGBA16 alpha must be opaque (65535)")
    return pixels


def validate_driver_report(report: dict, manifest: dict, params: dict, output: Path) -> None:
    require(report.get("format_version") == 1 and report.get("success") is True,
            f"driver did not report success: {report.get('error', '')}")
    inp, contract = manifest["input"], manifest["output_contract"]
    require(report.get("params_delta") == params, "driver parsed a different params delta")
    reported_input = report.get("input", {})
    for key in ("width", "height", "channels", "format", "row_order", "color_space", "transfer", "byte_count"):
        require(reported_input.get(key) == inp[key], f"driver input contract differs at {key}")
    require(isinstance(report.get("open_reply"), dict)
            and isinstance(report["open_reply"].get("params"), dict), "driver lacks resolved params")
    resolved = report["open_reply"]["params"]
    for key, value in params.items():
        require(resolved.get(key) == value, f"engine resolved a different {key}: {resolved.get(key)!r}")
    reported_output = report.get("output", {})
    for key in ("width", "height", "format", "row_order"):
        require(reported_output.get(key) == contract[key], f"driver output contract differs at {key}")
    require(reported_output.get("written") is True
            and reported_output.get("packed_row_stride_px") == contract["width"]
            and reported_output.get("byte_count") == contract["width"] * contract["height"] * 8,
            "driver output is not the expected packed RGBA16 artifact")
    read_rgba16(output, contract["width"], contract["height"])


def run_fixture(driver: Path, resources: Path, fixture_dir: Path, output_dir: Path) -> dict:
    driver, resources, fixture_dir, output_dir = (p.resolve() for p in
                                                 (driver, resources, fixture_dir, output_dir))
    manifest, params = validate_fixture(fixture_dir)
    require(driver.is_file(), f"driver does not exist: {driver}")
    dll = driver.parent / "spektrafilm_engine.dll"
    require(dll.is_file(), f"driver DLL must be beside executable: {dll}")
    snapshot = resource_snapshot(resources)
    prior = manifest.get("resource_contract", {}).get("baked_sha256")
    require(prior is None or prior == snapshot["baked_sha256"],
            "fixture was already associated with different baked resources; generate a new fixture")
    protected = [fixture_dir / name for name in ("input.f32", "params.json", "manifest.json")]
    protected += [driver, dll, *[resources / name for name in snapshot["files"]]]
    output, report_path, run_path, template_path = (output_dir / name for name in
        ("output.rgba16", "render.json", "run.json", "reference-metadata.template.json"))
    for path in (output, report_path, run_path, template_path):
        protect_output(path, protected)
        require(not path.exists(), f"output already exists; use a new run directory: {path}")
    output_dir.mkdir(parents=True, exist_ok=True)
    manifest["resource_contract"] = {"baked_sha256": snapshot["baked_sha256"],
                                     "scope": snapshot["baked_scope"]}
    write_json(fixture_dir / "manifest.json", manifest)
    inp = manifest["input"]
    argv = [str(driver), str(resources), str(fixture_dir / "input.f32"), str(inp["width"]),
            str(inp["height"]), str(fixture_dir / "params.json"), str(output), str(report_path)]
    binary_hashes = {str(path): sha256_file(path) for path in [driver, *sorted(driver.parent.glob("*.dll"))]}
    record = {"format_version": 1, "producer": PRODUCER, "status": "failed",
              "verification": "unverified", "fixture_dir": str(fixture_dir),
              "input_sha256": inp["sha256"], "params_sha256": manifest["params"]["sha256"],
              "command": argv, "binaries_sha256": binary_hashes, "resources": snapshot,
              "output_contract": manifest["output_contract"], "driver_returncode": None}
    try:
        completed = subprocess.run(argv, cwd=driver.parent, capture_output=True, text=True,
                                   encoding="utf-8", errors="replace", check=False)
        record.update(driver_returncode=completed.returncode, stdout=completed.stdout, stderr=completed.stderr)
        report = read_json(report_path) if report_path.is_file() else {}
        if report:
            record.update(driver_report={"path": str(report_path), "sha256": sha256_file(report_path)},
                          driver_stage=report.get("stage"), driver_error=report.get("error"))
        require(completed.returncode == 0,
                f"driver exited with code {completed.returncode}: {report.get('error') or completed.stderr.strip()}")
        validate_driver_report(report, manifest, params, output)
        require(resource_snapshot(resources) == snapshot, "resources changed during execution")
        require(all(sha256_file(Path(path)) == digest for path, digest in binary_hashes.items()),
                "driver or DLL changed during execution")
        validate_fixture(fixture_dir)
        record.update(status="rendered", output={"path": str(output), "sha256": sha256_file(output),
                                                 "byte_count": output.stat().st_size},
                      driver_report={"path": str(report_path), "sha256": sha256_file(report_path)},
                      backend=report.get("capabilities", {}).get("backend", {}))
    except (FixtureError, OSError) as exc:
        record["error"] = str(exc)
    write_json(run_path, record)
    # This is an incomplete form for an external producer to fill in. It is
    # deliberately rejected by compare until version, origin and hash exist.
    template = {"format_version": 1, "input_sha256": inp["sha256"],
                "params_sha256": manifest["params"]["sha256"],
                "resources_sha256": snapshot["baked_sha256"],
                "width": inp["width"], "height": inp["height"], "row_order": "top_down",
                "output_color_space": manifest["output_contract"]["color_space"],
                "output_transfer": manifest["output_contract"]["transfer"],
                "reference_sha256": "", "reference_version": "", "producer": "", "reference_backend": ""}
    write_json(template_path, template)
    return record


def compare_pixels(got: np.ndarray, reference: np.ndarray) -> dict:
    require(got.ndim == 3 and got.shape[2] == 4 and got.dtype == np.dtype("<u2"),
            "got must contain RGBA uint16 pixels")
    require(reference.ndim == 3 and reference.shape[2] in (3, 4)
            and reference.shape[:2] == got.shape[:2], "reference dimensions/channels do not match got")
    require(reference.dtype.kind == "f" and reference.dtype.itemsize in (4, 8),
            ".npy reference must contain float32 or float64 encoded RGB values")
    require(bool(np.isfinite(reference).all()), "reference contains NaN or infinity")
    if reference.shape[2] == 4:
        require(bool((reference[..., 3] == 1.0).all()), "reference alpha must be opaque (1.0)")
    want = reference[..., :3]
    counts_a = got[..., :3].astype(np.int32)
    count_delta = np.abs(counts_a - to_counts(want).astype(np.int32))
    delta = np.abs(counts_a.astype(np.float64) / 65535.0 - np.clip(want.astype(np.float64), 0.0, 1.0))
    over = int((count_delta > COUNT_TOLERANCE).sum())
    maximum = float(delta.max())
    fraction = over / count_delta.size
    return {"passed": bool(maximum <= FLOAT_TOLERANCE and fraction <= COUNT_OUTLIER_FRACTION),
            "max_abs_float": maximum, "max_abs_counts": int(count_delta.max()),
            "count_outliers": over, "compared_rgb_values": int(count_delta.size),
            "count_outlier_fraction": fraction,
            "worst_location_hwc": list(map(int, np.unravel_index(int(delta.argmax()), delta.shape)))}


def compare_fixture(fixture_dir: Path, got: Path, reference: Path,
                    reference_metadata: Path, report_path: Path) -> dict:
    fixture_dir, got, reference, reference_metadata, report_path = (p.resolve() for p in
        (fixture_dir, got, reference, reference_metadata, report_path))
    protected = [got, reference, reference_metadata, got.parent / "run.json", got.parent / "render.json",
                 *[fixture_dir / name for name in ("input.f32", "params.json", "manifest.json")]]
    protect_output(report_path, protected)
    record = {"format_version": 1, "status": "invalid", "verification": "unverified",
              "got_path": str(got), "reference_path": str(reference),
              "thresholds": {"max_abs_float": FLOAT_TOLERANCE, "count_tolerance": COUNT_TOLERANCE,
                             "max_count_outlier_fraction": COUNT_OUTLIER_FRACTION}}
    try:
        require(not same_file(got, reference), "reference must be a separate external artifact, not got itself")
        manifest, _ = validate_fixture(fixture_dir)
        run = read_json(got.parent / "run.json")
        require(run.get("format_version") == 1 and run.get("status") == "rendered"
                and run.get("producer") == PRODUCER, "got lacks a successful fixture run record")
        require(all(isinstance(run.get(key), dict) for key in ("output", "resources", "backend")),
                "got run record has invalid output/resources/backend objects")
        require(run.get("output", {}).get("sha256") == sha256_file(got), "got SHA-256 does not match run record")
        contract = manifest["output_contract"]
        require(run.get("input_sha256") == manifest["input"]["sha256"]
                and run.get("params_sha256") == manifest["params"]["sha256"]
                and run.get("output_contract") == contract, "got was produced for a different fixture/contract")
        baked = manifest.get("resource_contract", {}).get("baked_sha256")
        require(baked and run.get("resources", {}).get("baked_sha256") == baked,
                "got baked resource version does not match fixture")
        meta = read_json(reference_metadata)
        require(meta.get("format_version") == 1, "unsupported reference metadata format_version")
        expected = {"input_sha256": manifest["input"]["sha256"],
                    "params_sha256": manifest["params"]["sha256"], "resources_sha256": baked,
                    "width": contract["width"], "height": contract["height"], "row_order": "top_down",
                    "output_color_space": contract["color_space"], "output_transfer": contract["transfer"],
                    "reference_sha256": sha256_file(reference)}
        for key, value in expected.items():
            require(meta.get(key) == value, f"reference metadata differs at {key}")
        for key in ("producer", "reference_version", "reference_backend"):
            require(isinstance(meta.get(key), str) and bool(meta[key].strip()), f"reference {key} must be non-empty")
        require(meta["producer"].strip().casefold() not in (PRODUCER, "spk_render_fixture"),
                "the Windows fixture driver cannot be its own external reference")
        backend = run.get("backend", {}).get("render_core")
        require(not backend or meta["reference_backend"].strip().casefold() != str(backend).casefold(),
                "reference backend must differ from the Windows backend being validated")
        rgba = read_rgba16(got, contract["width"], contract["height"])
        if reference.suffix.lower() == ".npy":
            want = np.load(reference, allow_pickle=False)
        elif reference.suffix.lower() == ".rgba16":
            want = read_rgba16(reference, contract["width"], contract["height"]).astype(np.float64) / 65535.0
        else:
            raise FixtureError("reference must be .npy (encoded RGB floats) or packed little-endian .rgba16")
        metrics = compare_pixels(rgba, want)
        record.update(status="passed" if metrics["passed"] else "failed",
                      verification="compared_to_declared_external_reference", metrics=metrics,
                      reference_metadata=meta, reference_metadata_sha256=sha256_file(reference_metadata),
                      got_sha256=sha256_file(got), input_sha256=manifest["input"]["sha256"],
                      params_sha256=manifest["params"]["sha256"], resources_sha256=baked,
                      reference_representation="encoded_float" if reference.suffix.lower() == ".npy" else "quantized_rgba16",
                      provenance_note="External origin is declared by metadata; this tool does not independently prove it.")
    except (FixtureError, OSError, ValueError) as exc:
        record["error"] = str(exc)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    write_json(report_path, record)
    return record


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    generate = commands.add_parser("generate", help="write deterministic already-decoded RGB float32 pixels")
    generate.add_argument("--output-dir", type=Path, required=True)
    generate.add_argument("--size", type=int, default=180, help="height in pixels; width is floor(height * 4/3)")
    run = commands.add_parser("run", help="execute the DLL-backed driver; parity remains unverified")
    for name in ("driver", "resources", "fixture-dir", "output-dir"):
        run.add_argument(f"--{name}", type=Path, required=True)
    compare = commands.add_parser("compare", help="compare with a separate externally produced reference")
    for name in ("fixture-dir", "got", "reference", "reference-metadata", "report"):
        compare.add_argument(f"--{name}", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "generate":
            result = generate_fixture(args.output_dir, args.size)
            print(f"generated {result['input']['width']}x{result['input']['height']} RGB float32; parity unverified")
            return 0
        if args.command == "run":
            result = run_fixture(args.driver, args.resources, args.fixture_dir, args.output_dir)
            print(f"execution {result['status']}; parity unverified")
            if "error" in result:
                print(result["error"], file=sys.stderr)
            return 0 if result["status"] == "rendered" else 1
        result = compare_fixture(args.fixture_dir, args.got, args.reference, args.reference_metadata, args.report)
        print(f"comparison {result['status']}: {result.get('metrics', result.get('error', ''))}")
        return {"passed": 0, "failed": 1, "invalid": 2}[result["status"]]
    except (FixtureError, OSError) as exc:
        print(f"{args.command}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
