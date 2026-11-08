#!/usr/bin/env python3
"""Reconcile the inventory with the ledger and write the coverage report.

    python report.py summary --work <copy> --oracle <engine>
    python report.py mark --ids <job>,<job> --state visual_pass --note "sheet reviewed"
    python report.py verify-staged --work <copy> --oracle <engine>

`summary` never invents a pass: a colour pair is *qualified* only when both
calibration spaces reached `visual_pass` (or beyond), and *staged* only when the
table and its catalog entry are in `engine/resources/minilab/`. The special
routes (silver, reversal bypass, incompatible) are reported separately and are
never counted as colour minilab transforms.
"""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ledger as ledger_mod  # noqa: E402
import mctx  # noqa: E402

QUALIFIED_STATES = {"visual_pass", "qualified", "staged", "integrated_verified"}
EVIDENCE_SPECIAL = {
    "silver_path": "engine/tests/bw_checks.py",
    "positive_bypass": "engine/src/pipeline/pipeline.cpp (positive print bypass)",
    "incompatible_channel_models": "engine/src/core/profile.cpp pairing rule + minilab_inventory.py",
}


def summarise(ctx, inventory, led):
    colour = [p for p in inventory["pairs"] if p["route"] == "colour_minilab"]
    rows = []
    for pair in colour:
        states, measurements = {}, {}
        for space in mctx.SPACES:
            entry = led.get(pair["film"], pair["paper"], space) or {}
            states[space] = entry.get("state", "pending")
            # An inherited-calibration entry has no job of its own; its evidence
            # is the base film's job, which is what it stages.
            evidence_film = entry.get("inherited_from", pair["film"])
            gates_path = ctx.job_dir(evidence_film, pair["paper"], space) / "gates.json"
            gates = (mctx.read_json(gates_path)
                     if gates_path.exists() and entry.get("state") not in ("pending", "baking")
                     else None)
            if gates and "lut_accuracy" in gates:
                checks = gates["lut_accuracy"]["checks"]
                measurements[space] = dict(
                    inherited_from=entry.get("inherited_from"),
                    chart_max=checks["chart"]["dE00_max"],
                    chart_mean=checks["chart"]["dE00_mean"],
                    nef_mean=checks["nef"]["dE00_mean"],
                    nef_p99=checks["nef"]["dE00_p99"],
                    # Portra's canary evidence predates the envelope gate and
                    # carries the older keys; fall back rather than hide it.
                    chart_mean_ok=(not checks["chart_mean_flag"]) if "chart_mean_flag" in checks else checks.get("chart_mean_ok", checks.get("chart_ok")),
                    nef_mean_ok=checks.get("nef_mean_ok", checks.get("nef_ok")),
                    nef_p99_ok=(not checks["nef_p99_flag"]) if "nef_p99_flag" in checks else checks.get("nef_p99_ok"),
                    chart_max_flag=checks.get("chart_max_flag"),
                    sop_chart_met=checks.get("sop_chart_met"),
                    sop_nef_met=checks.get("sop_nef_met"),
                    identity=gates.get("identity", {}).get("checks"),
                    tone=gates.get("tone", {}).get("checks", {}).get("minilab"))
        pair_ok = all(states[s] in QUALIFIED_STATES for s in mctx.SPACES)
        rows.append(dict(film=pair["film"], paper=pair["paper"],
                         default_pair=pair["default_pair"],
                         states=states, qualified=pair_ok,
                         measurements=measurements,
                         catalogued_spaces=pair["catalogued_spaces"]))
    qualified_pairs = sum(1 for r in rows if r["qualified"])
    qualified_tables = sum(1 for r in rows for s in mctx.SPACES
                           if r["states"][s] in QUALIFIED_STATES)
    # "staged" is a fact about the catalog, not a ledger claim: read the index.
    index = mctx.read_json(ctx.repo / "engine" / "resources" / "minilab" / "index.json")
    staged_tables = sum(1 for spaces in index["pairs"].values() for s in spaces
                        if s in mctx.SPACES)
    special = {}
    for route in ("silver_path", "positive_bypass", "incompatible_channel_models"):
        n = sum(1 for p in inventory["pairs"] if p["route"] == route)
        special[route] = dict(rows=n, accounted=n, evidence=EVIDENCE_SPECIAL[route])
    pending = [r for r in rows if not r["qualified"]
               and any(r["states"][s] in ledger_mod.FAILED for s in mctx.SPACES)]
    blocked = []
    for r in rows:
        for space in mctx.SPACES:
            if r["states"][space] in ledger_mod.FAILED:
                entry = led.get(r["film"], r["paper"], space) or {}
                blocked.append(dict(film=r["film"], paper=r["paper"], space=space,
                                    state=r["states"][space],
                                    measurement=r["measurements"].get(space),
                                    error=entry.get("error"),
                                    log=entry.get("log")))
    return dict(
        generated=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        inventory=dict(colour_pairs=len(colour),
                       production_tables=len(colour) * 2,
                       films=inventory["summary"]["films"],
                       papers=inventory["summary"]["papers"],
                       all_pairs=inventory["summary"]["all_pairs"]),
        coverage=dict(colour_pairs_qualified=qualified_pairs,
                      colour_pairs_denominator=len(colour),
                      production_tables_qualified=qualified_tables,
                      production_tables_denominator=len(colour) * 2,
                      production_tables_staged=staged_tables,
                      full_qualified=qualified_pairs == len(colour)),
        special_routes=special,
        ledger=led.counts(),
        blocked=blocked,
        rows=rows)


