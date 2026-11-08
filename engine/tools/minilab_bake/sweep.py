#!/usr/bin/env python3
"""The all-pair queue: one bake/render child process at a time, resumable.

    python sweep.py --work <copy> --oracle <engine> --max-jobs 2
    python sweep.py ... --films kodak_gold_200 --spaces sRGB --dry-run

Each job is a fresh `bake.py` process, so a failed pair releases every large
array it held. The ledger is updated before and after each child, and a child
that dies without a `status.json` is recorded as `bake_failed` with the tail of
its log; it is retried only with `--retry`.

Ordering is by value, not by inventory hash: every film's own `target_print`
pair first, then the remaining papers film by film. That way a run that is cut
short has left a coherent set of default pairs behind it.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ledger as ledger_mod  # noqa: E402
import mctx  # noqa: E402


def job_list(inventory, films=None, papers=None, spaces=None, order="default"):
    films = set(films) if films else None
    papers = set(papers) if papers else None
    spaces = list(spaces or mctx.SPACES)
    rows = [p for p in inventory["pairs"] if p["route"] == "colour_minilab"]
    if films:
        rows = [p for p in rows if p["film"] in films]
    if papers:
        rows = [p for p in rows if p["paper"] in papers]

    def emit(pair):
        return [(pair["film"], pair["paper"], s) for s in spaces]

    if order == "inventory":
        jobs = []
        for p in rows:
            jobs += emit(p)
        return jobs

    # default pairs first, then the remaining papers in a stable paper order
    paper_order = sorted({p["paper"] for p in rows})
    jobs = []
    for p in rows:
        if p["default_pair"]:
            jobs += emit(p)
    for paper in paper_order:
        for p in rows:
            if p["paper"] == paper and not p["default_pair"]:
                jobs += emit(p)
    # a default pair can appear twice when a film's target_print equals the
    # paper being iterated; the caller dedupes
    seen, unique = set(), []
    for j in jobs:
        if j not in seen:
            seen.add(j)
            unique.append(j)
    return unique


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--oracle", type=Path, required=True)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--repo", type=Path)
    ap.add_argument("--inventory", type=Path)
    ap.add_argument("--films", help="comma-separated")
    ap.add_argument("--papers", help="comma-separated")
    ap.add_argument("--spaces", help="comma-separated (default both)")
    ap.add_argument("--order", choices=["default", "inventory"], default="default")
    ap.add_argument("--max-jobs", type=int, default=0, help="0 = all")
    ap.add_argument("--stop-after-seconds", type=float, default=0)
    ap.add_argument("--retry", action="store_true",
                    help="retry failed/incomplete states")
    ap.add_argument("--timeout", type=float, default=3600)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args(argv)

    ctx = mctx.Ctx(a.work, a.oracle, a.out or (a.work / "run"), a.repo)
    ctx.ensure_dirs()
    inventory = mctx.read_json(a.inventory or (ctx.repo / "engine" / "minilab-coverage" / "inventory.json"))
    films = a.films.split(",") if a.films else None
    papers = a.papers.split(",") if a.papers else None
    spaces = a.spaces.split(",") if a.spaces else None
    jobs = job_list(inventory, films, papers, spaces, a.order)

    led = ledger_mod.Ledger(ctx.ledger_path)
    led.data["inventory_sha256"] = mctx.sha256_file(
        a.inventory or (ctx.repo / "engine" / "minilab-coverage" / "inventory.json"))
    led.save()

    def eligible(job):
        state = led.state(*job)
        if state in ledger_mod.DONE:
            return False
        if state in ledger_mod.OWES and not a.retry:
            return False
        if state in ledger_mod.FAILED and not a.retry:
            return False
        if a.retry:
            return True
        return state in ("pending", "preflight_ok", "fitting", "fitted", "baking", "baked")

    queue = [j for j in jobs if eligible(j)]
    if a.dry_run:
        print(json.dumps({"jobs": len(queue), "first": queue[:10],
                          "ledger": led.counts()}, indent=1))
        return 0

    t_start = time.time()
    ran = 0
    for film, paper, space in queue:
        if a.max_jobs and ran >= a.max_jobs:
            break
        if a.stop_after_seconds and time.time() - t_start > a.stop_after_seconds:
            break
        jid = mctx.job_id(film, paper, space)
        logpath = ctx.out / "logs" / (jid + ".log")
        logpath.parent.mkdir(parents=True, exist_ok=True)
        entry = led.get(film, paper, space) or {}
        led.update(film, paper, space, "baking", force=True,
                   attempts=int(entry.get("attempts", 0)) + 1,
                   started=time.time(), log=str(logpath))
        t0 = time.time()
        cmd = [str(ctx.python), str(Path(__file__).resolve().parent / "bake.py"),
               "--work", str(ctx.work), "--oracle", str(ctx.oracle),
               "--out", str(ctx.out), "--repo", str(ctx.repo),
               "--film", film, "--paper", paper, "--space", space]
        env = {k: v for k, v in os.environ.items() if not k.startswith(("SPK_", "SPEKTRALAB_"))}
        timed_out = False
        with open(logpath, "w") as log:
            try:
                proc = subprocess.run(cmd, cwd=str(ctx.work), env=env,
                                      stdout=log, stderr=subprocess.STDOUT,
                                      timeout=a.timeout)
                code = proc.returncode
            except subprocess.TimeoutExpired:
                code, timed_out = -1, True
        status_path = ctx.job_dir(film, paper, space) / "status.json"
        if status_path.exists():
            status = mctx.read_json(status_path)
            state = status.get("state", "bake_failed")
            fields = dict(finished=time.time(), duration_secs=time.time() - t0,
                          exit_code=code,
                          table_sha256=status.get("table_sha256"),
                          table_fnv1a64=status.get("table_fnv1a64"),
                          sidecar=status.get("sidecar"),
                          gates=status.get("gates"),
                          job_dir=str(ctx.job_dir(film, paper, space)),
                          rss_kb=status.get("rss_kb"))
            if state == "gate_failed":
                fields["error"] = "one or more numeric gates failed"
            if timed_out:
                state = "bake_failed"
                fields["error"] = "timeout after %.0f s" % a.timeout
        else:
            tail = logpath.read_text().splitlines()[-30:]
            state = "bake_failed"
            fields = dict(finished=time.time(), duration_secs=time.time() - t0,
                          exit_code=code, error="; ".join(tail[-6:]), log_tail=tail)
        led.update(film, paper, space, state, **fields)
        ran += 1
        print("[%d/%d] %s %s %.0fs %s" % (ran, len(queue), jid, space,
                                          time.time() - t0, state), flush=True)

    print("ledger:", json.dumps(led.counts()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
