"""Exercise window/worker handlers in a non-activated offscreen window.

Captures use a memory DC: they validate layout and GDI pixel routing, not a
monitor profile, live gestures, display latency or visible-window appearance.
Python is only the test launcher, never a runtime dependency of SpektraLab.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time


def sha(path):
    with open(path, "rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--reject", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build, source, reject, output = (p.resolve() for p in (args.build, args.input, args.reject, args.output))
    output.mkdir(parents=True, exist_ok=False)
    exe = build / "engine/SpektraLab.exe"
    hashes = {str(p): sha(p) for p in (source, reject)}
    command = [str(exe), "--open", str(source), "--reject", str(reject), "--self-test", str(output / "window")]
    environment = os.environ.copy()
    environment["PATH"] = str(exe.parent) + os.pathsep + environment.get("PATH", "")
    started = time.perf_counter()
    run = subprocess.run(command, cwd=output, env=environment, capture_output=True, timeout=120)
    (output / "stdout.txt").write_bytes(run.stdout)
    (output / "stderr.txt").write_bytes(run.stderr)
    ui_path = output / "window/ui-report.json"
    ui = json.loads(ui_path.read_text(encoding="utf-8")) if ui_path.is_file() else {}
    unchanged = hashes == {str(p): sha(p) for p in (source, reject)}
    ok = run.returncode == 0 and ui.get("success") and unchanged
    report = {
        "success": bool(ok), "command": command, "exit_code": run.returncode,
        "wall_seconds": time.perf_counter() - started,
        "timing_scope": "entire test including snapshots, export, edits and rejected open; not a benchmark",
        "executable_sha256": sha(exe), "input_hashes": hashes,
        "inputs_unchanged": unchanged, "ui": ui,
        "outputs": {str(p.relative_to(output)): {"bytes": p.stat().st_size, "sha256": sha(p)}
                    for p in (output / "window").glob("*") if p.is_file()},
    }
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"success": bool(ok), "exit_code": run.returncode, "report": str(output / "report.json")}, ensure_ascii=False))
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