def markdown(report):
    c = report["coverage"]
    lines = [
        "# Minilab coverage ledger",
        "",
        "Generated %s by `engine/tools/minilab_bake/report.py`." % report["generated"],
        "",
        "| | count |",
        "|---|---:|",
        "| Colour pairs qualified | **%d / %d** |" % (c["colour_pairs_qualified"], c["colour_pairs_denominator"]),
        "| Production tables qualified | **%d / %d** |" % (c["production_tables_qualified"], c["production_tables_denominator"]),
        "| Production tables staged into `engine/resources/minilab/` | %d |" % c["production_tables_staged"],
        "| Full qualified coverage | %s |" % ("yes" if c["full_qualified"] else "**no**"),
        "",
        "A pair counts as qualified only when *both* calibration spaces reached",
        "`visual_pass`; \"the files exist\" is not the criterion.",
        "",
        "## Special routes (never counted as colour minilab)",
        "",
        "| route | rows | disposition | evidence |",
        "|---|---:|---|---|",
    ]
    for route, info in report["special_routes"].items():
        lines.append("| %s | %d | accounted, own runtime path preserved | `%s` |"
                     % (route, info["rows"], info["evidence"]))
    lines += ["", "## Colour pairs", "",
              "| film | paper | default | sRGB | ProPhoto | qualified |",
              "|---|---|:-:|---|---|:-:|"]
    for row in report["rows"]:
        lines.append("| %s | %s | %s | %s | %s | %s |" % (
            row["film"], row["paper"], "yes" if row["default_pair"] else "",
            row["states"]["sRGB"], row["states"]["ProPhoto RGB"],
            "**yes**" if row["qualified"] else "no"))
    if report["blocked"]:
        lines += ["", "## Blocked / failed rows", "",
                  "| film | paper | space | state | chart mean | photograph mean | photograph p99 | error |",
                  "|---|---|---|---|---:|---:|---:|---|"]
        for b in report["blocked"]:
            m = b.get("measurement") or {}
            fmt = lambda key: ("%.3f" % m[key]) if m.get(key) is not None else ""
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
                b["film"], b["paper"], b["space"], b["state"],
                fmt("chart_mean"), fmt("nef_mean"), fmt("nef_p99"),
                (b["error"] or "").replace("|", "\\|")[:180]))
    return "\n".join(lines) + "\n"


