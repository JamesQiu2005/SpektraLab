#!/usr/bin/env python3
"""Bounded host memory/regression checks with owned synthetic fixtures.

Run with the GPU otherwise idle:
  python engine/tests/host_memory.py --host build/engine/host/spektralab-host.exe \
      --resources build/engine/resources

Uses the shipped framed protocol and the host_smoke standard-library client.
This is a lifetime/correctness test, not a RAW memory or timing benchmark.
"""
import argparse
import json
import os
from pathlib import Path
import tempfile
import threading
import time

from host_smoke import Host, write_png


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def good(host, method, params=None):
    header, payload = host.call(method, params)
    require(header.get("ok"), f"{method}: {header.get('error')}")
    return header["result"], payload


def memory(host):
    report, payload = good(host, "memory_report")
    require(not payload, "memory_report returned pixels")
    return report


def temp_files(host):
    if os.name != "nt":
        return {}  # POSIX tmpfile() unlinks the directory entry immediately.
    return {p.name: (p.stat().st_size, p.stat().st_mtime_ns)
            for p in Path(tempfile.gettempdir()).glob(f"spektralab-residency-{host.p.pid}-*.tmp")}


def editor_is_suspended(host, sid, expected_bytes=None):
    report = memory(host)
    rows = report["persistent"]["sessions"]
    require(len(rows) == 1, "private export leaked a session")
    require(rows[0]["residency_suspended"], "editor was not suspended")
    require(rows[0]["source_bytes"] == rows[0]["cached_negative_bytes"] == rows[0]["cached_view_bytes"] == 0,
            "editor image memory remained on GPU")
    require(report["suspended_bytes"] > 0, "suspended snapshot missing from ledger")
    if expected_bytes is not None:
        require(report["suspended_bytes"] == expected_bytes, "batch changed suspended editor bytes")
    return report


def cancelled_export(host, params):
    """Cancel after the worker has opened its private session and emits render."""
    progress = params["progress_id"]
    rid = host.send("export_frame", params)
    cancel_id = None
    while True:
        header, payload = host.read_frame()
        if "event" in header:
            host.events.append(header)
            if header.get("progress_id") == progress and header.get("stage") == "render" and cancel_id is None:
                cancel_id = host.send("cancel", {"session": "", "progress_id": progress})
            continue
        if header.get("id") == rid:
            require(cancel_id is not None, "export completed before cancellation render event")
            require(not header.get("ok") and header.get("error", {}).get("code") == "cancelled",
                    f"running export cancellation failed: {header}")
            require(not payload, "cancelled export returned pixels")
            break
        host.early[header.get("id")] = (header, payload)
    reply, _ = host.wait(cancel_id)
    require(reply.get("ok") and reply["result"].get("was_running"), "cancel did not reach running export")


