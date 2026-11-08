#!/usr/bin/env python3
"""Prepare the offline workspace: resource overlays and per-film anchors.

Run once before a sweep (idempotent):

    python prepare.py --work <research copy> --oracle <patched engine> \
        --inventory ../../minilab-coverage/inventory.json

It writes `resources/` (what the oracle engine reads, including the product's
alias profile as shipped) and `host_resources/` (the same bytes with aliases
materialised for the numpy replica), then generates `anchor_C0` for every colour
film that does not have one. No table is baked here.
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mctx  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--work", type=Path, required=True)
    ap.add_argument("--oracle", type=Path, required=True)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--repo", type=Path)
    ap.add_argument("--inventory", type=Path, help="default: <repo>/engine/minilab-coverage/inventory.json")
    a = ap.parse_args(argv)
    ctx = mctx.Ctx(a.work, a.oracle, a.out or (a.work / "run"), a.repo)
    overlay = mctx.ensure_overlays(ctx)
    bridge = mctx.ensure_engine_bridge(ctx)

    inventory = mctx.read_json(a.inventory or (ctx.repo / "engine" / "minilab-coverage" / "inventory.json"))
    films = sorted({p["film"] for p in inventory["pairs"] if p["route"] == "colour_minilab"})
    ctx.bootstrap()
    anchors = mctx.ensure_anchors(ctx, films)

    print("overlay:", len(overlay["profiles"]), "profiles,", len(overlay["aliases"]), "aliases")
    print("engine bridge:", bridge["resources"])
    print("anchors:", len(anchors), "films")
    for film, info in sorted(anchors.items()):
        print("  %-32s %s %s" % (film, "reused" if info["reused"] else "computed",
                                 [round(v, 4) for v in info["anchor_C0"]]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
