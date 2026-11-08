#!/usr/bin/env python3
"""Copy qualified tables into `engine/resources/minilab/` and update the catalog.

    python stage.py --work <copy> --oracle <engine> \
        --ids kodak_gold_200__kodak_2383__srgb,kodak_gold_200__kodak_2383__pp

Nothing is staged without an explicit id. A pair is only eligible when its
numeric gates passed *and* its chart sheet was marked `visual_pass` in the
ledger (`report.py mark`). Existing known-good entries are never replaced unless
`--replace` is given.

The catalog identity is the engine's own: FNV-1a 64-bit over the raw file bytes
(`engine/src/core/minilab.cpp`), for the table, the named profile and — for a
`derived_from` alias — the inherited base profile. The last two are what stop a
table from outliving the material it was baked from.
"""
import argparse
import json
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ledger as ledger_mod  # noqa: E402
import mctx  # noqa: E402


def profile_path(repo, stock):
    for folder in (repo / "engine" / "resources" / "profiles",
                   repo / "engine" / "resources_product" / "profiles"):
        path = folder / (stock + ".json")
        if path.exists():
            return path
    raise SystemExit("missing profile %s" % stock)


def entry_for(ctx, film, paper, space, table_name):
    repo = ctx.repo
    out = dict(file=table_name, side=65,
               hash=mctx.fnv1a64_file(repo / "engine" / "resources" / "minilab" / table_name),
               film_hash=mctx.fnv1a64_file(profile_path(repo, film)),
               paper_hash=mctx.fnv1a64_file(profile_path(repo, paper)),
               look_retention=1,
               calibration_space=space)
    for role, stock in (("film", film), ("paper", paper)):
        data = mctx.read_json(profile_path(repo, stock))
        if data.get("derived_from"):
            out[role + "_base_hash"] = mctx.fnv1a64_file(
                repo / "engine" / "resources" / "profiles" / (data["derived_from"] + ".json"))
    return out


def make_bundle_resources(ctx):
    """The resources directory the app bundle would contain.

    `engine/build.sh bundle` syncs `engine/resources` and then lays the product
    overlay (`engine/resources_product`) over it. This mirrors that order so the
    runtime gate renders what would ship, not what the checkout happens to hold.
    """
    staging = ctx.out / "staging" / "resources"
    if staging.exists():
        shutil.rmtree(staging)
    shutil.copytree(ctx.repo / "engine" / "resources", staging)
    overlay = ctx.repo / "engine" / "resources_product"
    for item in sorted(overlay.iterdir()):
        target = staging / item.name
        if item.is_dir():
            shutil.copytree(item, target, dirs_exist_ok=True)
        else:
            shutil.copy2(item, target)
    return staging


def inherit_aliases(ctx, led, index):
    """Catalog a `derived_from` alias on its base film's qualified tables.

    A film alias is the base's measured data with a different `info` (CineStill
    800T is Vision3 500T with the rem-jet removed). The print transform is a
    property of the developed emulsion and the paper, so it *is* the base's
    transform; halation is a spatial film-stage effect that the table cannot and
    must not carry. Baking the alias separately derives its exposure anchor with
    halation active and shifts the domain, which is why CineStill measured
    0.21-0.28 where Vision3 500T measured 0.14-0.17 on the same paper.

    The entry points at the base's table file and pins both the alias bytes and
    the inherited base bytes. A future CineStill-specific calibration is the
    override: bake that pair normally and stage it with --replace.
    """
    repo = ctx.repo
    aliases = {}
    for path in sorted((repo / "engine" / "resources_product" / "profiles").glob("*.json")):
        data = mctx.read_json(path)
        if data.get("derived_from"):
            aliases[path.stem] = data["derived_from"]
    qualified = {"visual_pass", "qualified", "staged", "integrated_verified"}
    staged = []
    for alias, base in sorted(aliases.items()):
        for key in sorted(k for k in index["pairs"] if k.startswith(base + "|")):
            paper = key.split("|", 1)[1]
            base_spaces = index["pairs"][key]
            # The base must itself be qualified in both spaces; an alias may
            # not inherit a table the base never qualified.
            if not all((led.get(base, paper, s) or {}).get("state") in qualified
                       for s in mctx.SPACES):
                continue
            entry = {}
            for space, base_entry in base_spaces.items():
                entry[space] = dict(
                    file=base_entry["file"], side=65, hash=base_entry["hash"],
                    film_hash=mctx.fnv1a64_file(profile_path(repo, alias)),
                    paper_hash=mctx.fnv1a64_file(profile_path(repo, paper)),
                    film_base_hash=mctx.fnv1a64_file(profile_path(repo, base)),
                    look_retention=1, calibration_space=space,
                    calibration_source=base)
                led.update(alias, paper, space, "staged", force=True,
                           staged_file=base_entry["file"],
                           inherited_from=base, staged_at=time.time(),
                           staged=entry[space])
                staged.append(dict(id=mctx.job_id(alias, paper, space),
                                   file=base_entry["file"], inherited_from=base))
            index["pairs"][alias + "|" + paper] = entry
    return staged


