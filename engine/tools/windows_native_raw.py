"""Test the native RAW CLI independently of Python/rawpy at runtime.

Python is only the test runner and C ABI oracle. The native process receives a
standalone runtime directory and a restricted PATH. Decode equality is strict
against the existing, SHA-bound rawpy compat16 fixture; no tolerance is silently
introduced for a different LibRaw version. TIFF is decoded by the small
independent baseline-TIFF reader below, retaining all 16 bits per channel.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

import numpy as np

from windows_fixture import read_json, require, resource_snapshot, sha256_file, write_json
from windows_render_matrix import BASE, COMMON, Engine, load_input, render


TIFF_TYPES = {1: (1, "B"), 2: (1, "B"), 3: (2, "H"), 4: (4, "I"),
              5: (8, None), 7: (1, "B"), 9: (4, "i"), 10: (8, None),
              11: (4, "f"), 12: (8, "d")}


def read_rgb16_tiff(path: Path, expected_icc: bytes) -> tuple[np.ndarray, dict]:
    """Read one classic, uncompressed, chunky RGB16 TIFF without image codecs."""
    size = path.stat().st_size
    with path.open("rb") as stream:
        def chunk(offset, count):
            require(0 <= offset <= size and 0 <= count <= size - offset,
                    "TIFF field or strip points outside its file")
            stream.seek(offset)
            value = stream.read(count)
            require(len(value) == count, "TIFF changed or was truncated while reading")
            return value

        header = chunk(0, 8)
        require(header[:2] in (b"II", b"MM"), "TIFF byte-order marker is invalid")
        endian = "<" if header[:2] == b"II" else ">"
        magic, ifd = struct.unpack(endian + "HI", header[2:])
        require(magic == 42 and ifd >= 8, "expected classic TIFF with a valid first IFD")
        count = struct.unpack(endian + "H", chunk(ifd, 2))[0]
        entries = chunk(ifd + 2, count * 12 + 4)
        require(struct.unpack_from(endian + "I", entries, count * 12)[0] == 0,
                "native export must contain one image")
        tags = {}
        for i in range(count):
            entry = entries[i * 12:(i + 1) * 12]
            tag, kind, length = struct.unpack_from(endian + "HHI", entry)
            require(tag not in tags and kind in TIFF_TYPES and length > 0,
                    f"invalid or duplicate TIFF tag {tag}")
            item_size, code = TIFF_TYPES[kind]
            byte_count = item_size * length
            payload = entry[8:8 + byte_count] if byte_count <= 4 else chunk(
                struct.unpack_from(endian + "I", entry, 8)[0], byte_count)
            values = struct.unpack(endian + str(length) + code, payload) if code else ()
            tags[tag] = {"type": kind, "count": length, "bytes": payload, "values": values}

        def numbers(tag, default=None):
            if tag not in tags:
                require(default is not None, f"TIFF tag {tag} is missing")
                return default
            require(tags[tag]["type"] in (3, 4), f"TIFF tag {tag} must be SHORT or LONG")
            return tags[tag]["values"]

        def scalar(tag, default=None):
            values = numbers(tag, None if default is None else (default,))
            require(len(values) == 1, f"TIFF tag {tag} must be scalar")
            return values[0]

        width, height = scalar(256), scalar(257)
        require(width > 0 and height > 0 and width * height * 6 <= size,
                "TIFF dimensions exceed its uncompressed payload")
        require(numbers(258) == (16, 16, 16), "TIFF is not three-channel 16-bit output")
        require(scalar(259) == 1 and scalar(262) == 2 and scalar(277) == 3,
                "TIFF must be uncompressed RGB")
        require(scalar(274) == 1 and scalar(284) == 1,
                "TIFF must have top-left orientation and chunky planar configuration")
        require(numbers(339, (1, 1, 1)) in ((1,), (1, 1, 1)),
                "TIFF samples must be unsigned integers")
        require(338 not in tags, "RGB export unexpectedly has extra samples")
        require(34675 in tags and tags[34675]["type"] in (1, 7), "TIFF has no embedded ICC profile")
        icc = tags[34675]["bytes"]
        require(len(icc) >= 128 and struct.unpack_from(">I", icc)[0] == len(icc) and
                icc[36:40] == b"acsp" and icc[16:20] == b"RGB ", "invalid RGB ICC header")
        require(icc == expected_icc, "TIFF embedded ICC differs from the shipped sRGB profile")
        offsets, counts = numbers(273), numbers(279)
        rows_per_strip = scalar(278)
        require(rows_per_strip > 0 and len(offsets) == len(counts) ==
                (height + rows_per_strip - 1) // rows_per_strip, "TIFF strip count is inconsistent")
        regions = sorted(zip(offsets, counts))
        require(all(a + n <= b for (a, n), (b, _) in zip(regions, regions[1:])),
                "TIFF strips overlap")
        pixels = np.empty((height, width, 3), dtype=np.uint16)
        for i, (offset, byte_count) in enumerate(zip(offsets, counts)):
            first_row = i * rows_per_strip
            rows = min(rows_per_strip, height - first_row)
            require(byte_count == rows * width * 6, "TIFF strip byte count does not match its rows")
            payload = chunk(offset, byte_count)
            pixels[first_row:first_row + rows] = np.frombuffer(payload, dtype=endian + "u2").reshape(rows, width, 3)
    return pixels, {"width": width, "height": height, "channels": 3, "bits_per_sample": 16,
                    "compression": "none", "photometric": "RGB", "orientation": "top-left",
                    "color_space": "sRGB", "transfer": "encoded", "rows_per_strip": rows_per_strip,
                    "strip_count": len(offsets), "icc_sha256": hashlib.sha256(icc).hexdigest(),
                    "file_sha256": sha256_file(path), "bytes": size}


def clean_environment() -> dict[str, str]:
    environment = dict(os.environ)
    for key in list(environment):
        if key.upper().startswith("PYTHON") or key.upper().startswith("SPEKTRAFILM_"):
            del environment[key]
    windows = Path(environment.get("SystemRoot", r"C:\Windows"))
    environment["PATH"] = str(windows / "System32") + os.pathsep + str(windows)
    return environment


def make_runtime(driver: Path, library: Path, resources: Path, destination: Path) -> dict:
    destination.mkdir()
    files = [driver, *sorted(driver.parent.glob("*.dll"))]
    if not any(path.name.lower() == library.name.lower() for path in files):
        files.append(library)
    else:
        require(any(path.name.lower() == library.name.lower() and sha256_file(path) == sha256_file(library)
                    for path in files), "CLI-adjacent engine DLL differs from the selected C ABI oracle")
    require(any(path.name.lower() == "spektrafilm_engine.dll" for path in files),
            "standalone test bundle is missing the C ABI oracle DLL")
    inventory = {}
    for path in files:
        require(path.is_file(), f"runtime input is missing: {path}")
        target = destination / path.name
        shutil.copy2(path, target)
        inventory[path.name] = {"bytes": target.stat().st_size, "sha256": sha256_file(target)}
    shutil.copytree(resources, destination / "resources")
    notices = driver.parent / "third-party"
    license_inventory = {}
    if notices.is_dir():
        shutil.copytree(notices, destination / "third-party")
        license_inventory = {path.relative_to(notices).as_posix(): sha256_file(path)
                             for path in sorted(notices.rglob("*")) if path.is_file()}
    return {"files": inventory, "resources": resource_snapshot(destination / "resources"),
            "third_party_notices": license_inventory,
            "process_path": clean_environment()["PATH"], "python_environment_removed": True,
            "engine_dll_role": "independent Python C ABI test oracle; native CLI may link engine statically"}


def execute(command: list[str], cwd: Path, timeout: float, log: Path) -> dict:
    start = time.perf_counter()
    result = subprocess.run(command, cwd=cwd, env=clean_environment(), capture_output=True,
                            timeout=timeout, check=False)
    output = {"command": command, "returncode": result.returncode,
              "wall_ms": (time.perf_counter() - start) * 1000,
              "stdout": result.stdout.decode("utf-8", errors="replace"),
              "stderr": result.stderr.decode("utf-8", errors="replace")}
    write_json(log, output)
    return output


def execute_publish_race(command: list[str], cwd: Path, report_path: Path,
                         timeout: float, log: Path) -> tuple[dict, bytes]:
    """Create a competing report only after the native process starts staging.

    A missed scheduling window is a failed test, never a successful race test.
    The CLI publishes TIFF/decoded files before the report; its report collision
    must roll back those already-published files without deleting our sentinel.
    """
    sentinel = b"Publish-race sentinel: this file belongs to the competing writer.\n"
    require(not report_path.exists() and not list(cwd.glob(".spk-*.tmp")),
            "publish-race directory is not fresh")
    start = time.perf_counter()
    process = subprocess.Popen(command, cwd=cwd, env=clean_environment(),
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    injection = {"created_after_process_start": False, "temporary_file_seen": None,
                 "temporary_seen_ms": None, "sentinel_created_ms": None}
    stdout, stderr = b"", b""
    try:
        while process.poll() is None:
            if time.perf_counter() - start >= timeout:
                raise subprocess.TimeoutExpired(command, timeout)
            pending = list(cwd.glob(".spk-*.tmp"))
            if pending:
                injection["temporary_file_seen"] = pending[0].name
                injection["temporary_seen_ms"] = (time.perf_counter() - start) * 1000
                try:
                    with report_path.open("xb") as stream:
                        stream.write(sentinel)
                    injection["created_after_process_start"] = True
                    injection["sentinel_created_ms"] = (time.perf_counter() - start) * 1000
                except FileExistsError:
                    injection["missed_window"] = "native report was already published"
                break
            time.sleep(0.001)
        remaining = max(0.001, timeout - (time.perf_counter() - start))
        stdout, stderr = process.communicate(timeout=remaining)
    except BaseException:
        process.kill()
        stdout, stderr = process.communicate()
        raise
    finally:
        output = {"command": command, "returncode": process.returncode,
                  "wall_ms": (time.perf_counter() - start) * 1000,
                  "stdout": stdout.decode("utf-8", errors="replace"),
                  "stderr": stderr.decode("utf-8", errors="replace"), "race": injection}
        write_json(log, output)
    require(injection["created_after_process_start"] and injection["temporary_file_seen"] is not None,
            "publish race missed its staging window; this is not a passing rollback test")
    require("publish" in output["stderr"].lower(), "publish race failed before the intended publication collision")
    require("rolling back published outputs=2" in output["stderr"],
            "publish race did not confirm that both earlier outputs were already published")
    output["race"]["published_outputs_before_failure"] = 2
    write_json(log, output)
    return output, sentinel


def native_report(path: Path, height: int, width: int) -> dict:
    report = read_json(path)
    require(report.get("success") is True, "native report did not record success")
    require(report.get("input", {}).get("width") == width and
            report.get("input", {}).get("height") == height, "native report dimensions differ from oriented fixture")
    require(report["input"].get("color_space") == "ProPhoto RGB" and
            report["input"].get("transfer") == "linear", "native report mislabels decoded input")
    decode = report.get("decode", {})
    require(isinstance(decode.get("libraw_version"), str) and decode["libraw_version"],
            "native report has no LibRaw version")
    require(bool(decode.get("policy")), "native report has no explicit decode policy")
    require(decode.get("preserves_negative_rgb") is False and decode.get("preserves_above_one_rgb") is False,
            "compatible16 report must explicitly disclose clipped negative/highlight RGB")
    require(all(report.get("resolved_params", {}).get(key) == value
                for key, value in {**COMMON, **BASE, "extended_dynamic_range": False}.items()),
            "native CLI resolved unexpected parameters")
    require(report.get("output", {}).get("width") == width and report["output"].get("height") == height and
            report["output"].get("color_space") == "sRGB" and report["output"].get("output_cctf_encoding") is True,
            "native report mislabels TIFF dimensions or color")
    timings = report.get("timings_ms", {})
    require(isinstance(timings, dict) and bool(timings), "native report has no stage timings")
    require({"decode", "engine_create", "open", "render", "write"}.issubset(timings),
            "native report omits a required timing stage")
    for key, value in timings.items():
        require(isinstance(value, (float, int)) and not isinstance(value, bool) and
                math.isfinite(value) and value >= 0, f"invalid native timing: {key}")
    return report


def difference_stats(actual: np.ndarray, expected: np.ndarray) -> dict:
    require(actual.shape == expected.shape, "compared pixel dimensions differ")
    changed, maximum = 0, 0.0
    for row in range(0, actual.shape[0], 128):
        a, b = actual[row:row + 128], expected[row:row + 128]
        require(bool(np.isfinite(a).all()) and bool(np.isfinite(b).all()), "non-finite decoded/reference pixels")
        changed += int(np.count_nonzero(a != b))
        maximum = max(maximum, float(np.abs(a.astype(np.float64) - b.astype(np.float64)).max(initial=0)))
    return {"bit_exact": changed == 0, "changed_channel_values": changed, "maximum_absolute_error": maximum}


def failure_cases(driver: Path, resources: Path, raw: Path, params: Path,
                  output: Path, timeout: float) -> dict:
    results = {}
    definitions = [
        ("existing_tiff", None), ("existing_report", None), ("existing_decoded", None),
        ("output_is_input", None), ("output_is_params", None),
        ("output_is_report", None), ("output_is_decoded", None),
        ("report_is_decoded", None), ("unknown_raw", None), ("missing_raw", None),
        ("missing_resources", None), ("unknown_option", None),
        ("input_space_conflict", {"input_color_space": "sRGB"}),
        ("input_encoding_conflict", {"input_cctf_decoding": True}),
        ("output_space_conflict", {"output_color_space": "ProPhoto RGB"}),
        ("output_encoding_conflict", {"output_cctf_encoding": False}),
        ("hdr_output_conflict", {"extended_dynamic_range": True}),
        ("unknown_parameter", {"not_a_spektrafilm_parameter": True}),
        ("malformed_params", b"{this is invalid JSON"),
        ("nul_in_params", b'{"grain_active":false}\x00'),
        ("non_object_params", b"[]"),
        ("corrupt_icc_rollback", None), ("publish_race_rollback", None),
        ("invalid_decode_mode", None), ("duplicate_decode_mode", None), ("missing_decode_mode", None),
    ]
    for name, delta in definitions:
        case_dir = output / name
        case_dir.mkdir()
        source, config, res = raw, params, resources
        tiff, report, decoded = case_dir / "result.tif", case_dir / "report.json", case_dir / "decoded.f32"
        protected = {}
        if name.startswith("existing_"):
            existing = {"existing_tiff": tiff, "existing_report": report, "existing_decoded": decoded}[name]
            existing.write_bytes(b"Preserve this existing file exactly.\n")
            protected[existing] = sha256_file(existing)
        if name == "output_is_input":
            tiff = raw
            protected[raw] = sha256_file(raw)
        elif name == "output_is_params":
            tiff = params
            protected[params] = sha256_file(params)
        elif name == "output_is_report": report = tiff
        elif name == "output_is_decoded": decoded = tiff
        elif name == "report_is_decoded": decoded = report
        elif name == "unknown_raw":
            source = case_dir / "unsupported.ARW"
            source.write_bytes(b"This is not a camera RAW file.\n")
        elif name == "missing_raw": source = case_dir / "missing.ARW"
        elif name == "missing_resources": res = case_dir / "missing-resources"
        elif name == "corrupt_icc_rollback":
            res = case_dir / "resources-with-invalid-icc"
            shutil.copytree(resources, res)
            icc = res / "io" / "sRGB.icc"
            bad_profile = bytearray(icc.read_bytes())
            require(len(bad_profile) >= 40, "ICC test resource is too short")
            bad_profile[36:40] = b"BAD!"
            icc.write_bytes(bad_profile)
        if delta is not None:
            config = case_dir / "params.json"
            if isinstance(delta, bytes): config.write_bytes(delta)
            else: write_json(config, {**COMMON, **BASE, **delta})
        command = [str(driver), "--input", str(source), "--output", str(tiff), "--report", str(report),
                   "--resources", str(res), "--params", str(config), "--decoded-output", str(decoded)]
        if name == "unknown_option": command += ["--unrecognised-option"]
        if name == "invalid_decode_mode": command += ["--decode-mode", "automatic-hdr"]
        if name == "duplicate_decode_mode": command += ["--decode-mode", "compatible16", "--decode-mode", "headroom"]
        if name == "missing_decode_mode": command += ["--decode-mode"]
        if name == "publish_race_rollback":
            run, sentinel = execute_publish_race(command, case_dir, report, timeout, case_dir / "process.json")
            protected[report] = hashlib.sha256(sentinel).hexdigest()
        else:
            run = execute(command, case_dir, timeout, case_dir / "process.json")
        require(run["returncode"] != 0, f"native CLI accepted negative case {name}")
        require(bool(run["stderr"].strip() or run["stdout"].strip()), f"native CLI failed silently: {name}")
        if name == "corrupt_icc_rollback":
            require("icc" in run["stderr"].lower(), "corrupt ICC test did not reach profile validation")
        for path, digest in protected.items():
            require(path.is_file() and sha256_file(path) == digest, f"native CLI modified protected file in {name}")
        for path in {tiff, decoded} - set(protected):
            require(not path.exists(), f"native CLI left partial image/decoded output in {name}: {path}")
        if report.exists() and report not in protected:
            require(read_json(report).get("success") is False, f"failed CLI left a successful report in {name}")
        require(not list(case_dir.glob(".spk-*.tmp")), f"native CLI left temporary output files in {name}")
        results[name] = {"passed": True, "returncode": run["returncode"], "wall_ms": run["wall_ms"]}
        if "race" in run:
            results[name]["race"] = run["race"]
        print(f"native CLI rejection {name}: passed", flush=True)
    return results


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--driver", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True, help="original RAW used by the existing fixture")
    parser.add_argument("--fixture", type=Path, required=True, help="existing full-size rawpy float32 fixture")
    parser.add_argument("--fixture-metadata", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args()
    for key in ("driver", "library", "resources", "input", "fixture", "fixture_metadata", "output"):
        setattr(args, key, getattr(args, key).resolve())
    require(not args.output.exists(), "test output already exists; choose a fresh directory")
    require(args.timeout > 0, "timeout must be positive")
    args.output.mkdir(parents=True)
    report = {"success": False, "external_engine_parity": "unverified",
              "verification": "native_compat16_decode_and_independent_tiff_c_abi_pixel_gate",
              "harness_sha256": sha256_file(Path(__file__)), "cases": {}}
    try:
        fixture_meta = read_json(args.fixture_metadata)
        require(fixture_meta.get("downsample") == 1, "native comparison requires the full-size fixture")
        source_hash = sha256_file(args.input)
        require(fixture_meta.get("source_sha256") == source_hash, "RAW and fixture source hashes differ")
        height, width = fixture_meta["height"], fixture_meta["width"]
        fixture, report["fixture"] = load_input(args.fixture, width, height, args.fixture_metadata)
        report["raw_source"] = {"file": str(args.input), "sha256": source_hash, "bytes": args.input.stat().st_size}
        runtime = args.output / "runtime"
        report["runtime"] = make_runtime(args.driver, args.library, args.resources, runtime)
        driver, resources = runtime / args.driver.name, runtime / "resources"
        unicode_dir = args.output / "照片 空格 🧪"
        unicode_dir.mkdir()
        raw, params = unicode_dir / "原始 照片 🧪.ARW", unicode_dir / "渲染 参数 🧪.json"
        shutil.copy2(args.input, raw)
        write_json(params, {**COMMON, **BASE})
        tiff, native_json = unicode_dir / "胶片 成片 🧪.tif", unicode_dir / "处理 报告 🧪.json"
        decoded = unicode_dir / "线性 像素 🧪.f32"
        command = [str(driver), "--input", str(raw), "--output", str(tiff), "--report", str(native_json),
                   "--resources", str(resources), "--params", str(params), "--decoded-output", str(decoded)]
        run = execute(command, unicode_dir, args.timeout, args.output / "native-process.json")
        report["native_process"] = run
        require(run["returncode"] == 0, "native RAW CLI failed: " + run["stderr"])
        require(tiff.is_file() and native_json.is_file() and decoded.is_file(), "native success omitted an output")
        report["native_report"] = native_report(native_json, height, width)
        require(decoded.stat().st_size == fixture.nbytes, "native decoded byte count differs from fixture")
        native_pixels = np.memmap(decoded, dtype="<f4", mode="r", shape=fixture.shape)
        report["decode_comparison"] = difference_stats(native_pixels, fixture)
        report["decode_comparison"].update(native_sha256=sha256_file(decoded),
            fixture_sha256=sha256_file(args.fixture), native_libraw=report["native_report"]["decode"]["libraw_version"],
            fixture_libraw=fixture_meta["libraw_version"])
        del native_pixels
        require(report["decode_comparison"]["bit_exact"] and
                report["decode_comparison"]["native_sha256"] == report["decode_comparison"]["fixture_sha256"],
                "native decode differs from rawpy fixture; investigate decoder versions/build options before changing any threshold")
        icc_path = resources / "io" / "sRGB.icc"
        require(icc_path.is_file(), "runtime has no shipped sRGB ICC profile")
        tiff_pixels, report["tiff"] = read_rgb16_tiff(tiff, icc_path.read_bytes())
        with Engine(library=runtime / args.library.name, resources=resources) as engine:
            with engine.open(fixture, {**COMMON, **BASE}) as session:
                resolved = session.get_params()
                require(all(resolved.get(key) == value for key, value in {**COMMON, **BASE}.items()),
                        "C ABI reference resolved unexpected parameters")
                expected, info = render(session, (height, width, 4))
                report["reference_render"] = {"info": info, "resolved_params": resolved}
        report["tiff_comparison"] = difference_stats(tiff_pixels, expected[..., :3])
        require(report["tiff_comparison"]["bit_exact"], "TIFF pixels differ from direct C ABI RGBA16 RGB channels")
        del tiff_pixels, expected, fixture
        report["unicode_paths_passed"] = ["RAW input", "params", "TIFF output", "JSON report", "decoded float32"]
        print("native RAW decode and TIFF pixels: byte-exact", flush=True)
        negative_dir = args.output / "negative-cases"
        negative_dir.mkdir()
        report["cases"] = failure_cases(driver, resources, raw, params, negative_dir, args.timeout)
        require(sha256_file(args.input) == source_hash and sha256_file(raw) == source_hash,
                "native CLI changed an input RAW")
        report["success"] = True
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        write_json(args.output / "report.json", report)


if __name__ == "__main__":
    main()
