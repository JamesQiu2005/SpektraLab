"""Check Windows C ABI ownership, cache reuse, and bounded allocation ledgers.

This is a manual integration gate against a built DLL. It deliberately keeps
raw SpkResult allocations alive; Session.render normally copies and frees them
before returning and therefore cannot test the output ownership contract.
"""
from __future__ import annotations

import argparse
import ctypes
import gc
import hashlib
from pathlib import Path
import sys
import weakref

import numpy as np

from windows_render_matrix import BASE, COMMON
from windows_fixture import FixtureError, require, resource_snapshot, sha256_file, write_json
from spk_ctypes import Engine, EngineError, SpkResult, SPK_OK


def frame(height: int, width: int) -> np.ndarray:
    x = np.linspace(0.0, 1.0, width, dtype=np.float32)[None, :]
    y = np.linspace(0.0, 1.0, height, dtype=np.float32)[:, None]
    image = np.empty((height, width, 3), dtype=np.float32)
    image[..., 0] = 0.02 + 0.75 * x + 0.12 * y
    image[..., 1] = 0.03 + 0.55 * y + 0.2 * x
    image[..., 2] = 0.04 + 0.65 * (1.0 - x) * (1.0 - y)
    return image


class OwnedResult:
    def __init__(self, session, tier: str = "full", reprint: bool = False):
        self.lib = session._engine._lib
        self.result = SpkResult()
        self.freed = False
        fn = self.lib.spk_reprint if reprint else self.lib.spk_render
        status = fn(session._handle, tier.encode(), ctypes.byref(self.result))
        try:
            require(status == SPK_OK, session._engine._last_error())
            r = self.result
            require(bool(r.rgba16) and bool(r.texture) and r.width > 0 and r.height > 0
                    and r.row_stride_px >= r.width, "invalid owned result layout")
        except Exception:
            self.close()
            raise

    def pixels(self) -> np.ndarray:
        require(not self.freed, "attempted to read a freed test result")
        r = self.result
        flat = np.ctypeslib.as_array(r.rgba16, shape=(r.height * r.row_stride_px * 4,))
        return flat.reshape(r.height, r.row_stride_px, 4)[:, :r.width]

    def digest(self) -> str:
        return hashlib.sha256(self.pixels().tobytes(order="C")).hexdigest()

    def info(self) -> dict:
        r = self.result
        return {"width": r.width, "height": r.height, "row_stride_px": r.row_stride_px,
                "elapsed_ms": r.elapsed_ms, "reprint": bool(r.reprint),
                "negative_was_cached": bool(r.negative_was_cached), "sha256": self.digest()}

    def close(self) -> None:
        if not self.freed:
            self.lib.spk_result_free(ctypes.byref(self.result))
            self.freed = True

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


def check_ledger(report: dict) -> None:
    pool, persistent = report["pool"], report["persistent"]
    require(pool["total_bytes"] == sum(pool[name] for name in
            ("live_bytes", "free_bytes", "pending_bytes")), "pool byte partitions disagree")
    require(pool["buffers"] == sum(pool[name] for name in
            ("live_buffers", "free_buffers", "pending_buffers")), "pool count partitions disagree")
    require(report["total_bytes"] == pool["total_bytes"] + persistent["bytes"],
            "total allocation ledger does not equal pool plus persistent")
    require(pool["live_bytes"] == 0 and pool["pending_bytes"] == 0,
            "render boundary retains pooled live or pending memory")
    require(pool["live_buffers"] == 0 and pool["pending_buffers"] == 0,
            "render boundary retains pooled live or pending buffers")
    for name in ("pending_held", "over_releases", "reclaim_while_encoding", "live_underflows"):
        require(pool["audit"][name] == 0, f"pool audit violation: {name}")
    rows = persistent["sessions"]
    for name in ("source_bytes", "cached_negative_bytes"):
        require(persistent[name] == sum(row[name] for row in rows),
                f"session allocation ledger mismatch: {name}")


def stable_ledger(report: dict) -> dict:
    # Cumulative allocation/reuse counters must grow; retained bytes and buffer
    # counts after an identical warmed cycle must not.
    return {"total_bytes": report["total_bytes"],
            "pool": {name: report["pool"][name] for name in
                     ("total_bytes", "live_bytes", "free_bytes", "pending_bytes", "buffers",
                      "live_buffers", "free_buffers", "pending_buffers")},
            "persistent": {name: report["persistent"][name] for name in
                           ("bytes", "buffers", "source_bytes", "cached_negative_bytes", "negatives")}}


def difference_stats(actual: np.ndarray, expected: np.ndarray) -> dict:
    require(actual.shape == expected.shape, "comparison image dimensions differ")
    delta = np.abs(actual.astype(np.int32) - expected.astype(np.int32))
    changed = delta != 0
    return {"bit_exact": not bool(changed.any()), "changed_channel_values": int(changed.sum()),
            "changed_pixels": int(changed.any(axis=2).sum()),
            "maximum_absolute_u16": int(delta.max()),
            "changed_values_per_channel": changed.sum(axis=(0, 1)).tolist(),
            "maximum_absolute_u16_per_channel": delta.max(axis=(0, 1)).tolist()}