def prune_unreferenced(ctx, index):
    """Remove table files no catalog entry names (an alias's superseded bakes)."""
    minilab = ctx.repo / "engine" / "resources" / "minilab"
    used = {e["file"] for spaces in index["pairs"].values() for e in spaces.values()}
    removed = []
    for path in sorted(minilab.glob("*.lut3d")):
        if path.name not in used:
            path.unlink()
            removed.append(path.name)
    return removed


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--oracle", type=Path, required=True)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--repo", type=Path)
    ap.add_argument("--ids", help="comma-separated job ids")
    ap.add_argument("--qualified", action="store_true",
                    help="stage every pair whose both spaces are visual_pass")
    ap.add_argument("--inherit-alias", action="store_true",
                    help="catalog every derived_from alias on its base film's "
                         "qualified tables, without rebaking (see FINDINGS 9)")
    ap.add_argument("--replace", action="store_true")
    a = ap.parse_args(argv)
    ctx = mctx.Ctx(a.work, a.oracle, a.out or (a.work / "run"), a.repo)
    led = ledger_mod.Ledger(ctx.ledger_path)
    minilab = ctx.repo / "engine" / "resources" / "minilab"
    index_path = minilab / "index.json"
    index = mctx.read_json(index_path)
    staged = []
    if a.inherit_alias:
        staged = inherit_aliases(ctx, led, index)
        index["pairs"] = dict(sorted(index["pairs"].items()))
        tmp = index_path.with_name(index_path.name + ".tmp")
        tmp.write_text(json.dumps(index, indent=2) + "\n")
        tmp.replace(index_path)
        prune_unreferenced(ctx, index)
        bundle = make_bundle_resources(ctx)
        mctx.write_json(ctx.out / "reports" / "staging.json",
                        dict(staged=staged, index=str(index_path),
                             pairs=len(index["pairs"]), mode="inherit-alias"))
        print(json.dumps(dict(staged=len(staged), pairs=len(index["pairs"]),
                              bundle=str(bundle)), indent=1))
        return 0
    if a.qualified:
        pairs = {}
        for entry in led.data["entries"].values():
            if entry["state"] in ("visual_pass", "qualified"):
                pairs.setdefault((entry["film"], entry["paper"]), set()).add(entry["space"])
        ids = [mctx.job_id(f, p, s) for (f, p), spaces in sorted(pairs.items())
               if all(s in spaces for s in mctx.SPACES) for s in mctx.SPACES]
    elif a.ids:
        ids = [x for x in a.ids.split(",") if x]
    else:
        raise SystemExit("stage needs --ids or --qualified")
    for jid in ids:
        film, paper, space = mctx.parse_job_id(jid)
        entry = led.get(film, paper, space)
        if not entry:
            raise SystemExit("%s: no ledger entry" % jid)
        if entry["state"] not in ("visual_pass", "qualified", "staged"):
            raise SystemExit("%s: state %s is not stageable (needs visual_pass)"
                             % (jid, entry["state"]))
        jobdir = ctx.job_dir(film, paper, space)
        gates = mctx.read_json(jobdir / "gates.json")
        for gate in ("artifact", "paper_solve", "lut_accuracy", "tone"):
            if not gates[gate]["passed"]:
                raise SystemExit("%s: gate %s failed" % (jid, gate))
        if not (jobdir / "sheet.jpg").exists():
            raise SystemExit("%s: no chart sheet" % jid)
        name = "%s__%s%s.lut3d" % (film, paper,
                                   "_pp" if space == "ProPhoto RGB" else "")
        pair_key = "%s|%s" % (film, paper)
        existing = index["pairs"].get(pair_key, {}).get(space)
        if existing and not a.replace:
            raise SystemExit("%s: %s already catalogued as %s (use --replace)"
                             % (jid, space, existing["file"]))
        shutil.copy2(jobdir / "table.lut3d", minilab / name)
        entry_json = entry_for(ctx, film, paper, space, name)
        index["pairs"].setdefault(pair_key, {})[space] = entry_json
        led.update(film, paper, space, "staged", staged_file=name,
                   staged=entry_json, staged_at=time.time())
        staged.append(dict(id=jid, file=name, entry=entry_json))
    index["pairs"] = dict(sorted(index["pairs"].items()))
    tmp = index_path.with_name(index_path.name + ".tmp")
    tmp.write_text(json.dumps(index, indent=2) + "\n")
    tmp.replace(index_path)
    mctx.write_json(ctx.out / "reports" / "staging.json",
                    dict(staged=staged, index=str(index_path),
                         pairs=len(index["pairs"])))
    bundle = make_bundle_resources(ctx)
    print(json.dumps(dict(staged=len(staged), pairs=len(index["pairs"]),
                          bundle=str(bundle)), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
