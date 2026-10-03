"""Measure full C ABI latency in independent processes, including CPU RGBA16 delivery.

Input is already decoded linear ProPhoto RGB. This does not measure RAW decoding
or image-file export and never substitutes node timing sums for render latency.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

import numpy as np

from windows_render_matrix import COMMON, Engine, EngineError, SpkResult, SPK_OK, load_input, validate_params
from windows_fixture import require, resource_snapshot, sha256_file, write_json

TARGETS_MS = {"first_full": 5000, "warm_full": 3000, "cached_reprint": 1000}


def sample(session, width, height, kind):
    result = SpkResult()
    fn = session._engine._lib.spk_reprint if kind == "cached_reprint" else session._engine._lib.spk_render
    print(json.dumps({"event": "begin_render", "kind": kind}), flush=True)
    start = time.perf_counter()
    status = fn(session._handle, b"full", ctypes.byref(result))
    elapsed = (time.perf_counter() - start) * 1000
    try:
        if status != SPK_OK:
            raise EngineError(session._engine._last_error())
        require((result.width, result.height) == (width, height), "unexpected full resolution")
        require(bool(result.rgba16) and result.row_stride_px >= width, "invalid result memory")
        cached = bool(result.negative_was_cached)
        require(cached == (kind == "cached_reprint"), "unexpected negative cache state")
        rgba = np.ctypeslib.as_array(result.rgba16, shape=(height * result.row_stride_px * 4,))
        rgba = rgba.reshape(height, result.row_stride_px, 4)[:, :width]
        require(bool((rgba[..., 3] == 65535).all()), "alpha is not opaque")
        row = {"kind": kind, "wall_ms": elapsed, "engine_elapsed_ms": result.elapsed_ms,
               "negative_was_cached": cached, "width": width, "height": height,
               "row_stride_px": result.row_stride_px, "result_bytes": height * result.row_stride_px * 8}
        print(json.dumps({"event": "end_render", **row}), flush=True)
        return row
    finally:
        session._engine._lib.spk_result_free(ctypes.byref(result))


def worker(args):
    # Explicitly clear inherited instrumentation for official measurements.
    os.environ.pop("SPK_DIAGNOSTIC_DEVICE_LOCAL", None)
    for name in ("SPEKTRAFILM_NODE_TIMINGS", "SPEKTRAFILM_TRANSFER_TIMINGS"):
        if args.diagnostic:
            os.environ[name] = "1"
        else:
            os.environ.pop(name, None)
    report = {"success": False, "diagnostic": args.diagnostic, "samples": [],
              "scope": "C ABI full call including negative cache and owned CPU RGBA16; no RAW decode/open/export"}
    try:
        start = time.perf_counter()
        frame, provenance = load_input(args.input, args.width, args.height, args.input_metadata)
        report["input_load_and_validation_ms"] = (time.perf_counter() - start) * 1000
        report["input"] = provenance
        report["library_sha256"] = sha256_file(args.library)
        report["resources"] = resource_snapshot(args.resources)
        start = time.perf_counter()
        with Engine(library=args.library, resources=args.resources) as engine:
            report["engine_create_ms"] = (time.perf_counter() - start) * 1000
            report["build_info"] = engine.build_info
            report["capabilities"] = engine.capabilities()
            start = time.perf_counter()
            with engine.open(frame, COMMON) as session:
                report["open_ms"] = (time.perf_counter() - start) * 1000
                report["resolved_params"] = session.get_params()
                validate_params(report["resolved_params"], "default")
                schedule = ["first_full"] + ["warm_full"] * args.warm + ["cached_reprint"] * args.reprints
                for kind in schedule:
                    row = sample(session, args.width, args.height, kind)
                    row["memory_after_result_free"] = engine.memory_report()
                    if args.diagnostic:
                        row["progress"] = session.progress()
                    report["samples"].append(row)
                    write_json(args.output, report)
        report["success"] = True
    finally:
        write_json(args.output, report)


def orchestrate(args):
    require(not args.output.exists(), "output directory already exists; use a new directory")
    args.output.mkdir(parents=True)
    reports = []
    summary = {"success": False, "diagnostic": args.diagnostic, "processes": args.processes,
               "warm_per_process": args.warm, "reprints_per_process": args.reprints,
               "targets_ms": TARGETS_MS, "runs": reports, "external_parity": "unverified"}
    try:
        for index in range(args.processes):
            output = args.output / f"process-{index + 1}.json"
            cmd = [sys.executable, str(Path(__file__).resolve()), "--worker", "--library", str(args.library),
                   "--resources", str(args.resources), "--input", str(args.input),
                   "--width", str(args.width), "--height", str(args.height), "--output", str(output),
                   "--warm", str(args.warm), "--reprints", str(args.reprints)]
            if args.input_metadata:
                cmd += ["--input-metadata", str(args.input_metadata)]
            if args.diagnostic:
                cmd += ["--diagnostic"]
            with (args.output / f"process-{index + 1}.log").open("w", encoding="utf-8") as log:
                subprocess.run(cmd, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            report = json.loads(output.read_text(encoding="utf-8"))
            require(report["success"], "worker did not complete")
            reports.append(report)
            print(json.dumps({"process": index + 1,
                              "samples": [{"kind": x["kind"], "wall_ms": x["wall_ms"]} for x in report["samples"]]}), flush=True)
        stats = {}
        for kind, target in TARGETS_MS.items():
            values = [x["wall_ms"] for run in reports for x in run["samples"] if x["kind"] == kind]
            stats[kind] = {"count": len(values), "median_ms": statistics.median(values),
                           "min_ms": min(values), "max_ms": max(values),
                           "target_ms": target, "median_target_met": statistics.median(values) <= target}
        summary["statistics"] = stats
        summary["targets_met"] = not args.diagnostic and all(x["median_target_met"] for x in stats.values())
        summary["success"] = True
        print(json.dumps({"targets_met": summary["targets_met"], "statistics": stats}), flush=True)
    finally:
        write_json(args.output / "report.json", summary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--input-metadata", type=Path)
    parser.add_argument("--width", type=int, required=True)
    parser.add_argument("--height", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--processes", type=int, default=3)
    parser.add_argument("--warm", type=int, default=5)
    parser.add_argument("--reprints", type=int, default=5)
    parser.add_argument("--diagnostic", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    require(min(args.processes, args.warm, args.reprints) > 0, "sample counts must be positive")
    worker(args) if args.worker else orchestrate(args)


if __name__ == "__main__":
    main()