def run(args) -> dict:
    output = args.output.resolve()
    require(not output.exists(), "output report already exists; use a new path")
    output.parent.mkdir(parents=True, exist_ok=True)
    report = {"format_version": 1, "success": False, "cases": {},
              "verification": "c_api_lifetime_cache_and_allocation_ledger",
              "external_parity": "unverified",
              "memory_scope": "engine allocation ledger; not measured physical VRAM residency",
              "harness_sha256": sha256_file(Path(__file__).resolve()),
              "params_delta": {**COMMON, **BASE, "preview_long_edge": 800}}
    engine = None
    sessions = []
    held = None
    active_case = None
    try:
        engine = Engine(library=args.library, resources=args.resources)
        report["environment"] = {"library": str(engine.library_path),
            "library_sha256": sha256_file(engine.library_path), "build_info": engine.build_info,
            "resources": str(engine.resources_path), "numpy": np.__version__,
            "capabilities": engine.capabilities()}
        report["resources"] = resource_snapshot(engine.resources_path)
        params = report["params_delta"]
        original = frame(129, 193)
        mutable = original.copy()
        small = engine.open(mutable, params)
        sessions.append(small)

        active_case = "input_copy_independence"
        case = {"success": False}
        report["cases"][active_case] = case
        require(np.shares_memory(mutable, small._keepalive),
                "test input was unexpectedly copied by the Python wrapper")
        source_ref = weakref.ref(mutable)
        mutable.fill(0)
        small._keepalive = None
        del mutable
        gc.collect()
        require(source_ref() is None, "the original input allocation is still retained by Python")
        held = OwnedResult(small)
        held_digest = held.digest()
        require(not held.result.reprint and not held.result.negative_was_cached,
                "full render incorrectly reports a cached negative")
        reference = engine.open(original.copy(), params)
        sessions.append(reference)
        with OwnedResult(reference) as expected:
            require(np.array_equal(held.pixels(), expected.pixels()),
                    "changing/freeing caller input changed the engine's source")
            case["reference"] = expected.info()
        reference.close()
        require(held.digest() == held_digest, "a later render changed the retained output")
        case.update(success=True, input_python_allocation_released=True, bit_exact=True,
                    retained_output=held.info())

        active_case = "multi_session_and_cache_cycles"
        case = {"success": False, "warm": [], "cycles": []}
        report["cases"][active_case] = case
        large = engine.open(frame(601, 901), params)
        sessions.append(large)
        pair = (("small", small), ("large", large))
        tiers = ("full", "live", "preview")
        references = {}
        for tier in tiers:
            for label, session in pair:
                with OwnedResult(session, tier) as result:
                    info = result.info()
                    require(not info["reprint"] and not info["negative_was_cached"],
                            "a forced render reported negative reuse")
                    expected_edge = 193 if label == "small" else (800 if tier == "live" else 901)
                    require(max(info["width"], info["height"]) == expected_edge,
                            "tier dimensions do not match preview_long_edge")
                    references[label, tier] = info["sha256"]
                    case["warm"].append({"session": label, "tier": tier, **info})
        for cycle in range(3):
            calls = []
            for tier in tiers:
                for label, session in pair:
                    for reprint in (False, True):
                        with OwnedResult(session, tier, reprint=reprint) as result:
                            info = result.info()
                            require(info["reprint"] == reprint and info["negative_was_cached"] == reprint,
                                    "forced render/reprint cache flags disagree")
                            require(info["sha256"] == references[label, tier],
                                    "deterministic output changed between sessions or cycles")
                            require(held.digest() == held_digest,
                                    "a subsequent render rewrote a retained output")
                            calls.append({"session": label, "tier": tier, **info})
            memory = engine.memory_report()
            check_ledger(memory)
            require(len(memory["persistent"]["sessions"]) == 2, "expected two live sessions")
            require(memory["persistent"]["negatives"] == 6, "expected three negatives per session")
            case["cycles"].append({"cycle": cycle + 1, "calls": calls, "memory": memory})
        ledgers = [stable_ledger(entry["memory"]) for entry in case["cycles"]]
        require(ledgers[0] == ledgers[1] == ledgers[2],
                "retained allocation ledger grows across identical warmed cycles")
        case.update(success=True, warmed_ledger_stable=True, audit_violations=0)

        active_case = "striped_transfer_regression"
        case = {"success": False, "strip_rows": 17}
        report["cases"][active_case] = case
        strip_params = {**params, "striped": True, "strip_rows": 17}
        # Transfer-only regression preserves both archived paths independently.
        # After a correctness fix, --require-stripe-parity instead requires the
        # new whole/striped outputs to match exactly and records old differences;
        # the historical backend may itself contain the boundary bug being fixed.
        with Engine(library=args.reference_library, resources=args.reference_resources) as reference_engine:
            report["reference_environment"] = {"library": str(reference_engine.library_path),
                "library_sha256": sha256_file(reference_engine.library_path),
                "resources": str(reference_engine.resources_path), "build_info": reference_engine.build_info}
            report["reference_resources"] = resource_snapshot(reference_engine.resources_path)
            require(report["resources"]["baked_sha256"] == report["reference_resources"]["baked_sha256"],
                    "archived and optimized backends do not have identical baked resources")
            with reference_engine.open(original.copy(), params) as old_session:
                with OwnedResult(old_session) as old_result:
                    old_whole = np.array(old_result.pixels(), copy=True)
                    case["reference_whole"] = old_result.info()
            with reference_engine.open(original.copy(), strip_params) as old_session:
                with OwnedResult(old_session) as old_result:
                    old_striped = np.array(old_result.pixels(), copy=True)
                    case["reference_striped"] = old_result.info()
        case["whole_vs_reference"] = difference_stats(held.pixels(), old_whole)
        if not args.require_stripe_parity:
            require(case["whole_vs_reference"]["bit_exact"],
                    "whole-frame output differs from the archived backend")
        striped = engine.open(original.copy(), strip_params)
        sessions.append(striped)
        require(striped.get_params()["striped"] and striped.get_params()["strip_rows"] == 17,
                "striped parameters did not take effect")
        with OwnedResult(striped) as result:
            case["striped_vs_reference"] = difference_stats(result.pixels(), old_striped)
            case["whole_vs_striped"] = difference_stats(result.pixels(), held.pixels())
            case["reference_whole_vs_striped"] = difference_stats(old_striped, old_whole)
            if not args.require_stripe_parity:
                require(case["striped_vs_reference"]["bit_exact"],
                        "striped output differs from the archived backend")
            whole_frame_parity = case["whole_vs_striped"]["bit_exact"]
            if args.require_stripe_parity:
                require(whole_frame_parity, "corrected striped path differs from whole-frame rendering")
            case.update(success=True,
                        validation_mode="strict_stripe_parity" if args.require_stripe_parity else "archived_transfer_regression",
                        transfer_regression_bit_exact=(case["whole_vs_reference"]["bit_exact"] and
                                                       case["striped_vs_reference"]["bit_exact"]),
                        whole_frame_parity=whole_frame_parity, result=result.info(),
                        progress=striped.progress(),
                        pre_existing_issue=None if whole_frame_parity else {
                            "description": "The archived and optimized striped paths have the same discrepancy against whole-frame rendering.",
                            "status": "unresolved; striped whole-frame parity is not asserted by this regression gate",
                            "difference": case["reference_whole_vs_striped"]})
        striped.close()

        active_case = "session_release_and_pool_trim"
        case = {"success": False}
        report["cases"][active_case] = case
        for session in sessions:
            session.close()
        after_release = engine.memory_report()
        check_ledger(after_release)
        require(after_release["persistent"]["source_bytes"] == 0 and
                after_release["persistent"]["cached_negative_bytes"] == 0 and
                after_release["persistent"]["negatives"] == 0 and
                after_release["persistent"]["sessions"] == [],
                "released sessions retain sources or cached negatives")
        require(held.digest() == held_digest, "releasing sessions invalidated the retained output")
        # A new small frame after the prior sessions are gone must trigger the
        # existing frame-switch trim; explicit trim is not a public C API.
        tiny = engine.open(frame(71, 113), params)
        sessions.append(tiny)
        after_reopen = engine.memory_report()
        check_ledger(after_reopen)
        require(after_reopen["pool"]["total_bytes"] <= after_release["pool"]["total_bytes"] // 10,
                "opening a small frame retained the old frame's pool")
        tiny.close()
        case.update(success=True, after_release=after_release, after_small_reopen=after_reopen)

        active_case = "result_survives_engine_destruction"
        case = {"success": False}
        report["cases"][active_case] = case
        engine.close()
        gc.collect()
        require(held.digest() == held_digest, "destroying the engine invalidated its returned pixels")
        case.update(success=True, sha256_after_destroy=held.digest())
        held.close()  # spk_result_free must also be valid without a live engine.
        case["freed_after_engine_destroy"] = True
        report["success"] = True
    except Exception as exc:
        report["error"] = str(exc)
        report["failed_case"] = active_case
        raise
    finally:
        try:
            # Results and sessions are released on failures too; keep the
            # engine alive until the sessions have dropped their GPU handles.
            if engine is not None and engine._handle:
                for session in reversed(sessions):
                    session.close()
            if held is not None:
                held.close()
            if engine is not None:
                engine.close()
        finally:
            write_json(output, report)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--reference-library", type=Path, required=True,
                        help="archived pre-optimization DLL for independent whole/striped regression")
    parser.add_argument("--reference-resources", type=Path, required=True)
    parser.add_argument("--require-stripe-parity", action="store_true",
                        help="require corrected stripes to equal whole-frame exactly; record old-backend differences")
    parser.add_argument("--output", type=Path, required=True, help="new JSON report path")
    args = parser.parse_args()
    try:
        report = run(args)
        print(f"lifecycle: {len(report['cases'])} cases passed; {args.output}")
        return 0
    except (FixtureError, EngineError, OSError, ValueError) as exc:
        print(f"lifecycle failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