def exercise(host, directory):
    a, b = directory / "editor.png", directory / "batch.png"
    write_png(str(a), 320, 240)
    write_png(str(b), 960, 640)
    hello, _ = good(host, "hello")
    require("export_frame" in hello["methods"], "host lacks complete export")
    opened, _ = good(host, "open", {"path": str(a), "params": {"auto_exposure": False}})
    sid = opened["session"]
    view = {"session": sid, "tier": "full", "display": "srgb", "generation": 1}
    first, pixels = good(host, "render_view", view)
    require(not first["print_cached"] and pixels, "first view did not render")
    # Diagnostic polling must not keep the scratch pool warm indefinitely.
    started = time.monotonic()
    samples = []
    while time.monotonic() - started < 5.8:
        for method in ("get_params", "progress", "overscan_geometry"):
            good(host, method, {"session": sid})
        samples.append(memory(host))
        time.sleep(0.2)
    require(samples[-1]["pool"]["free_bytes"] == 0, "five-second idle did not trim free GPU pool while polling")
    repeated, again = good(host, "render_view", view)
    require(repeated["print_cached"] and again == pixels, "idle trim changed cached random print")
    print("ok   idle trim under diagnostic polling; cached random print identical", flush=True)

    export = {"source_path": str(b), "format": "png", "color_space": "srgb",
              "params": {"auto_exposure": False}, "overwrite": False}
    rows, files = [], None
    disk_bytes = None
    for n in range(20):
        path = directory / f"batch-{n:02}.png"
        result, payload = good(host, "export_frame", {**export, "path": str(path)})
        require(not payload and path.is_file() and result["width"] == 960, "private export pixels/metadata invalid")
        # UI metadata/progress polling must not bring the entire editor back
        # between batch frames or make metadata depend on successful GPU I/O.
        for method in ("get_params", "progress", "overscan_geometry"):
            good(host, method, {"session": sid})
        report = editor_is_suspended(host, sid, disk_bytes)
        disk_bytes = report["suspended_bytes"]
        rows.append(report)
        current = temp_files(host)
        if files is None:
            files = current
            require(os.name != "nt" or len(files) == 1, "editor snapshot file count is not one")
        require(current == files, "batch recreated or accumulated editor snapshot files")
    require(len({r["persistent"]["bytes"] for r in rows[-10:]}) == 1, "private export persistent GPU memory accumulated")
    print("ok   20 private exports retain one disk snapshot; no persistent GPU/session growth", flush=True)

    # Once suspended, neither a source failure nor a failed write may erase the
    # editor's only exact cached print. Existing-file protection remains early.
    for label, patch in [
        ("missing source", {"source_path": str(directory / "missing.png"), "path": str(directory / "missing-output.png")}),
        ("missing output directory", {"path": str(directory / "absent" / "output.png")}),
        ("existing output", {"path": str(directory / "batch-00.png")}),
    ]:
        reply, payload = host.call("export_frame", {**export, **patch})
        require(not reply.get("ok") and not payload, f"{label} unexpectedly succeeded")
        editor_is_suspended(host, sid, disk_bytes)
        require(temp_files(host) == files, f"{label} lost or replaced editor snapshot")
    require(not list(directory.rglob("*.partial-*")), "failed export left a partial output")

    # Cover queued cancellation deterministically and in-flight cancellation
    # after the private session exists (the latter catches cleanup ordering).
    progress = "memory-queued-cancel"
    good(host, "cancel", {"session": "", "progress_id": progress})
    cancelled = directory / "queued-cancel.png"
    reply, _ = host.call("export_frame", {**export, "path": str(cancelled), "progress_id": progress})
    require(not reply.get("ok") and reply["error"]["code"] == "cancelled" and not cancelled.exists(), "queued cancellation failed")
    running = directory / "running-cancel.png"
    cancelled_export(host, {**export, "path": str(running), "progress_id": "memory-running-cancel"})
    require(not running.exists(), "running cancellation committed output")
    editor_is_suspended(host, sid, disk_bytes)
    require(temp_files(host) == files, "cancellation damaged editor snapshot")

    # A restored view must not need the original file or regenerate its film.
    a.unlink()
    failed_redecode, _ = host.call("redecode", {"session": sid})
    require(not failed_redecode.get("ok"), "redecode unexpectedly found the deleted source")
    editor_is_suspended(host, sid, disk_bytes)
    require(temp_files(host) == files, "failed redecode restored or discarded the old snapshot")
    restored, after = good(host, "render_view", view)
    require(restored["print_cached"] and after == pixels, "batch/failure/cancel restore changed random pixels")
    require(not temp_files(host) and memory(host)["suspended_bytes"] == 0, "resume left a disk snapshot")
    print("ok   output/source failures, queued/running cancellation, and source-independent byte-exact restore", flush=True)

    # Suspend again, then close without restoring: all temp files and the idle
    # pool must be released when the last editor handle is closed.
    good(host, "export_frame", {**export, "path": str(directory / "last.png")})
    editor_is_suspended(host, sid)
    good(host, "close", {"session": sid})
    closed = memory(host)
    require(not closed["persistent"]["sessions"] and closed["suspended_bytes"] == 0, "last close retained session/disk bytes")
    require(closed["pool"]["free_bytes"] == 0 and not temp_files(host), "last close retained pool or temporary files")
    print("ok   last close releases GPU scratch and deletes suspended snapshot", flush=True)
    return {"passed": True, "private_exports": 21, "idle_poll_samples": len(samples),
            "suspended_bytes": disk_bytes, "last_close": closed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--report", help="optional JSON result path")
    args = parser.parse_args()
    host = Host([str(Path(args.host).resolve()), "--resources", str(Path(args.resources).resolve())])
    watchdog = threading.Timer(120, lambda: host.p.kill() if host.p.poll() is None else None)
    watchdog.daemon = True
    watchdog.start()
    try:
        with tempfile.TemporaryDirectory(prefix="spektralab-host-memory-") as root:
            report = exercise(host, Path(root))
        if args.report:
            Path(args.report).write_text(json.dumps(report, indent=2), encoding="utf-8")
    finally:
        watchdog.cancel()
        if host.p.poll() is None:
            host.call("shutdown")
            host.p.wait(timeout=10)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