def verify_staged(ctx):
    index = mctx.read_json(ctx.repo / "engine" / "resources" / "minilab" / "index.json")
    problems, ok = [], 0
    for pair, spaces in sorted(index["pairs"].items()):
        film, paper = pair.split("|")
        for space, entry in sorted(spaces.items()):
            path = ctx.repo / "engine" / "resources" / "minilab" / entry["file"]
            if not path.is_file():
                problems.append("%s %s: missing %s" % (pair, space, entry["file"]))
                continue
            if path.stat().st_size != 28 + 65 ** 3 * 3 * 4:
                problems.append("%s %s: wrong size" % (pair, space))
            if mctx.fnv1a64_file(path) != entry["hash"]:
                problems.append("%s %s: payload hash" % (pair, space))
            for role, stock in (("film", film), ("paper", paper)):
                profile = None
                for folder in (ctx.repo / "engine" / "resources" / "profiles",
                               ctx.repo / "engine" / "resources_product" / "profiles"):
                    if (folder / (stock + ".json")).exists():
                        profile = folder / (stock + ".json")
                        break
                if profile is None:
                    problems.append("%s %s: no profile %s" % (pair, space, stock))
                    continue
                if mctx.fnv1a64_file(profile) != entry[role + "_hash"]:
                    problems.append("%s %s: %s identity" % (pair, space, role))
                data = mctx.read_json(profile)
                if data.get("derived_from"):
                    base = ctx.repo / "engine" / "resources" / "profiles" / (data["derived_from"] + ".json")
                    if role + "_base_hash" not in entry:
                        problems.append("%s %s: %s alias without base hash" % (pair, space, role))
                    elif mctx.fnv1a64_file(base) != entry[role + "_base_hash"]:
                        problems.append("%s %s: %s base identity" % (pair, space, role))
            ok += 1
    return dict(entries=ok, problems=problems)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("command", choices=["summary", "mark", "verify-staged", "adopt", "sheets"])
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--oracle", type=Path, required=True)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--repo", type=Path)
    ap.add_argument("--inventory", type=Path)
    ap.add_argument("--ids")
    ap.add_argument("--all-numeric", action="store_true",
                    help="mark every pair whose both spaces are numeric_pass")
    ap.add_argument("--state", choices=["visual_pass", "qualified", "needs_visual_review"])
    ap.add_argument("--note", default="")
    a = ap.parse_args(argv)
    ctx = mctx.Ctx(a.work, a.oracle, a.out or (a.work / "run"), a.repo)
    led = ledger_mod.Ledger(ctx.ledger_path)
    if a.command == "sheets":
        # One montage of every pair that is numeric_pass in both spaces and not
        # yet reviewed, so a batch is inspected in one image instead of N.
        from PIL import Image
        import numpy as np
        pairs = {}
        for entry in led.data["entries"].values():
            pairs.setdefault((entry["film"], entry["paper"]), {})[entry["space"]] = entry["state"]
        names = [mctx.job_id(f, p, "sRGB") for (f, p), sp in sorted(pairs.items())
                 if all(sp.get(s) == "numeric_pass" for s in mctx.SPACES)]
        if a.ids:
            keep = set(a.ids.split(","))
            names = [n for n in names if n in keep]
        tiles = []
        for name in names:
            path = ctx.sheets / (name + ".jpg")
            if not path.exists():
                continue
            im = Image.open(path)
            w = 250
            tiles.append(np.asarray(im.resize((w, round(im.height * w / im.width)),
                                             Image.LANCZOS)))
        if not tiles:
            print("no unreviewed sheets")
            return 0
        out = Path("/tmp/minilab-sheets.jpg")
        Image.fromarray(np.concatenate(tiles, 1)).save(out, quality=88)
        print(json.dumps(dict(sheets=len(tiles), path=str(out), ids=names)))
        return 0
    if a.command == "mark":
        if a.all_numeric:
            pairs = {}
            for entry in led.data["entries"].values():
                pairs.setdefault((entry["film"], entry["paper"]), {})[entry["space"]] = entry["state"]
            ids = [mctx.job_id(f, p, s) for (f, p), sp in sorted(pairs.items())
                   if all(sp.get(s) == "numeric_pass" for s in mctx.SPACES)
                   for s in mctx.SPACES]
        elif a.ids:
            ids = [x for x in a.ids.split(",")]
        else:
            raise SystemExit("mark needs --ids or --all-numeric")
        if not a.state:
            raise SystemExit("mark needs --state")
        for jid in ids:
            film, paper, space = mctx.parse_job_id(jid)
            entry = led.get(film, paper, space) or {}
            if entry.get("state") not in ("numeric_pass", "needs_visual_review",
                                          "visual_pass", "qualified"):
                print("%s: skipped from %s" % (jid, entry.get("state")))
                continue
            led.update(film, paper, space, a.state, review_note=a.note,
                       reviewed=time.time())
            print(jid, "->", a.state)
        return 0
    if a.command == "adopt":
        # A job run directly by `bake.py` before the ledger existed (the frozen
        # canary) is adopted from its published status.json, not re-baked.
        if not a.ids:
            raise SystemExit("adopt needs --ids")
        for jid in a.ids.split(","):
            film, paper, space = mctx.parse_job_id(jid)
            status = mctx.read_json(ctx.job_dir(film, paper, space) / "status.json")
            led.update(film, paper, space, status["state"],
                       finished=status.get("finished"),
                       duration_secs=status.get("duration_secs"),
                       table_sha256=status.get("table_sha256"),
                       table_fnv1a64=status.get("table_fnv1a64"),
                       sidecar=status.get("sidecar"), gates=status.get("gates"),
                       job_dir=str(ctx.job_dir(film, paper, space)),
                       peak_rss_bytes=status.get("peak_rss_bytes"))
            print(jid, "->", status["state"])
        return 0
    if a.command == "verify-staged":
        result = verify_staged(ctx)
        mctx.write_json(ctx.out / "reports" / "staged-verification.json", result)
        print(json.dumps(result, indent=1))
        return 0 if not result["problems"] else 1

    inventory_path = a.inventory or (ctx.repo / "engine" / "minilab-coverage" / "inventory.json")
    inventory = mctx.read_json(inventory_path)
    report = summarise(ctx, inventory, led)
    mctx.write_json(ctx.out / "reports" / "coverage.json", report)
    dest = ctx.repo / "engine" / "minilab-coverage" / "COVERAGE.md"
    dest.write_text(markdown(report))
    # The complete run ledger, committed next to the coverage table. Compact by
    # design: the evidence (nodes, sidecars, sheets, logs) stays in the run root,
    # whose path and digests travel in each job's manifest.
    compact = dict(
        schema_version=1, generated=report["generated"],
        inventory=str(inventory_path), inventory_sha256=mctx.sha256_file(inventory_path),
        recipe=mctx.RECIPE, coverage=report["coverage"],
        special_routes=report["special_routes"], ledger=report["ledger"],
        entries=[dict(film=r["film"], paper=r["paper"], default_pair=r["default_pair"],
                      states=r["states"], measurements=r["measurements"])
                 for r in report["rows"]])
    mctx.write_json(ctx.repo / "engine" / "minilab-coverage" / "LEDGER.json", compact)
    print(json.dumps(dict(coverage=report["coverage"],
                          special={k: v["rows"] for k, v in report["special_routes"].items()},
                          ledger=report["ledger"],
                          blocked=len(report["blocked"])), indent=1))
    print("wrote", dest, "and LEDGER.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
